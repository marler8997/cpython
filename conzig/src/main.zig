//! Resolves conzig files, see README.md.

const usage =
    \\usage: conzig check FILE
    \\       conzig resolve FILE [--also FILE...] [--target TRIPLE] [--zig PATH] [NAME=VALUE...]
    \\                      --resolved OUT [--unresolved OUT] [--needed OUT] [--error-unused-inputs]
    \\       conzig header RESOLVED TEMPLATE OUT
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const command = args.next() orelse fatal("{s}", .{usage});
    const path = args.next() orelse fatal("{s}", .{usage});
    if (std.mem.eql(u8, command, "header")) {
        const template_path = args.next() orelse fatal("{s}", .{usage});
        const out_path = args.next() orelse fatal("{s}", .{usage});
        if (args.next() != null) fatal("{s}", .{usage});
        return writeHeader(arena, io, path, template_path, out_path);
    }
    const is_resolve = std.mem.eql(u8, command, "resolve");
    if (!is_resolve and !std.mem.eql(u8, command, "check")) fatal("{s}", .{usage});

    var sources: std.ArrayList(Source) = .empty;
    var content: std.ArrayList(u8) = .empty;
    try appendSource(arena, io, &sources, &content, path);

    var resolved_path: ?[]const u8 = null;
    var unresolved_path: ?[]const u8 = null;
    var needed_path: ?[]const u8 = null;
    var error_unused_inputs = false;
    var target_triple: ?[]const u8 = null;
    var zig_exe: ?[]const u8 = null;
    var cli_inputs: std.ArrayList(conzig.Input) = .empty;
    if (!is_resolve and args.next() != null) fatal("{s}", .{usage});
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--target")) {
            target_triple = args.next() orelse fatal("{s}", .{usage});
        } else if (std.mem.eql(u8, arg, "--zig")) {
            zig_exe = args.next() orelse fatal("{s}", .{usage});
        } else if (std.mem.eql(u8, arg, "--resolved")) {
            resolved_path = args.next() orelse fatal("{s}", .{usage});
        } else if (std.mem.eql(u8, arg, "--unresolved")) {
            unresolved_path = args.next() orelse fatal("{s}", .{usage});
        } else if (std.mem.eql(u8, arg, "--needed")) {
            needed_path = args.next() orelse fatal("{s}", .{usage});
        } else if (std.mem.eql(u8, arg, "--error-unused-inputs")) {
            error_unused_inputs = true;
        } else if (std.mem.eql(u8, arg, "--also")) {
            try appendSource(arena, io, &sources, &content, args.next() orelse fatal("{s}", .{usage}));
        } else {
            const eq = std.mem.indexOfScalar(u8, arg, '=') orelse fatal("expected NAME=VALUE but got '{s}'", .{arg});
            try cli_inputs.append(arena, .{ .name = arg[0..eq], .value = arg[eq + 1 ..] });
        }
    }

    var diagnostic: conzig.Diagnostic = .{};
    const file = conzig.parse(arena, content.items, &diagnostic) catch |err| switch (err) {
        error.Invalid => fatalAt(sources.items, diagnostic.line, diagnostic.message),
        error.OutOfMemory => |e| return e,
    };
    if (!is_resolve) return;

    if (zig_exe != null and target_triple == null) fatal("--zig needs --target, compile checks need a whole target", .{});

    // what the results will depend on, these are inputs so that a later run can't use different ones
    var derived: std.ArrayList(conzig.Input) = .empty;
    if (target_triple) |triple| try appendTargetInputs(arena, io, &derived, triple);
    if (zig_exe) |zig| try derived.append(arena, .{ .name = "zig.version", .value = zigVersion(arena, io, zig) });

    var given: std.ArrayList(conzig.Input) = .empty;
    try given.appendSlice(arena, file.inputs);
    for ([_][]const conzig.Input{ cli_inputs.items, derived.items }) |inputs_to_add| {
        for (inputs_to_add) |input| {
            // results in this file were resolved with the other value, so they'd be wrong
            const already = for (given.items) |other| {
                if (std.mem.eql(u8, other.name, input.name)) break other;
            } else null;
            if (already) |other| {
                if (!std.mem.eql(u8, other.value, input.value)) fatal(
                    "{s} is already {s} but this run also has {s}",
                    .{ other.name, other.value, input.value },
                );
            } else try given.append(arena, input);
        }
    }
    if (error_unused_inputs) {
        const used = try conzig.usedNames(arena, file);
        var count: usize = 0;
        for (cli_inputs.items) |input| {
            if (used.contains(input.name)) continue;
            std.log.err("the input {s} isn't used by any definition", .{input.name});
            count += 1;
        }
        if (count != 0) fatal("{} inputs are unused", .{count});
    }

    var inputs: std.StringHashMapUnmanaged(conzig.Result) = .empty;
    for (given.items) |input| try inputs.put(arena, input.name, .parseInput(input.value));
    const resolved_out = resolved_path orelse fatal("{s}", .{usage});
    const work_dir = try std.fmt.allocPrint(arena, "{s}.checks", .{resolved_out});
    defer std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};
    const compiler: []const []const u8 = if (zig_exe) |zig| &.{ zig, "cc", "-target", target_triple.? } else &.{};
    var checker: Checker = .{ .arena = arena, .io = io, .compiler = compiler, .work_dir = work_dir, .prelude = file.prelude };
    var evaluator: conzig.Evaluator = .{ .arena = arena, .inputs = &inputs, .diagnostic = &diagnostic };
    if (compiler.len != 0) {
        checker.checkCompiler() catch |err| switch (err) {
            error.CheckFailed => fatal("{s}", .{checker.failure}),
            error.OutOfMemory => |e| return e,
        };
        checker.runAll(file) catch |err| switch (err) {
            error.CheckFailed => fatal("{s}", .{checker.failure}),
            error.OutOfMemory => |e| return e,
        };
        evaluator.check = .{ .context = &checker, .run = Checker.check };
    }
    const results = evaluator.run(file) catch |err| switch (err) {
        error.Invalid => fatalAt(sources.items, diagnostic.line, diagnostic.message),
        error.CheckFailed => fatal("{s}", .{checker.failure}),
        error.OutOfMemory => |e| return e,
    };

    // with nowhere to put them, what's left are errors
    if (unresolved_path == null) {
        var count: usize = 0;
        for (file.defs, results) |def, result| {
            if (result != .unresolved) continue;
            const at = locate(sources.items, def.line);
            std.log.err("{s}:{}: {s} {f}", .{ at.path, at.line, def.name, result.unresolved });
            count += 1;
        }
        if (count != 0) fatal("{} values are unresolved", .{count});
    }

    var resolved: std.Io.Writer.Allocating = .init(arena);
    conzig.writeResolved(&resolved.writer, file, results) catch return error.OutOfMemory;
    writeFile(io, resolved_out, resolved.written());
    if (unresolved_path) |unresolved_out| {
        var unresolved: std.Io.Writer.Allocating = .init(arena);
        conzig.writeUnresolved(arena, &unresolved.writer, file, results, given.items) catch return error.OutOfMemory;
        writeFile(io, unresolved_out, unresolved.written());
    }
    if (needed_path) |needed_out| {
        var needed: std.Io.Writer.Allocating = .init(arena);
        conzig.writeNeeded(arena, &needed.writer, file, results, given.items) catch return error.OutOfMemory;
        writeFile(io, needed_out, needed.written());
    }
}

