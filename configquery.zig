pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var template_files: std.ArrayList([]const u8) = .empty;
    var output_path: ?[]const u8 = null;
    var header_template_path: ?[]const u8 = null;
    var config: Config = .{};

    {
        var args = try init.minimal.args.iterateAllocator(arena);
        _ = args.next();
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "-o")) {
                output_path = args.next() orelse fatal("-o requires an argument", .{});
            } else if (std.mem.eql(u8, arg, "--template")) {
                header_template_path = args.next() orelse fatal("--template requires an argument", .{});
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
            \\Usage: configquery --template <header.h.in> [options] [template-files]
            \\
            \\Processes template files line by line. Lines starting with # are
            \\comments. Each line is NAME VALUE where VALUE is either a literal
            \\or a query starting with ?. The resulting values replace the
            \\"#undef NAME" lines of the autoconf header template, every
            \\"#undef" line needs a value and every value must be used.
            \\
            \\Options:
            \\  --template <path>         The autoconf header template (i.e. pyconfig.h.in)
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
        var stderr = std.Io.File.stderr().writerStreaming(io, &.{});
        stderr.interface.writeAll(usage) catch return stderr.err.?;
        stderr.interface.flush() catch return stderr.err.?;
        std.process.exit(1);
    }

    const header_template_path_ = header_template_path orelse fatal("missing --template", .{});
    const header_template = std.Io.Dir.cwd().readFileAlloc(io, header_template_path_, arena, .unlimited) catch |err| fatal(
        "failed to read '{s}' with {t}",
        .{ header_template_path_, err },
    );

    var out_buf: [4096]u8 = undefined;
    var out_file = if (output_path) |path| std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| fatal(
        "failed to create '{s}' with {t}",
        .{ path, err },
    ) else std.Io.File.stdout();
    defer if (output_path != null) out_file.close(io);
    var out_writer = out_file.writerStreaming(io, &out_buf);
    const out = &out_writer.interface;

    var queries: std.ArrayList(Query) = .empty;
    var name_set: std.StringHashMapUnmanaged(u32) = .empty;
    var values: std.StringArrayHashMapUnmanaged(Value) = .empty;
    var error_count: u32 = 0;

    for (template_files.items) |template_path| {
        const content = std.Io.Dir.cwd().readFileAlloc(io, template_path, arena, .unlimited) catch |err| fatal(
            "failed to read '{s}' with {t}",
            .{ template_path, err },
        );
        var line_it = std.mem.splitScalar(u8, content, '\n');
        var line_num: u32 = 0;
        while (line_it.next()) |line_untrimmed| {
            line_num += 1;
            switch (parseLine(line_untrimmed)) {
                .skip => continue,
                .err => |msg| {
                    reportError(io, template_path, line_num, "{s}", .{msg});
                    error_count += 1;
                },
                .literal => |lit| {
                    checkUnique(arena, &name_set, io, template_path, line_num, lit.config_name, &error_count);
                    values.put(arena, lit.config_name, .{ .text = lit.value_str }) catch |e| oom(e);
                },
                .query => |input| {
                    checkUnique(arena, &name_set, io, template_path, line_num, input.config_name, &error_count);
                    if (input.includes.len > 0 or input.compile_body.len > 0) {
                        queries.append(arena, .{
                            .input = input,
                            .file_path = template_path,
                            .line_num = line_num,
                        }) catch |e| oom(e);
                    } else {
                        values.put(arena, input.config_name, .{ .text = input.pass_text }) catch |e| oom(e);
                    }
                },
            }
        }
    }

    if (error_count > 0) fatal("{} errors in config templates", .{error_count});

    if (queries.items.len > 0) {
        const zig_exe = config.zig_exe orelse fatal("compile query requires --zig-exe", .{});
        const cache_dir = config.cache_dir orelse fatal("compile query requires --cache-dir", .{});
        const argv_template = buildArgvTemplate(arena, zig_exe, &config);

        var group: std.Io.Group = .init;
        for (queries.items, 0..) |*q, i| {
            group.async(io, runCompileCheck, .{ arena, io, q, argv_template, cache_dir, i });
        }
        group.await(io) catch |err| switch (err) {
            error.Canceled => fatal("canceled", .{}),
        };

        for (queries.items) |*q| {
            const result = q.result orelse fatal("compile query for '{s}' has no result", .{q.input.config_name});
            const value_text = if (result.success) q.input.pass_text else q.input.fail_text;
            values.put(arena, q.input.config_name, .{ .text = value_text, .comments = result.error_comments }) catch |e| oom(e);
            if (result.fatal_msg) |msg| {
                error_count += 1;
                reportError(io, q.file_path, q.line_num, "{s}", .{msg});
            }
        }
    }

    error_count += renderAutoconfUndef(io, header_template_path_, header_template, &values, out) catch return out_writer.err.?;
    for (values.keys(), values.values()) |name, value| {
        if (value.used) continue;
        reportError(io, header_template_path_, 0, "config value unused: {s}", .{name});
        error_count += 1;
    }
    out.flush() catch return out_writer.err.?;
    if (error_count > 0) fatal("{} errors", .{error_count});
}

