//! Shows where conzig's pyconfig.h differs from what upstream's configure gets on this machine. It
//! needs the machine's own compiler and tools, so it's a one-off check and the build doesn't use it.
//! A difference isn't always a mistake, configure sees the machine's libc and libraries, and conzig
//! sees Zig's libc and only the libraries the build links.

const usage = "usage: checkconfig UPSTREAM_DIR WORK_DIR CONZIG_HEADER\n";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const upstream_dir = args.next() orelse fatal("{s}", .{usage});
    const work_dir = args.next() orelse fatal("{s}", .{usage});
    const conzig_path = args.next() orelse fatal("{s}", .{usage});
    if (args.next() != null) fatal("{s}", .{usage});

    const upstream_abs = try std.fs.path.resolve(arena, &.{ try std.process.currentPathAlloc(io, arena), upstream_dir });
    const configure = try std.fs.path.join(arena, &.{ upstream_abs, "configure" });

    // the flags would change the result and ZIG_PROGRESS is for the build that's running this
    const environ = init.environ_map;
    for ([_][]const u8{ "CFLAGS", "CPPFLAGS", "CXXFLAGS", "LDFLAGS", "LIBS", "CONFIG_SITE", "ZIG_PROGRESS" }) |name| {
        _ = environ.swapRemove(name);
    }
    const result = std.process.run(arena, io, .{
        .argv = &.{ "sh", configure, "--without-ensurepip" },
        .cwd = .{ .path = work_dir },
        .environ_map = environ,
    }) catch |err| fatal("failed to run configure with {t}, this step needs a shell", .{err});
    if (result.term != .exited or result.term.exited != 0) fatal(
        "configure failed, see {s}/config.log\n{s}",
        .{ work_dir, result.stderr },
    );

    const template_path = try std.fs.path.join(arena, &.{ upstream_dir, "pyconfig.h.in" });
    const configure_path = try std.fs.path.join(arena, &.{ work_dir, "pyconfig.h" });
    const template = readFile(arena, io, cwd, template_path);
    const conzig_values = try parseHeader(arena, readFile(arena, io, cwd, conzig_path));
    const configure_values = try parseHeader(arena, readFile(arena, io, cwd, configure_path));

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const w = &stdout.interface;
    var total: usize = 0;
    var different: usize = 0;
    var lines = std.mem.splitScalar(u8, template, '\n');
    while (lines.next()) |line| {
        const name = undefName(line) orelse continue;
        total += 1;
        const from_conzig = conzig_values.get(name) orelse fatal("{s} doesn't have {s}", .{ conzig_path, name });
        const from_configure = configure_values.get(name) orelse fatal("{s} doesn't have {s}", .{ configure_path, name });
        if (std.mem.eql(u8, from_conzig, from_configure)) continue;
        different += 1;
        w.print("{s}: conzig {s}, configure {s}\n", .{ name, from_conzig, from_configure }) catch return stdout.err.?;
    }
    w.print("{} of {} values differ, see {s}/config.log for why configure got its answers\n", .{ different, total, work_dir }) catch return stdout.err.?;
    w.flush() catch return stdout.err.?;
}

fn readFile(arena: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8) []const u8 {
    return cwd.readFileAlloc(io, path, arena, .unlimited) catch |err| fatal("failed to read '{s}' with {t}", .{ path, err });
}

fn undefName(line: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, line, " \t\r");
    const first = it.next() orelse return null;
    if (std.mem.eql(u8, first, "#undef")) return it.next();
    if (!std.mem.eql(u8, first, "#")) return null;
    if (!std.mem.eql(u8, it.next() orelse return null, "undef")) return null;
    return it.next();
}

/// Maps each name to the text of its value, or `undef`.
fn parseHeader(arena: std.mem.Allocator, header: []const u8) error{OutOfMemory}!std.StringHashMapUnmanaged([]const u8) {
    var values: std.StringHashMapUnmanaged([]const u8) = .empty;
    // configure also defines WORDS_BIGENDIAN in here, for universal builds which we don't do
    var universal = false;
    var lines = std.mem.splitScalar(u8, header, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "#if defined AC_APPLE_UNIVERSAL_BUILD")) {
            universal = true;
            continue;
        }
        if (universal) {
            if (std.mem.startsWith(u8, trimmed, "#else")) universal = false;
            continue;
        }
        var it = std.mem.tokenizeAny(u8, trimmed, " \t");
        const first = it.next() orelse continue;
        if (std.mem.eql(u8, first, "/*")) {
            const second = it.next() orelse continue;
            if (std.mem.eql(u8, second, "#")) {
                if (!std.mem.eql(u8, it.next() orelse continue, "undef")) continue;
            } else if (!std.mem.eql(u8, second, "#undef")) continue;
            try values.put(arena, it.next() orelse continue, "undef");
            continue;
        }
        const name = if (std.mem.eql(u8, first, "#define"))
            it.next() orelse continue
        else if (std.mem.eql(u8, first, "#") and std.mem.eql(u8, it.next() orelse continue, "define"))
            it.next() orelse continue
        else
            continue;
        const value = std.mem.trim(u8, it.rest(), " \t");
        try values.put(arena, name, if (value.len == 0) "defined" else value);
    }
    return values;
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");
