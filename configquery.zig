pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var template_files: std.ArrayList([]const u8) = .empty;
    var output_path: ?[]const u8 = null;
    var config: Config = .{};

    {
        var args = try init.minimal.args.iterateAllocator(arena);
        _ = args.next();
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "-o")) {
                output_path = args.next() orelse fatal("-o requires an argument", .{});
            } else if (std.mem.eql(u8, arg, "--zig-exe")) {
                config.zig_exe = args.next() orelse fatal("--zig-exe requires an argument", .{});
            } else if (std.mem.eql(u8, arg, "--cache-dir")) {
                config.cache_dir = args.next() orelse fatal("--cache-dir requires an argument", .{});
            } else if (std.mem.eql(u8, arg, "-target")) {
                config.target_triple = args.next() orelse fatal("-target requires an argument", .{});
            } else if (std.mem.eql(u8, arg, "-mcpu")) {
                config.mcpu = args.next() orelse fatal("-mcpu requires an argument", .{});
            } else if (std.mem.startsWith(u8, arg, "-I")) {
                config.include_dirs.append(arena, arg) catch |e| oom(e);
            } else {
                template_files.append(arena, arg) catch |e| oom(e);
            }
        }
    }

    if (template_files.items.len == 0) {
        const usage =
            \\Usage: configquery [options] [template-files]
            \\
            \\Processes template files line by line. Lines starting with # are
            \\comments. Each line is NAME VALUE where VALUE is either a literal
            \\or a query starting with ?.
            \\
            \\Options:
            \\  -o <path>                 Write output to file (default: stdout)
            \\  --zig-exe [exe]           Path to zig executable (for compile queries)
            \\  -target [name]            <arch><sub>-<os>-<abi> see the targets command
            \\  -mcpu [cpu]               Specify target CPU and feature set
            \\  -I[dir]                   Add directory to include search path
            \\  --cache-dir [path]        The local cache directory
            \\
            \\Literal Values
            \\  SIZEOF_INT 4
            \\  RETSIGTYPE .void
            \\  PY_HASH "md5,sha1"
            \\  HAVE_FEATURE defined
            \\  MISSING_FEATURE undef
            \\
            \\Query syntax: NAME ? PASS|FAIL [define=DEF,...] [include=HDR,...] [COMPILE_BODY]
            \\
            \\  HAVE_ALLOCA_H ? 1|undef include=alloca.h
            \\  HAVE_FORK ? 1|undef include=unistd.h int main(){fork();}
            \\  HAVE_PRLIMIT ? 1|undef include=sys/time.h,sys/resource.h int main(){prlimit(0,0,0,0);}
            \\  HAVE_CLOSE_RANGE ? 1|undef define=_GNU_SOURCE include=unistd.h int main(){close_range(0,0,0);}
            \\
            \\configquery is purposely limited to compile-only (no link). Its up to the caller to ensure
            \\header/symbol availability matches library symbol availability.
            \\
        ;
        var stderr = std.Io.File.stderr().writer(io, &.{});
        stderr.interface.writeAll(usage) catch return stderr.err.?;
        stderr.interface.flush() catch return stderr.err.?;
        std.process.exit(1);
    }

    var out_buf: [4096]u8 = undefined;
    var out_file = if (output_path) |path| std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| fatal(
        "failed to create '{s}' with {t}",
        .{ path, err },
    ) else std.Io.File.stdout();

    defer if (output_path != null) out_file.close(io);
    var out_writer = out_file.writer(io, &out_buf);

    var error_count: u32 = 0;

    for (template_files.items) |template_path| {
        const content = std.Io.Dir.cwd().readFileAlloc(io, template_path, arena, .unlimited) catch |err| fatal(
            "failed to read '{s}' with {t}",
            .{ template_path, err },
        );
        defer arena.free(content);
        processFile(
            arena,
            io,
            &config,
            &error_count,
            &out_writer.interface,
            template_path,
            content,
        ) catch |err| switch (err) {
            error.WriteFailed => return out_writer.err.?,
            else => |e| return e,
        };
    }

    out_writer.interface.flush() catch return out_writer.err.?;
    if (error_count > 0) fatal("{} errors", .{error_count});
}

const Config = struct {
    zig_exe: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
    target_triple: ?[]const u8 = null,
    mcpu: ?[]const u8 = null,
    include_dirs: std.ArrayList([]const u8) = .empty,
};