const Value = struct {
    text: []const u8,
    /// Lines that start with "// ".
    comments: []const u8 = "",
    used: bool = false,
};

/// Mirrors how std.Build.Step.ConfigHeader renders its autoconf_undef style.
fn renderAutoconfUndef(
    io: std.Io,
    template_path: []const u8,
    contents: []const u8,
    values: *std.StringArrayHashMapUnmanaged(Value),
    w: *std.Io.Writer,
) error{WriteFailed}!u32 {
    const newline = blk: {
        const lf_index = std.mem.indexOfScalar(u8, contents, '\n') orelse break :blk "\n";
        break :blk if (lf_index > 0 and contents[lf_index - 1] == '\r') "\r\n" else "\n";
    };

    try w.writeAll("/* This file was generated by configquery. */");
    try w.writeAll(newline);

    var error_count: u32 = 0;
    var line_num: u32 = 0;
    var line_it = std.mem.splitScalar(u8, contents, '\n');
    while (line_it.next()) |raw_line| {
        line_num += 1;
        const last_line = line_it.index == null;
        const line = std.mem.trimEnd(u8, raw_line, "\r");

        const name = blk: {
            if (!std.mem.startsWith(u8, line, "#")) break :blk null;
            var it = std.mem.tokenizeAny(u8, line[1..], " \t\r");
            const directive = it.next() orelse break :blk null;
            if (!std.mem.eql(u8, directive, "undef")) break :blk null;
            break :blk it.next();
        } orelse {
            try w.writeAll(line);
            if (!last_line) try w.writeAll(newline);
            continue;
        };
        const value = values.getPtr(name) orelse {
            reportError(io, template_path, line_num, "unspecified config value: {s}", .{name});
            error_count += 1;
            continue;
        };
        value.used = true;
        var comment_it = std.mem.splitScalar(u8, value.comments, '\n');
        while (comment_it.next()) |comment| if (comment.len > 0) {
            // a trailing backslash would continue the comment onto the next line
            try w.writeAll(std.mem.trimEnd(u8, comment, "\\ \t\r"));
            try w.writeAll(newline);
        };
        switch (ConfigHeaderExt.parseValue(value.text).?) {
            .undef => try w.print("/* #undef {s} */", .{name}),
            .defined => try w.print("#define {s}", .{name}),
            .boolean => |b| try w.print("#define {s} {c}", .{ name, @as(u8, '0') + @intFromBool(b) }),
            .int => |i| try w.print("#define {s} {d}", .{ name, i }),
            .ident => |ident| if (ident.len > 0)
                try w.print("#define {s} {s}", .{ name, ident })
            else
                try w.print("#define {s}", .{name}),
            .string => |string| try w.print("#define {s} \"{f}\"", .{ name, std.zig.fmtString(string) }),
        }
        try w.writeAll(newline);
    }
    return error_count;
}

const Config = struct {
    zig_exe: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
    target_triple: ?[]const u8 = null,
    mcpu: ?[]const u8 = null,
    include_dirs: std.ArrayList([]const u8) = .empty,
};

const Line = union(enum) {
    skip,
    err: []const u8,
    literal: struct {
        config_name: []const u8,
        value_str: []const u8,
    },
    query: QueryInput,
};