fn appendTargetInputs(
    arena: std.mem.Allocator,
    io: std.Io,
    inputs: *std.ArrayList(conzig.Input),
    triple: []const u8,
) error{OutOfMemory}!void {
    const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch |err| fatal(
        "invalid target '{s}': {t}",
        .{ triple, err },
    );
    const target = std.zig.system.resolveTargetQuery(io, query) catch |err| fatal(
        "failed to resolve target '{s}' with {t}",
        .{ triple, err },
    );
    try inputs.appendSlice(arena, &.{
        .{ .name = "target.triple", .value = triple },
        .{ .name = "target.os.tag", .value = @tagName(target.os.tag) },
        .{ .name = "target.cpu.arch", .value = @tagName(target.cpu.arch) },
        .{ .name = "target.cpu.endian", .value = @tagName(target.cpu.arch.endian()) },
        .{ .name = "target.abi.tag", .value = @tagName(target.abi) },
    });
}

fn zigVersion(arena: std.mem.Allocator, io: std.Io, zig_exe: []const u8) []const u8 {
    const result = std.process.run(arena, io, .{ .argv = &.{ zig_exe, "version" } }) catch |err| fatal(
        "failed to run '{s} version' with {t}",
        .{ zig_exe, err },
    );
    if (result.term != .exited or result.term.exited != 0) fatal("'{s} version' failed: {s}", .{ zig_exe, result.stderr });
    return std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
}