fn processFile(
    arena: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    error_count: *u32,
    out: *std.Io.Writer,
    template_path: []const u8,
    content: []const u8,
) !void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    var line_num: u32 = 0;
    while (line_it.next()) |line_untrimmed| {
        line_num += 1;
        const line = std.mem.trim(u8, line_untrimmed, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;

        const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse {
            reportError(io, template_path, line_num, "expected 'NAME VALUE'", .{});
            error_count.* += 1;
            continue;
        };
        const config_name = line[0..first_space];
        const value_str = std.mem.trimStart(u8, line[first_space + 1 ..], " ");

        if (!std.mem.startsWith(u8, value_str, "?")) {
            try out.print("{s} {s}\n", .{ config_name, value_str });
            _ = ConfigHeaderExt.parseValue(value_str) orelse {
                reportError(io, template_path, line_num, "invalid config value '{s}'", .{value_str});
                error_count.* += 1;
            };
            continue;
        }

        // Query: NAME ? PASS|FAIL [define=...] [include=...] [COMPILE_BODY]
        const query_str = std.mem.trimStart(u8, value_str[1..], " ");
        _, const pass_end = ConfigHeaderExt.parseValue(query_str) orelse {
            reportError(io, template_path, line_num, "expected PASS_VALUE after ? but got '{s}'", .{query_str});
            error_count.* += 1;
            continue;
        };
        const pass_text = query_str[0..pass_end];
        if (pass_end >= query_str.len or query_str[pass_end] != '|') {
            reportError(io, template_path, line_num, "expected '|' after PASS_VALUE but got '{s}'", .{query_str[pass_end..]});
            error_count.* += 1;
            continue;
        }
        const after_pipe = query_str[pass_end + 1 ..];
        _, const fail_end = ConfigHeaderExt.parseValue(after_pipe) orelse {
            reportError(io, template_path, line_num, "expected FAIL_VALUE after '|' but got '{s}'", .{after_pipe});
            error_count.* += 1;
            continue;
        };
        const fail_text = after_pipe[0..fail_end];
        const query_expr = std.mem.trimStart(u8, after_pipe[fail_end..], " ");
        const success = try evalQuery(
            arena,
            io,
            config,
            out,
            config_name,
            query_expr,
            template_path,
            line_num,
            error_count,
        );
        try out.print("{s} {s}\n", .{ config_name, if (success) pass_text else fail_text });
    }
}

const ExprIterator = struct {
    const State = union(enum) {
        define: Common,
        include: Common,
        compile,
        done,
    };

    const Common = union(enum) {
        check,
        values: std.mem.SplitIterator(u8, .scalar),
    };

    pub const Error = error{ Empty, Unexpected, OutOfOrder };

    expr: []const u8,
    pos: usize = 0,
    state: State = .{ .define = .check },

    fn nextDefine(self: *ExprIterator) Error!?[]const u8 {
        const common = &self.state.define;
        if (self.nextCommon("define=", common)) |value| return value;
        self.state = .{ .include = .check };
        return null;
    }

    fn nextInclude(self: *ExprIterator) Error!?[]const u8 {
        const common = &self.state.include;
        if (self.nextCommon("include=", common)) |value| return value;
        self.state = .compile;
        return null;
    }

    fn compile(self: *ExprIterator) ?[]const u8 {
        std.debug.assert(self.state == .compile);
        self.state = .done;
        const rem = std.mem.trimStart(u8, self.expr[self.pos..], " ");
        if (rem.len == 0) return null;
        self.pos = self.expr.len;
        return rem;
    }

    fn nextCommon(self: *ExprIterator, prefix: []const u8, common: *Common) ?[]const u8 {
        switch (common.*) {
            .check => {
                const token, const new_pos = lex(self.expr, self.pos) orelse return null;
                if (!std.mem.startsWith(u8, token, prefix)) return null;
                common.* = .{ .values = std.mem.splitScalar(u8, token[prefix.len..], ',') };
                self.pos = new_pos;
            },
            .values => {},
        }
        return common.values.next();
    }

    pub const FmtError = struct {
        it: *const ExprIterator,
        err: Error,

        pub fn format(f: *const FmtError, writer: *std.Io.Writer) error{WriteFailed}!void {
            switch (f.err) {
                error.Empty => try writer.writeAll("expression cannot be empty"),
                error.Unexpected => try writer.print(
                    "unexpected content at position {}: '{s}'",
                    .{ f.it.pos, f.it.expr[f.it.pos..] },
                ),
                error.OutOfOrder => try writer.print(
                    "clauses out of order at position {}: '{s}' (expected: [define ...] [include ...] [compile ...])",
                    .{ f.it.pos, f.it.expr[f.it.pos..] },
                ),
            }
        }
    };

    pub fn fmtError(it: *const ExprIterator, err: Error) FmtError {
        return .{ .it = it, .err = err };
    }
};

/// Parse a value starting at pos. Values can be:
///   bare:   undef, defined, true, false, INTEGER
///   ident:  'LITERAL'
///   string: "LITERAL"
/// Returns the value (including quotes) and the position after it.
fn lex(s: []const u8, pos: usize) ?struct { []const u8, usize } {
    const start = std.mem.indexOfNonePos(u8, s, pos, " ") orelse return null;
    if (std.mem.indexOfScalarPos(u8, s, start, ' ')) |end| return .{ s[start..end], end + 1 };
    return .{ s[start..], s.len };
}