const QueryInput = struct {
    config_name: []const u8,
    pass_text: []const u8,
    fail_text: []const u8,
    defines: []const u8,
    includes: []const u8,
    compile_body: []const u8,
};

const Query = struct {
    input: QueryInput,
    file_path: []const u8,
    line_num: u32,
    result: ?Result = null,
    pub const Result = struct {
        success: bool,
        error_comments: []const u8,
        fatal_msg: ?[]const u8,
    };
};

fn parseLine(line_untrimmed: []const u8) Line {
    const line = std.mem.trim(u8, line_untrimmed, &std.ascii.whitespace);
    if (line.len == 0 or line[0] == '#') return .skip;

    const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return .{ .err = "expected 'NAME VALUE'" };
    const config_name = line[0..first_space];
    const value_str = std.mem.trimStart(u8, line[first_space + 1 ..], " ");

    if (!std.mem.startsWith(u8, value_str, "?")) {
        _ = ConfigHeaderExt.parseValue(value_str) orelse
            return .{ .err = "invalid config value" };
        return .{ .literal = .{ .config_name = config_name, .value_str = value_str } };
    }

    const pass_str, const after_pass = scanConfigValue(value_str, 1);
    _ = ConfigHeaderExt.parseValue(pass_str) orelse return .{ .err = "expected PASS_VALUE after ?" };
    const pipe_index = skipWhitespace(value_str, after_pass);
    if (pipe_index >= value_str.len or value_str[pipe_index] != '|')
        return .{ .err = "expected '|' after PASS_VALUE" };
    const fail_str, const after_fail = scanConfigValue(value_str, pipe_index + 1);
    _ = ConfigHeaderExt.parseValue(fail_str) orelse return .{ .err = "expected FAIL_VALUE after '|'" };
    var rest = std.mem.trimStart(u8, value_str[after_fail..], " ");
    const defines = parseExprClause(&rest, "define=");
    const includes = parseExprClause(&rest, "include=");
    if (includes.len == 0 and rest.len == 0) return .{ .err = "query has no include nor code to check" };
    return .{ .query = .{
        .config_name = config_name,
        .pass_text = pass_str,
        .fail_text = fail_str,
        .defines = defines,
        .includes = includes,
        .compile_body = rest,
    } };
}

fn skipWhitespace(str: []const u8, start: usize) usize {
    var i = start;
    while (true) : (i += 1) {
        if (i >= str.len) return i;
        if (!std.ascii.isWhitespace(str[i])) return i;
    }
}

fn scanConfigValue(str: []const u8, start: usize) struct { []const u8, usize } {
    const i = skipWhitespace(str, start);
    if (i >= str.len) return .{ "", str.len };
    switch (str[i]) {
        'a'...'z', 'A'...'Z', '_' => return scanAlphanum(str, i),
        '-', '0'...'9' => return scanInt(str, i),
        // TODO: handle :IDENTICAL and "QUOTED_STRING"
        else => |ch| std.debug.panic("todo '{c}'", .{ch}),
    }
}
fn scanAlphanum(str: []const u8, start: usize) struct { []const u8, usize } {
    switch (str[start]) {
        'a'...'z', 'A'...'Z', '_' => {},
        else => unreachable,
    }
    var i = start + 1;
    while (true) : (i += 1) {
        if (i >= str.len) return .{ str[start..], i };
        switch (str[i]) {
            'a'...'z', 'A'...'Z', '_', '0'...'9' => {},
            else => return .{ str[start..i], i },
        }
    }
}
fn scanInt(str: []const u8, start: usize) struct { []const u8, usize } {
    switch (str[start]) {
        '-', '0'...'9' => {},
        else => unreachable,
    }
    var i = start + 1;
    while (true) : (i += 1) {
        if (i >= str.len) return .{ str[start..], i };
        switch (str[i]) {
            '0'...'9' => {},
            else => return .{ str[start..i], i },
        }
    }
}

fn parseExprClause(rest: *[]const u8, prefix: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, rest.*, prefix)) return "";
    const after_prefix = rest.*[prefix.len..];
    const end = std.mem.indexOfScalar(u8, after_prefix, ' ') orelse after_prefix.len;
    rest.* = std.mem.trimStart(u8, after_prefix[end..], " ");
    return after_prefix[0..end];
}