/// A file in the content being parsed and the line before its first one.
const Source = struct {
    path: []const u8,
    start: u32,
};

fn appendSource(
    arena: std.mem.Allocator,
    io: std.Io,
    sources: *std.ArrayList(Source),
    content: *std.ArrayList(u8),
    path: []const u8,
) error{OutOfMemory}!void {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| fatal(
        "failed to read '{s}' with {t}",
        .{ path, err },
    );
    try sources.append(arena, .{ .path = path, .start = @intCast(std.mem.countScalar(u8, content.items, '\n')) });
    try content.appendSlice(arena, data);
    if (data.len != 0 and data[data.len - 1] != '\n') try content.append(arena, '\n');
}

fn locate(sources: []const Source, line: u32) struct { path: []const u8, line: u32 } {
    var index = sources.len - 1;
    while (index > 0 and sources[index].start >= line) index -= 1;
    return .{ .path = sources[index].path, .line = line - sources[index].start };
}

fn fatalAt(sources: []const Source, line: u32, message: []const u8) noreturn {
    const at = locate(sources, line);
    fatal("{s}:{}: {s}", .{ at.path, at.line, message });
}

/// Replaces each `#undef NAME` line in an autoconf template. A value the template doesn't have, or
/// the other way around, means they're out of step, so both are errors.
fn writeHeader(
    arena: std.mem.Allocator,
    io: std.Io,
    resolved_path: []const u8,
    template_path: []const u8,
    out_path: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    const resolved = cwd.readFileAlloc(io, resolved_path, arena, .unlimited) catch |err| fatal(
        "failed to read '{s}' with {t}",
        .{ resolved_path, err },
    );
    const template = cwd.readFileAlloc(io, template_path, arena, .unlimited) catch |err| fatal(
        "failed to read '{s}' with {t}",
        .{ template_path, err },
    );

    const Entry = struct { value: conzig.Value, used: bool = false };
    var values: std.StringArrayHashMapUnmanaged(Entry) = .empty;
    var resolved_lines = std.mem.splitScalar(u8, resolved, '\n');
    var line_num: u32 = 0;
    while (resolved_lines.next()) |line| {
        line_num += 1;
        if (line.len == 0) continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse fatal("{s}:{}: invalid line '{s}'", .{ resolved_path, line_num, line });
        const value = conzig.Value.parse(line[space + 1 ..]) orelse fatal("{s}:{}: invalid value in '{s}'", .{ resolved_path, line_num, line });
        try values.put(arena, line[0..space], .{ .value = value });
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var errors: usize = 0;
    var template_lines = std.mem.splitScalar(u8, template, '\n');
    line_num = 0;
    while (template_lines.next()) |line| {
        line_num += 1;
        const name = undefName(line) orelse {
            w.print("{s}\n", .{line}) catch return error.OutOfMemory;
            continue;
        };
        const entry = values.getPtr(name) orelse {
            std.log.err("{s}:{}: {s} has no definition", .{ template_path, line_num, name });
            errors += 1;
            continue;
        };
        entry.used = true;
        (switch (entry.value) {
            .undef => w.print("/* #undef {s} */\n", .{name}),
            .defined => w.print("#define {s}\n", .{name}),
            .false => w.print("#define {s} 0\n", .{name}),
            .true => w.print("#define {s} 1\n", .{name}),
            .int => |int| w.print("#define {s} {}\n", .{ name, int }),
            .string => |string| w.print("#define {s} \"{s}\"\n", .{ name, string }),
            .ident => |ident| w.print("#define {s} {s}\n", .{ name, ident }),
        }) catch return error.OutOfMemory;
    }
    for (values.keys(), values.values()) |name, entry| {
        if (entry.used) continue;
        std.log.err("{s}: {s} isn't in {s}", .{ resolved_path, name, template_path });
        errors += 1;
    }
    if (errors != 0) fatal("{} values don't match between {s} and {s}", .{ errors, resolved_path, template_path });
    writeFile(io, out_path, out.written());
}

fn undefName(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "#")) return null;
    var it = std.mem.tokenizeAny(u8, line[1..], " \t\r");
    if (!std.mem.eql(u8, it.next() orelse return null, "undef")) return null;
    return it.next() orelse fatal("'#undef' with no name", .{});
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) void {
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch |err| fatal(
        "failed to write '{s}' with {t}",
        .{ path, err },
    );
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");
const conzig = @import("conzig");
const Checker = conzig.Checker;