test ExprIterator {
    // include only
    {
        var it = ExprIterator{ .expr = "include=alloca.h" };
        try std.testing.expect(try it.nextDefine() == null);
        try std.testing.expectEqualStrings("alloca.h", (try it.nextInclude()).?);
        try std.testing.expect(try it.nextInclude() == null);
        try std.testing.expect(it.compile() == null);
    }
    // multiple includes with commas
    {
        var it = ExprIterator{ .expr = "include=sys/time.h,sys/resource.h" };
        try std.testing.expect(try it.nextDefine() == null);
        try std.testing.expectEqualStrings("sys/time.h", (try it.nextInclude()).?);
        try std.testing.expectEqualStrings("sys/resource.h", (try it.nextInclude()).?);
        try std.testing.expect(try it.nextInclude() == null);
        try std.testing.expect(it.compile() == null);
    }
    // define + include + compile body
    {
        var it = ExprIterator{
            .expr = "define=_GNU_SOURCE include=unistd.h int main(){close_range(0,0,0);}",
        };
        try std.testing.expectEqualStrings("_GNU_SOURCE", (try it.nextDefine()).?);
        try std.testing.expect(try it.nextDefine() == null);
        try std.testing.expectEqualStrings("unistd.h", (try it.nextInclude()).?);
        try std.testing.expect(try it.nextInclude() == null);
        try std.testing.expectEqualStrings("int main(){close_range(0,0,0);}", it.compile().?);
    }
    // compile body only
    {
        var it = ExprIterator{ .expr = "int main(){return 0;}" };
        try std.testing.expect(try it.nextDefine() == null);
        try std.testing.expect(try it.nextInclude() == null);
        try std.testing.expectEqualStrings("int main(){return 0;}", it.compile().?);
    }
    // empty
    {
        var it = ExprIterator{ .expr = "" };
        try std.testing.expect(try it.nextDefine() == null);
        try std.testing.expect(try it.nextInclude() == null);
        try std.testing.expect(it.compile() == null);
    }
}

fn evalQuery(
    arena: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    out: *std.Io.Writer,
    config_name: []const u8,
    expr: []const u8,
    file_path: []const u8,
    line_num: u32,
    errors: *u32,
) error{WriteFailed}!bool {
    var it = ExprIterator{ .expr = expr };

    while (it.nextDefine() catch |err| {
        exprErr(io, file_path, line_num, errors, &it, err);
        return false;
    }) |_| {}

    var has_headers = false;
    while (it.nextInclude() catch |err| {
        exprErr(io, file_path, line_num, errors, &it, err);
        return false;
    }) |header| {
        _ = header;
        has_headers = true;
    }
    if (!has_headers and it.compile() == null) return true;
    return try doCompile(
        arena,
        io,
        config,
        out,
        config_name,
        expr,
        file_path,
        line_num,
        errors,
    );
}

// assumes expr is valid
fn writeSource(w: *std.Io.Writer, expr: []const u8) error{WriteFailed}!void {
    var it = ExprIterator{ .expr = expr };
    while (it.nextDefine() catch unreachable) |d| {
        try w.print("#define {s}\n", .{d});
    }
    while (it.nextInclude() catch unreachable) |h| {
        try w.print("#include <{s}>\n", .{h});
    }
    if (it.compile()) |c| try w.writeAll(c);
    try w.writeByte('\n');
    try w.flush();
}

fn exprErr(io: std.Io, file_path: []const u8, line_num: u32, errors: *u32, it: *const ExprIterator, err: ExprIterator.Error) void {
    reportError(io, file_path, line_num, "bad expression: {f}", .{it.fmtError(err)});
    errors.* += 1;
}