fn buildArgvTemplate(
    arena: std.mem.Allocator,
    zig_exe: []const u8,
    config: *const Config,
) []const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(arena, zig_exe) catch |e| oom(e);
    argv.append(arena, "build-obj") catch |e| oom(e);
    if (config.target_triple) |t| {
        argv.append(arena, "-target") catch |e| oom(e);
        argv.append(arena, t) catch |e| oom(e);
    }
    if (config.mcpu) |m| {
        argv.append(arena, "-mcpu") catch |e| oom(e);
        argv.append(arena, m) catch |e| oom(e);
    }
    argv.append(arena, "-lc") catch |e| oom(e);
    argv.append(arena, "-fno-emit-bin") catch |e| oom(e);
    for (config.include_dirs.items) |dir| argv.append(arena, dir) catch |e| oom(e);
    return argv.toOwnedSlice(arena) catch |e| oom(e);
}

fn runCompileCheck(
    arena: std.mem.Allocator,
    io: std.Io,
    query: *Query,
    argv_template: []const []const u8,
    cache_dir: []const u8,
    index: usize,
) void {
    query.result = doCompileCheck(arena, io, query, argv_template, cache_dir, index);
}

fn doCompileCheck(
    arena: std.mem.Allocator,
    io: std.Io,
    query: *const Query,
    argv_template: []const []const u8,
    cache_dir: []const u8,
    index: usize,
) Query.Result {
    const sep = std.fs.path.sep_str;

    const pid = switch (@import("builtin").os.tag) {
        .linux => std.os.linux.getpid(),
        .macos, .ios => std.c.getpid(),
        else => @compileError("unsupported OS"),
    };
    var task_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const task_dir = std.fmt.bufPrint(&task_dir_buf, "{s}" ++ sep ++ "tmp" ++ sep ++ "cq-{}-{}", .{ cache_dir, pid, index }) catch
        fatal("cache-dir path too long", .{});
    std.Io.Dir.cwd().createDirPath(io, task_dir) catch |err|
        fatal("failed to create '{s}': {t}", .{ task_dir, err });

    var source_buf: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = std.fmt.bufPrint(&source_buf, "{s}" ++ sep ++ "check.c", .{task_dir}) catch
        fatal("source path too long", .{});

    {
        var file = std.Io.Dir.cwd().createFile(io, source_path, .{}) catch |err|
            fatal("failed to create '{s}' with {t}", .{ source_path, err });
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var w = file.writer(io, &buf);
        writeSource(&w.interface, &query.input) catch fatal("failed to write source: {t}", .{w.err.?});
        std.debug.assert(w.interface.end == 0);
    }

    const argv = blk: {
        var a = std.ArrayList([]const u8).initCapacity(arena, argv_template.len + 3) catch |e| oom(e);
        a.appendSliceAssumeCapacity(argv_template);
        a.appendAssumeCapacity("--cache-dir");
        a.appendAssumeCapacity(task_dir);
        a.appendAssumeCapacity(source_path);
        break :blk a.items;
    };

    const result = std.process.run(arena, io, .{
        .argv = argv,
    }) catch |err| fatal("zig build-obj failed with {t}", .{err});

    var delete_task_dir = true;
    defer if (delete_task_dir) std.Io.Dir.cwd().deleteTree(io, task_dir) catch {};

    switch (result.term) {
        .exited => |code| if (code == 0) return .{
            .success = true,
            .error_comments = "",
            .fatal_msg = null,
        },
        inline else => |sig, kind| {
            return .{
                .success = false,
                .error_comments = "",
                .fatal_msg = std.fmt.allocPrint(arena, "zig build-obj terminated ({t}) with {}", .{ kind, sig }) catch |e| oom(e),
            };
        },
    }

    var comments: std.ArrayList(u8) = .empty;
    comments.appendSlice(arena, std.fmt.allocPrint(arena, "// compilation for '{s}' failed with the following:\n", .{query.input.config_name}) catch |e| oom(e)) catch |e| oom(e);
    var stderr_it = std.mem.splitScalar(u8, result.stderr, '\n');
    while (stderr_it.next()) |stderr_line| {
        if (stderr_line.len > 0) comments.appendSlice(arena, std.fmt.allocPrint(arena, "// {s}\n", .{stderr_line}) catch |e| oom(e)) catch |e| oom(e);
    }

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

    var fatal_msg: ?[]const u8 = null;
    if (has_unexpected_error and !has_expected_error) {
        delete_task_dir = false;
        fatal_msg = std.fmt.allocPrint(
            arena,
            "compile check failed with unexpected error(s):\n{s}",
            .{result.stderr},
        ) catch |e| oom(e);
    }

    return .{
        .success = false,
        .error_comments = comments.toOwnedSlice(arena) catch |e| oom(e),
        .fatal_msg = fatal_msg,
    };
}

