//! Answers the checks that need a compiler. The compiler is an opaque command, this only appends
//! to it and looks at whether it succeeded.

const Checker = @This();

arena: std.mem.Allocator,
io: std.Io,
compiler: []const []const u8,
work_dir: []const u8,
prelude: conzig.Attrs,
/// Results from `runAll`, by the definition's name.
results: std.StringHashMapUnmanaged(conzig.Value) = .empty,
/// Why it failed if a function returned error.CheckFailed.
failure: []const u8 = "",

const Error = conzig.CheckError;

const Mode = enum { compile, link };

fn fail(c: *Checker, comptime fmt: []const u8, args: anytype) Error {
    c.failure = try std.fmt.allocPrint(c.arena, fmt, args);
    return error.CheckFailed;
}

/// Makes sure the compiler works. Without this a broken one would look like nothing is available.
pub fn checkCompiler(c: *Checker) Error!void {
    for ([_]Mode{ .compile, .link }) |mode| {
        const result = try c.run("conzig_compiler_check", "int main(void) { return 0; }\n", mode, &.{});
        if (!result.passed) return c.fail("the compiler can't {t} a trivial program:\n{s}", .{ mode, result.stderr });
    }
}

/// Runs the checks that don't depend on any others, a batch at a time.
pub fn runAll(c: *Checker, file: conzig.File) Error!void {
    var indexes: std.ArrayList(usize) = .empty;
    for (file.defs, 0..) |def, i| {
        if (def.guard == null and def.kind.needsCompiler()) try indexes.append(c.arena, i);
    }
    const outcomes = try c.arena.alloc(Error!conzig.Value, file.defs.len);
    const batch_size = std.Thread.getCpuCount() catch 1;
    var start: usize = 0;
    while (start < indexes.items.len) : (start += batch_size) {
        var group: std.Io.Group = .init;
        for (indexes.items[start..@min(start + batch_size, indexes.items.len)]) |i| {
            group.async(c.io, runOne, .{ c, file.defs[i], &outcomes[i] });
        }
        group.await(c.io) catch |err| switch (err) {
            error.Canceled => return c.fail("canceled", .{}),
        };
    }
    for (indexes.items) |i| try c.results.put(c.arena, file.defs[i].name, try outcomes[i]);
}

fn runOne(c: *Checker, def: conzig.Def, outcome: *Error!conzig.Value) void {
    outcome.* = c.compute(def);
}

/// The answer for a definition, for conzig.Evaluator.
pub fn check(context: *anyopaque, def: conzig.Def) Error!conzig.Value {
    const c: *Checker = @ptrCast(@alignCast(context));
    if (c.results.get(def.name)) |value| return value;
    return c.compute(def);
}

fn compute(c: *Checker, def: conzig.Def) Error!conzig.Value {
    switch (def.kind) {
        .sizeof => return c.findSize(def, "sizeof"),
        .alignof => return c.findSize(def, "_Alignof"),
        else => {},
    }
    const mode: Mode = switch (def.kind) {
        .@"have-function", .links => .link,
        else => .compile,
    };
    const result = try c.run(def.name, try c.source(def, try c.program(def)), mode, def.attrs.libs);
    return if (result.passed) def.pass else def.fail;
}

/// What goes after the includes.
fn program(c: *Checker, def: conzig.Def) Error![]const u8 {
    return switch (def.kind) {
        .@"have-header" => "int main(void) { return 0; }\n",
        // taking its address works whatever its signature is, and a macro can't be linked
        .@"have-function" => try std.fmt.allocPrint(c.arena,
            \\int main(void) {{
            \\#ifndef {0s}
            \\    void *volatile x = (void *){0s};
            \\    return x != 0;
            \\#else
            \\    return 0;
            \\#endif
            \\}}
            \\
        , .{def.args[0]}),
        .@"have-type" => try std.fmt.allocPrint(c.arena, "int main(void) {{ return sizeof({s}) == 0; }}\n", .{def.args[0]}),
        .@"have-member" => try std.fmt.allocPrint(c.arena, "int main(void) {{ {s} x; return sizeof(x.{s}) == 0; }}\n", .{ def.args[0], def.args[1] }),
        .@"have-decl" => try std.fmt.allocPrint(c.arena,
            \\int main(void) {{
            \\#ifndef {0s}
            \\    (void){0s};
            \\#endif
            \\    return 0;
            \\}}
            \\
        , .{def.args[0]}),
        .links, .compiles => try std.mem.join(c.arena, "\n", def.body),
        else => unreachable,
    };
}