fn doCompile(
    arena: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    out: *std.Io.Writer,
    config_name: []const u8,
    expr: []const u8,
    file_path: []const u8,
    line_num: u32,
    errors: *u32,
) error{WriteFailed}!bool {
    const zig_exe = config.zig_exe orelse fatal("compile query requires --zig-exe", .{});
    const cache_dir = config.cache_dir orelse fatal("compile query requires --cache-dir", .{});
    const sep = std.fs.path.sep_str;
    const pid = switch (@import("builtin").os.tag) {
        .linux => std.os.linux.getpid(),
        .macos, .ios => std.c.getpid(),
        else => @compileError("unsupported OS"),
    };
    const tid = std.Thread.getCurrentId();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = std.fmt.bufPrint(
        &path_buf,
        "{s}" ++ sep ++ "tmp" ++ sep ++ "configquery-{}-{}.c",
        .{ cache_dir, pid, tid },
    ) catch unreachable;
    std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(source_path).?) catch |err|
        fatal("failed to create '{s}': {t}", .{ std.fs.path.dirname(source_path).?, err });

    {
        var file = std.Io.Dir.cwd().createFile(io, source_path, .{}) catch |err|
            fatal("failed to create '{s}' with {t}", .{ source_path, err });
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var w = file.writer(io, &buf);
        writeSource(&w.interface, expr) catch fatal("failed to write source: {t}", .{w.err.?});
        std.debug.assert(w.interface.end == 0);
    }

    const argv_options = [_]?[]const u8{
        zig_exe,
        "build-obj",
        "--cache-dir",
        cache_dir,
        if (config.target_triple != null) "-target" else null,
        config.target_triple,
        if (config.mcpu != null) "-mcpu" else null,
        config.mcpu,
        "-lc",
        "-fno-emit-bin",
        source_path,
    };
    const max_argv_count = argv_options.len + config.include_dirs.items.len;
    var argv = std.ArrayList([]const u8).initCapacity(arena, max_argv_count) catch |e| oom(e);
    var argv_options_remaining = argv_options.len;
    for (argv_options) |maybe_arg| {
        if (maybe_arg) |arg| {
            argv.appendAssumeCapacity(arg);
            argv_options_remaining -= 1;
        }
    }
    for (config.include_dirs.items) |dir| argv.appendAssumeCapacity(dir);
    std.debug.assert(argv.items.len + argv_options_remaining == max_argv_count);

    const result = std.process.run(arena, io, .{
        .argv = argv.items,
    }) catch |err| fatal("zig build-obj failed with {t}", .{err});
    var delete_source = true;
    defer if (delete_source) std.Io.Dir.cwd().deleteFile(io, source_path) catch |err|
        fatal("failed to delete '{s}': {t}", .{ source_path, err });
    switch (result.term) {
        .exited => |code| if (code == 0) return true,
        inline else => |sig, kind| {
            reportError(io, file_path, line_num, "zig build-obj terminated ({t}) with {}", .{ kind, sig });
            errors.* += 1;
            return false;
        },
    }

    // Write compile errors as comments in the output
    try out.print("# compilation for '{s}' failed with the following:\n", .{config_name});
    var stderr_it = std.mem.splitScalar(u8, result.stderr, '\n');
    while (stderr_it.next()) |stderr_line| {
        if (stderr_line.len > 0) try out.print("# {s}\n", .{stderr_line});
    }

    // Expected errors (file not found, undeclared function, etc.) mean the
    // feature is not available. Unexpected errors indicate a bad template.
    var has_expected_error = false;
    var has_unexpected_error = false;
    var err_it = std.mem.splitScalar(u8, result.stderr, '\n');
    while (err_it.next()) |err_line_raw| {
        const err_line = std.mem.trimEnd(u8, err_line_raw, "\r");
        if (err_line.len == 0) continue;
        const error_prefix = "error: ";
        const error_start = std.mem.indexOf(u8, err_line, error_prefix) orelse continue;
        const err_msg = err_line[error_start + error_prefix.len ..];
        if (std.mem.endsWith(u8, err_msg, "file not found") or
            std.mem.startsWith(u8, err_msg, "call to undeclared function ") or
            std.mem.startsWith(u8, err_msg, "call to undeclared library function ") or
            std.mem.startsWith(u8, err_msg, "use of undeclared identifier") or
            std.mem.startsWith(u8, err_msg, "invalid instruction mnemonic") or
            std.mem.startsWith(u8, err_msg, "function definition is not allowed") or
            std.mem.startsWith(u8, err_msg, "unknown type name") or
            std.mem.startsWith(u8, err_msg, "no member named") or
            std.mem.startsWith(u8, err_msg, "incomplete definition of type") or
            std.mem.startsWith(u8, err_msg, "implicit declaration of function") or
            std.mem.startsWith(u8, err_msg, "redefinition of"))
        {
            has_expected_error = true;
        } else {
            has_unexpected_error = true;
        }
    }

    if (has_unexpected_error and !has_expected_error) {
        delete_source = false;
        reportError(io, file_path, line_num, "compile check failed with unexpected error(s):\n{s}", .{result.stderr});
        errors.* += 1;
    }

    return false;
}

fn reportError(io: std.Io, file: []const u8, line: u32, comptime fmt: []const u8, args: anytype) void {
    var stderr = std.Io.File.stderr().writer(io, &.{});
    stderr.interface.print("{s}:{}: " ++ fmt ++ "\n", .{ file, line } ++ args) catch
        fatal("failed to write to stderr: {t}", .{stderr.err.?});
}

fn oom(err: error{OutOfMemory}) noreturn {
    fatal("{s}", .{@errorName(err)});
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}

const std = @import("std");
const ConfigHeaderExt = @import("ConfigHeaderExt.zig");