fn checkUnique(
    arena: std.mem.Allocator,
    seen: *std.StringHashMapUnmanaged(u32),
    io: std.Io,
    file: []const u8,
    line: u32,
    name: []const u8,
    error_count: *u32,
) void {
    const result = seen.getOrPut(arena, name) catch |e| oom(e);
    if (result.found_existing) {
        reportError(io, file, line, "duplicate config name '{s}' (first seen on line {})", .{ name, result.value_ptr.* });
        error_count.* += 1;
    } else {
        result.value_ptr.* = line;
    }
}

fn writeSource(w: *std.Io.Writer, q: *const QueryInput) error{WriteFailed}!void {
    if (q.defines.len > 0) {
        var it = std.mem.splitScalar(u8, q.defines, ',');
        while (it.next()) |d| try w.print("#define {s}\n", .{d});
    }
    if (q.includes.len > 0) {
        var it = std.mem.splitScalar(u8, q.includes, ',');
        while (it.next()) |h| try w.print("#include <{s}>\n", .{h});
    }
    if (q.compile_body.len != 0) {
        try w.writeAll(q.compile_body);
        try w.writeByte('\n');
    }
    try w.flush();
}

test parseLine {
    {
        const q = parseLine("HAVE_ALLOCA_H ? 1|undef include=alloca.h").query;
        try std.testing.expectEqualStrings("HAVE_ALLOCA_H", q.config_name);
        try std.testing.expectEqualStrings("1", q.pass_text);
        try std.testing.expectEqualStrings("undef", q.fail_text);
        try std.testing.expectEqualStrings("", q.defines);
        try std.testing.expectEqualStrings("alloca.h", q.includes);
        try std.testing.expectEqualStrings("", q.compile_body);
    }
    {
        const q = parseLine("HAVE_CLOSE_RANGE ? 1|undef define=_GNU_SOURCE include=unistd.h int main(){close_range(0,0,0);}").query;
        try std.testing.expectEqualStrings("_GNU_SOURCE", q.defines);
        try std.testing.expectEqualStrings("unistd.h", q.includes);
        try std.testing.expectEqualStrings("int main(){close_range(0,0,0);}", q.compile_body);
    }
    {
        const q = parseLine("HAVE_PRLIMIT ? 1|undef include=sys/time.h,sys/resource.h int main(){prlimit(0,0,0,0);}").query;
        try std.testing.expectEqualStrings("sys/time.h,sys/resource.h", q.includes);
        try std.testing.expectEqualStrings("int main(){prlimit(0,0,0,0);}", q.compile_body);
    }
    {
        const q = parseLine("HAVE_BUILTIN_ATOMIC ? 1|undef int main(){return 0;}").query;
        try std.testing.expectEqualStrings("", q.defines);
        try std.testing.expectEqualStrings("", q.includes);
        try std.testing.expectEqualStrings("int main(){return 0;}", q.compile_body);
    }
    {
        const lit = parseLine("SIZEOF_INT 4").literal;
        try std.testing.expectEqualStrings("SIZEOF_INT", lit.config_name);
        try std.testing.expectEqualStrings("4", lit.value_str);
    }
    try std.testing.expect(parseLine("") == .skip);
    try std.testing.expect(parseLine("# comment") == .skip);
    try std.testing.expect(parseLine("NOVALUE") == .err);
}

fn reportError(io: std.Io, file: []const u8, line: u32, comptime fmt: []const u8, args: anytype) void {
    var stderr = std.Io.File.stderr().writerStreaming(io, &.{});
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