fn source(c: *Checker, def: conzig.Def, body: []const u8) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(c.arena);
    const w = &out.writer;
    writeSource(w, c.prelude, def, body) catch return error.OutOfMemory;
    return out.written();
}

fn writeSource(w: *std.Io.Writer, prelude: conzig.Attrs, def: conzig.Def, body: []const u8) error{WriteFailed}!void {
    for ([_]conzig.Attrs{ prelude, def.attrs }) |attrs| {
        for (attrs.defines) |define| {
            if (std.mem.indexOfScalar(u8, define, '=')) |eq| {
                try w.print("#define {s} {s}\n", .{ define[0..eq], define[eq + 1 ..] });
            } else {
                try w.print("#define {s} 1\n", .{define});
            }
        }
    }
    for ([_]conzig.Attrs{ prelude, def.attrs }) |attrs| {
        for (attrs.includes) |include| try w.print("#include <{s}>\n", .{include});
    }
    if (def.kind == .@"have-header") try w.print("#include <{s}>\n", .{def.args[0]});
    try w.writeAll(body);
    try w.writeByte('\n');
}

/// Finds a size by compiling, nothing has to run so this works when cross compiling. Most sizes are
/// one of the common ones. A type that doesn't exist has the size 0, as it does in configure.
fn findSize(c: *Checker, def: conzig.Def, operator: []const u8) Error!conzig.Value {
    for ([_]u32{ 8, 4, 16, 2, 1 }) |size| {
        if (try c.sizeHolds(def, operator, "==", size)) return .{ .int = size };
    }
    var high: u32 = 1;
    while (!try c.sizeHolds(def, operator, "<=", high)) {
        if (high >= 1 << 16) return .{ .int = 0 };
        high *= 2;
    }
    var low: u32 = high / 2 + 1;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (try c.sizeHolds(def, operator, "<=", middle)) high = middle else low = middle + 1;
    }
    return .{ .int = high };
}

fn sizeHolds(c: *Checker, def: conzig.Def, operator: []const u8, comparison: []const u8, size: u32) Error!bool {
    const body = try std.fmt.allocPrint(c.arena, "_Static_assert({s}({s}) {s} {}, \"\");\nint main(void) {{ return 0; }}\n", .{ operator, def.args[0], comparison, size });
    const result = try c.run(def.name, try c.source(def, body), .compile, &.{});
    return result.passed;
}

const RunResult = struct { passed: bool, stderr: []const u8 };

fn run(c: *Checker, name: []const u8, source_text: []const u8, mode: Mode, libs: []const []const u8) Error!RunResult {
    const cwd = std.Io.Dir.cwd();
    const dir = try std.fmt.allocPrint(c.arena, "{s}/{s}", .{ c.work_dir, name });
    cwd.createDirPath(c.io, dir) catch |err| return c.fail("failed to create '{s}' with {t}", .{ dir, err });
    defer cwd.deleteTree(c.io, dir) catch {};
    const source_path = try std.fmt.allocPrint(c.arena, "{s}/check.c", .{dir});
    cwd.writeFile(c.io, .{ .sub_path = source_path, .data = source_text }) catch |err| return c.fail("failed to write '{s}' with {t}", .{ source_path, err });

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.arena, c.compiler);
    if (mode == .compile) try argv.append(c.arena, "-c");
    try argv.appendSlice(c.arena, &.{ "-o", try std.fmt.allocPrint(c.arena, "{s}/check.out", .{dir}), source_path });
    if (mode == .link) {
        for ([_][]const []const u8{ c.prelude.libs, libs }) |lib_list| {
            for (lib_list) |lib| try argv.append(c.arena, try std.fmt.allocPrint(c.arena, "-l{s}", .{lib}));
        }
    }
    const result = std.process.run(c.arena, c.io, .{ .argv = argv.items }) catch |err| return c.fail("failed to run '{s}' with {t}", .{ c.compiler[0], err });
    return .{ .passed = result.term == .exited and result.term.exited == 0, .stderr = result.stderr };
}

const std = @import("std");
const conzig = @import("root.zig");
