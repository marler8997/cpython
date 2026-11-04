//! Maintains config.txt, run it with `zig build update-config`. See "Generating static config" in
//! README.md.
//!
//! It enumerates every combination of inputs that should have been tested, and only tests the ones
//! config.txt doesn't list yet. Testing runs upstream's configure with zig cc in cross compile mode,
//! so it doesn't execute anything for the target and the result doesn't depend on this machine.
//!
//! Every update expands config.txt into the tested combinations, adds the new ones, then reduces
//! everything back down. The reduction is the idea behind a multi-valued decision diagram printed as
//! flat lines: with a fixed input order, the same combinations always give the same file.

const usage =
    \\usage: updateconfig ZIG_EXE [MODE]
    \\
    \\  (no mode)  test the combinations config.txt doesn't list yet and add them
    \\  --verify   test every combination again for this zig version and change nothing, a
    \\             different result means an input that affects config is missing
    \\  --check    test nothing, fail if config.txt is missing a combination
    \\
;

/// configure can't answer these in cross compile mode because they need to run a program.
const cross_answers = [_]struct { []const u8, []const u8 }{
    .{ "ac_cv_file__dev_ptmx", "yes" },
    .{ "ac_cv_file__dev_ptc", "no" },
    .{ "ac_cv_buggy_getaddrinfo", "no" },
    .{ "ac_cv_computed_gotos", "yes" },
    .{ "ac_cv_working_tzset", "yes" },
    .{ "ac_cv_broken_sem_getvalue", "no" },
    .{ "ac_cv_pthread_system_supported", "yes" },
};

/// libSystem.tbd has these so they link, but zig's headers don't declare them for this code. That
/// includes util.h and pty.h which it doesn't ship, while configure only checks that they link.
const macos_answers = [_]struct { []const u8, []const u8 }{
    .{ "ac_cv_func_openpty", "no" },
    .{ "ac_cv_lib_util_openpty", "no" },
    .{ "ac_cv_lib_bsd_openpty", "no" },
    .{ "ac_cv_func_forkpty", "no" },
    .{ "ac_cv_lib_util_forkpty", "no" },
    .{ "ac_cv_lib_bsd_forkpty", "no" },
    .{ "ac_cv_search_login_tty", "no" },
    .{ "ac_cv_func_sendfile", "no" },
    .{ "ac_cv_lib_sendfile_sendfile", "no" },
    // without openpty, os.openpty falls back to /dev/ptmx and skips the STREAMS calls macOS doesn't
    // have only when this is set
    .{ "ac_cv_file__dev_ptc", "yes" },
};

/// A fixed value so the result is the same on every machine. It only has to be different from the
/// host we pass to configure, which uses "unknown" as its vendor.
const build_triple = "x86_64-pc-linux-gnu";

/// Python needs getauxval to link, which glibc added in this version.
const oldest_glibc: std.SemanticVersion = .{ .major = 2, .minor = 16, .patch = 0 };

const config_path = "config.txt";
const work_root = ".zig-cache/update-config";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const zig_exe = args.next() orelse fatal("{s}", .{usage});
    const mode: enum { update, verify, check } = if (args.next()) |arg| blk: {
        if (std.mem.eql(u8, arg, "--verify")) break :blk .verify;
        if (std.mem.eql(u8, arg, "--check")) break :blk .check;
        fatal("{s}", .{usage});
    } else .update;
    if (args.next() != null) fatal("{s}", .{usage});

    const zon = std.Io.Dir.cwd().readFileAlloc(io, "build.zig.zon", arena, .unlimited) catch |err| fatal(
        "failed to read 'build.zig.zon' with {t}",
        .{err},
    );

    const content = std.Io.Dir.cwd().readFileAlloc(io, config_path, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => "",
        else => |e| fatal("failed to read '{s}' with {t}", .{ config_path, e }),
    };
    const file = config.parse(arena, config_path, content);

    const abilists_path = std.fmt.allocPrint(arena, "{s}/libc/glibc/abilists", .{zigEnv(arena, io, zig_exe, "lib_dir")}) catch |e| oom(e);
    const abilists = std.Io.Dir.cwd().readFileAlloc(io, abilists_path, arena, .unlimited) catch |err| fatal(
        "failed to read '{s}' with {t}",
        .{ abilists_path, err },
    );

    var rows: std.ArrayList(Row) = .empty;
    const rows_dropped = expand(arena, file, zon, &rows);

    var jobs: std.ArrayList(Job) = .empty;
    var python_it: UpstreamVersionIterator = .{ .zon = zon };
    while (python_it.next()) |python| {
        for (std.zig.target.available_libcs) |libc| {
            // the only hermetic targets we test so far
            if (libc.os != .linux and libc.os != .macos) continue;
            var inputs: Inputs = .{ builtin.zig_version_string, python, @tagName(libc.os), @tagName(libc.arch), @tagName(libc.abi), config.no_glibc };
            if (libc.os != .linux or !libc.abi.isGnu()) {
                if (findRow(rows.items, inputs) == null) jobs.append(arena, .{ .inputs = inputs }) catch |e| oom(e);
                continue;
            }
            var glibc_it: GlibcVersionIterator = .init(abilists_path, abilists);
            while (glibc_it.next()) |glibc| {
                if (glibc.order(oldest_glibc) == .lt) continue;
                if (libc.glibc_min) |min| if (glibc.order(min) == .lt) continue;
                if (glibc.patch != 0) fatal("glibc {f} has a patch version which we don't support as an input", .{glibc});
                inputs[config.glibc_input] = std.fmt.allocPrint(arena, "{}.{}", .{ glibc.major, glibc.minor }) catch |e| oom(e);
                if (findRow(rows.items, inputs) == null) jobs.append(arena, .{ .inputs = inputs }) catch |e| oom(e);
            }
        }
    }

    switch (mode) {
        .check => {
            for (jobs.items) |job| std.log.err("{s} has not been tested", .{job.name(arena)});
            if (jobs.items.len != 0) fatal("{} combinations have not been tested, run: zig build update-config", .{jobs.items.len});
        },
        .update => {
            if (jobs.items.len == 0 and !rows_dropped) {
                std.debug.print("{s} is up to date\n", .{config_path});
                return;
            }
            if (rows_dropped) writeConfig(io, rows.items);
            if (jobs.items.len != 0) runJobs(arena, io, init.environ_map, zig_exe, zon, .update, jobs.items, &rows);
        },
        .verify => {
            var verify_jobs: std.ArrayList(Job) = .empty;
            for (rows.items) |row| {
                if (std.mem.eql(u8, row.inputs[zig_input], builtin.zig_version_string)) verify_jobs.append(arena, .{ .inputs = row.inputs }) catch |e| oom(e);
            }
            if (verify_jobs.items.len == 0) fatal("{s} has nothing for zig {s}, run: zig build update-config", .{ config_path, builtin.zig_version_string });
            runJobs(arena, io, init.environ_map, zig_exe, zon, .verify, verify_jobs.items, &rows);
            std.debug.print("all {} combinations match {s}\n", .{ verify_jobs.items.len, config_path });
        },
    }
}

const Row = struct {
    inputs: Inputs,
    status: enum { yes, failed },
    /// Empty if the status is failed, a name that's not here is absent.
    values: std.StringHashMapUnmanaged(Value) = .empty,

    fn value(row: Row, name: []const u8) Value {
        return row.values.get(name) orelse .absent;
    }
    pub fn format(row: Row, w: *std.Io.Writer) error{WriteFailed}!void {
        for (row.inputs, config.input_names, 0..) |input, input_name, i| {
            if (i != 0) try w.writeByte(' ');
            try w.print("{s}={s}", .{ input_name, input });
        }
    }
    fn lessThan(_: void, a: Row, b: Row) bool {
        for (a.inputs, b.inputs) |x, y| switch (std.mem.order(u8, x, y)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        };
        return false;
    }
};

fn findRow(rows: []const Row, inputs: Inputs) ?usize {
    for (rows, 0..) |row, i| {
        for (row.inputs, inputs) |a, b| {
            if (!std.mem.eql(u8, a, b)) break;
        } else return i;
    }
    return null;
}

/// Calls `callback` for every combination listed by `when`, which must list every input.
fn forEachCombination(when: config.When, context: anytype, comptime callback: fn (@TypeOf(context), Inputs) void) void {
    var indexes: [config.input_names.len]usize = @splat(0);
    while (true) {
        var inputs: Inputs = undefined;
        for (&inputs, when.lists, indexes) |*input, list, index| input.* = list.?[index];
        callback(context, inputs);

        var i: usize = indexes.len;
        while (true) {
            if (i == 0) return;
            i -= 1;
            indexes[i] += 1;
            if (indexes[i] < when.lists[i].?.len) break;
            indexes[i] = 0;
        }
    }
}

/// Fills `rows` from `file`. Returns whether any were dropped, which are the ones that don't list
/// an input that's been added since, or are for a python that's no longer in build.zig.zon.
fn expand(arena: std.mem.Allocator, file: config.File, zon: []const u8, rows: *std.ArrayList(Row)) bool {
    const Context = struct {
        arena: std.mem.Allocator,
        file: config.File,
        zon: []const u8,
        rows: *std.ArrayList(Row),
        status: @FieldType(Row, "status"),
        dropped: *bool,

        fn add(context: @This(), inputs: Inputs) void {
            var python_it: UpstreamVersionIterator = .{ .zon = context.zon };
            while (python_it.next()) |python| {
                if (std.mem.eql(u8, python, inputs[python_input])) break;
            } else {
                context.dropped.* = true;
                return;
            }
            var row: Row = .{ .inputs = inputs, .status = context.status };
            if (context.status == .yes) for (context.file.values) |entry| {
                const value = entry.eval(inputs);
                if (value != .absent) row.values.put(context.arena, entry.name, value) catch |e| oom(e);
            };
            context.rows.append(context.arena, row) catch |e| oom(e);
        }
    };

    var dropped = false;
    for (file.verified.when) |when| {
        const status: @FieldType(Row, "status") = blk: {
            if (when.value == .ident) {
                if (std.mem.eql(u8, when.value.ident, "yes")) break :blk .yes;
                if (std.mem.eql(u8, when.value.ident, "failed")) break :blk .failed;
            }
            fatal("verified has an unknown status", .{});
        };
        for (when.lists) |list| {
            if (list == null) dropped = true;
        }
        for (when.lists) |list| {
            if (list == null) break;
        } else forEachCombination(when, Context{
            .arena = arena,
            .file = file,
            .zon = zon,
            .rows = rows,
            .status = status,
            .dropped = &dropped,
        }, Context.add);
    }
    return dropped;
}

const zig_input = 0;
const python_input = 1;
const os_input = 2;
const arch_input = 3;
const abi_input = 4;
const glibc_input = config.glibc_input;

/// The versions from the upstream_* dependencies in build.zig.zon.
const UpstreamVersionIterator = struct {
    zon: []const u8,
    index: usize = 0,

    const prefix = "\"upstream_";

    fn next(it: *UpstreamVersionIterator) ?[]const u8 {
        const start = std.mem.indexOfPos(u8, it.zon, it.index, prefix) orelse return null;
        const version_start = start + prefix.len;
        const end = std.mem.indexOfScalarPos(u8, it.zon, version_start, '"') orelse fatal("invalid build.zig.zon", .{});
        it.index = end;
        return it.zon[version_start..end];
    }
};

/// The glibc versions zig can link against, from the abilists file it ships.
const GlibcVersionIterator = struct {
    remaining: []const u8,

    const version_size = 3;

    fn init(path: []const u8, abilists: []const u8) GlibcVersionIterator {
        // a count of library names then each one null terminated, followed by a count of versions
        var index: usize = 1;
        for (0..abilists[0]) |_| {
            index = (std.mem.indexOfScalarPos(u8, abilists, index, 0) orelse fatal("invalid '{s}'", .{path})) + 1;
        }
        const start = index + 1;
        return .{ .remaining = abilists[start..][0 .. @as(usize, abilists[index]) * version_size] };
    }
    fn next(it: *GlibcVersionIterator) ?std.SemanticVersion {
        if (it.remaining.len == 0) return null;
        defer it.remaining = it.remaining[version_size..];
        return .{ .major = it.remaining[0], .minor = it.remaining[1], .patch = it.remaining[2] };
    }
};

/// The package hash of an upstream dependency in build.zig.zon.
fn upstreamHash(arena: std.mem.Allocator, zon: []const u8, version: []const u8) []const u8 {
    const key = std.fmt.allocPrint(arena, "\"upstream_{s}\"", .{version}) catch |e| oom(e);
    const start = std.mem.indexOf(u8, zon, key) orelse fatal("no upstream_{s} in build.zig.zon", .{version});
    const hash_prefix = ".hash = \"";
    const hash_start = (std.mem.indexOfPos(u8, zon, start, hash_prefix) orelse fatal("no hash for upstream_{s} in build.zig.zon", .{version})) + hash_prefix.len;
    const hash_end = std.mem.indexOfScalarPos(u8, zon, hash_start, '"') orelse fatal("invalid build.zig.zon", .{});
    return zon[hash_start..hash_end];
}

/// The upstream package directory, zig stores it either in the project or in the global cache.
fn findUpstream(arena: std.mem.Allocator, io: std.Io, global_cache: []const u8, hash: []const u8) ?[]const u8 {
    const candidates = [_][]const u8{
        std.fmt.allocPrint(arena, "zig-pkg/{s}", .{hash}) catch |e| oom(e),
        std.fmt.allocPrint(arena, "{s}/p/{s}", .{ global_cache, hash }) catch |e| oom(e),
    };
    for (candidates) |dir| {
        const configure = std.fmt.allocPrint(arena, "{s}/configure", .{dir}) catch |e| oom(e);
        std.Io.Dir.cwd().access(io, configure, .{}) catch continue;
        return std.Io.Dir.cwd().realPathFileAlloc(io, dir, arena) catch |err| fatal("failed to resolve '{s}' with {t}", .{ dir, err });
    }
    return null;
}

fn runZig(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) []const u8 {
    const result = std.process.run(arena, io, .{ .argv = argv }) catch |err| fatal("failed to run '{s} {s}' with {t}", .{ argv[0], argv[1], err });
    if (result.term != .exited or result.term.exited != 0) fatal(
        "'{s} {s}' failed:\n{s}",
        .{ argv[0], argv[1], result.stderr },
    );
    return result.stdout;
}

fn zigEnv(arena: std.mem.Allocator, io: std.Io, zig_exe: []const u8, name: []const u8) []const u8 {
    const env = runZig(arena, io, &.{ zig_exe, "env" });
    const prefix = std.fmt.allocPrint(arena, ".{s} = \"", .{name}) catch |e| oom(e);
    const start = (std.mem.indexOf(u8, env, prefix) orelse fatal("no {s} in 'zig env'", .{name})) + prefix.len;
    const end = std.mem.indexOfScalarPos(u8, env, start, '"') orelse fatal("invalid 'zig env' output", .{});
    return env[start..end];
}

/// One combination to test.
const Job = struct {
    inputs: Inputs,
    src: []const u8 = undefined,
    bin_dir: []const u8 = undefined,
    build_python: []const u8 = undefined,
    configure: []const u8 = undefined,
    environ: std.process.Environ.Map = undefined,
    outcome: union(enum) {
        pending,
        /// configure ran and it can't do this combination.
        failed: []const u8,
        /// Something went wrong that says nothing about this combination.
        fatal: []const u8,
        values: std.StringHashMapUnmanaged(Value),
    } = .pending,

    fn name(job: Job, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "python {s} {s}", .{ job.inputs[python_input], job.target(arena) }) catch |e| oom(e);
    }
    fn target(job: Job, arena: std.mem.Allocator) []const u8 {
        const triple = std.fmt.allocPrint(arena, "{s}-{s}-{s}", .{ job.inputs[arch_input], job.inputs[os_input], job.inputs[abi_input] }) catch |e| oom(e);
        if (std.mem.eql(u8, job.inputs[glibc_input], config.no_glibc)) return triple;
        return std.fmt.allocPrint(arena, "{s}.{s}", .{ triple, job.inputs[glibc_input] }) catch |e| oom(e);
    }
};

/// Reports where a tested combination differs from `row`. Returns how many differences there were.
fn reportDifferences(arena: std.mem.Allocator, job: Job, row: Row) u32 {
    switch (job.outcome) {
        .failed => |reason| {
            if (row.status == .failed) return 0;
            std.log.err("{s}: verified but now fails, {s}", .{ job.name(arena), reason });
            return 1;
        },
        .values => |values| {
            if (row.status == .failed) {
                std.log.err("{s}: recorded as failed but now works", .{job.name(arena)});
                return 1;
            }
            var count: u32 = 0;
            var it = row.values.iterator();
            while (it.next()) |entry| {
                const value = values.get(entry.key_ptr.*) orelse .absent;
                if (value.eql(entry.value_ptr.*)) continue;
                std.log.err("{s}: {s} is {f} but config.txt has {f}", .{ job.name(arena), entry.key_ptr.*, value, entry.value_ptr.* });
                count += 1;
            }
            var new_it = values.iterator();
            while (new_it.next()) |entry| {
                if (row.values.contains(entry.key_ptr.*)) continue;
                std.log.err("{s}: {s} is {f} but config.txt has absent", .{ job.name(arena), entry.key_ptr.*, entry.value_ptr.* });
                count += 1;
            }
            return count;
        },
        .pending, .fatal => unreachable,
    }
}

/// Tests the combinations a batch at a time. When updating it saves after each batch so that
/// stopping doesn't lose the ones that finished.
fn runJobs(
    arena: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    zig_exe: []const u8,
    zon: []const u8,
    mode: enum { update, verify },
    jobs: []Job,
    rows: *std.ArrayList(Row),
) void {
    if (!std.fs.path.isAbsolute(zig_exe)) fatal("the path to zig must be absolute but got '{s}'", .{zig_exe});
    const global_cache = zigEnv(arena, io, zig_exe, "global_cache_dir");
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, work_root) catch |err| fatal("failed to create '{s}' with {t}", .{ work_root, err });
    const work_root_abs = cwd.realPathFileAlloc(io, work_root, arena) catch |err| fatal("failed to resolve '{s}' with {t}", .{ work_root, err });
    const bin_dir = writeTools(arena, io, work_root_abs, zig_exe);

    var fetched = false;
    for (jobs) |*job| {
        const python = job.inputs[python_input];
        const hash = upstreamHash(arena, zon, python);
        job.src = findUpstream(arena, io, global_cache, hash) orelse blk: {
            if (!fetched) {
                std.debug.print("fetching upstream python sources\n", .{});
                _ = runZig(arena, io, &.{ zig_exe, "build", "--fetch=all" });
                fetched = true;
            }
            break :blk findUpstream(arena, io, global_cache, hash) orelse fatal(
                "upstream package '{s}' for python {s} is missing after fetching it",
                .{ hash, python },
            );
        };
        job.environ = environ.clone(arena) catch |e| oom(e);
        job.bin_dir = bin_dir;
        job.build_python = writeBuildPython(arena, io, bin_dir, python);
        job.configure = std.fmt.allocPrint(arena, "{s}/configure", .{job.src}) catch |e| oom(e);
        if (std.mem.eql(u8, job.inputs[os_input], "macos")) {
            job.configure = writeMacosConfigure(arena, io, work_root_abs, python, job.configure);
        }
    }

    const progress = std.Progress.start(io, .{
        .root_name = switch (mode) {
            .update => "update-config",
            .verify => "verify-config",
        },
        .estimated_total_items = jobs.len,
    });
    defer progress.end();
    // progress is only drawn on a terminal, without this a long run would look stuck
    const print_progress = !(std.Io.File.stderr().isTty(io) catch false);

    const batch_size = std.Thread.getCpuCount() catch |err| fatal("failed to get the cpu count with {t}", .{err});
    var differences: u32 = 0;
    var finished: usize = 0;
    while (finished < jobs.len) {
        const batch = jobs[finished..@min(finished + batch_size, jobs.len)];
        var group: std.Io.Group = .init;
        for (batch) |*job| group.async(io, runJob, .{ arena, io, zig_exe, job, progress });
        group.await(io) catch |err| switch (err) {
            error.Canceled => fatal("canceled", .{}),
        };

        for (batch) |job| {
            if (job.outcome == .fatal) fatal("{s}: {s}", .{ job.name(arena), job.outcome.fatal });
        }
        switch (mode) {
            .verify => for (batch) |job| {
                differences += reportDifferences(arena, job, rows.items[findRow(rows.items, job.inputs).?]);
            },
            .update => {
                for (batch) |job| switch (job.outcome) {
                    .pending, .fatal => unreachable,
                    .failed => |reason| {
                        std.debug.print("{s}: failed, {s}\n", .{ job.name(arena), reason });
                        rows.append(arena, .{ .inputs = job.inputs, .status = .failed }) catch |e| oom(e);
                    },
                    .values => |values| rows.append(arena, .{ .inputs = job.inputs, .status = .yes, .values = values }) catch |e| oom(e),
                };
                writeConfig(io, rows.items);
            },
        }
        finished += batch.len;
        if (print_progress) std.debug.print("tested {}/{}\n", .{ finished, jobs.len });
    }
    if (differences != 0) fatal(
        "{} results differ for combinations that were already tested, so something that affects config isn't one of the inputs in config.zig",
        .{differences},
    );
}

fn writeScript(arena: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8, data: []const u8) void {
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name }) catch |e| oom(e);
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = data,
        .flags = .{ .permissions = .executable_file },
    }) catch |err| fatal("failed to write '{s}' with {t}", .{ path, err });
}

/// configure splits CC and friends on spaces so it can't be given a path to zig, wrapper scripts on
/// the PATH let zig and this project be anywhere. These and the build python have to be written
/// before any job starts: a child forked while another thread has an executable open for writing
/// inherits it, and running it then fails with ETXTBSY.
fn writeTools(arena: std.mem.Allocator, io: std.Io, work_root_abs: []const u8, zig_exe: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, zig_exe, '\'') != null) fatal("the path to zig can't contain a single quote: {s}", .{zig_exe});
    if (std.mem.indexOfScalar(u8, work_root_abs, ':') != null) fatal("this project's path can't contain a colon: {s}", .{work_root_abs});
    const bin_dir = std.fmt.allocPrint(arena, "{s}/bin", .{work_root_abs}) catch |e| oom(e);
    std.Io.Dir.cwd().createDirPath(io, bin_dir) catch |err| fatal("failed to create '{s}' with {t}", .{ bin_dir, err });
    for ([_]struct { []const u8, []const u8 }{
        .{ "zig-cc", "cc" },
        .{ "zig-cxx", "c++" },
        .{ "zig-ar", "ar" },
        .{ "zig-ranlib", "ranlib" },
    }) |tool| {
        const data = std.fmt.allocPrint(arena, "#!/bin/sh\nexec '{s}' {s} \"$@\"\n", .{ zig_exe, tool[1] }) catch |e| oom(e);
        writeScript(arena, io, bin_dir, tool[0], data);
    }
    return bin_dir;
}

/// configure requires a build python in cross compile mode, it only checks its version and it doesn't
/// affect pyconfig.h. Returns its name on the PATH.
fn writeBuildPython(arena: std.mem.Allocator, io: std.Io, bin_dir: []const u8, python: []const u8) []const u8 {
    const second_dot = blk: {
        const first = std.mem.indexOfScalar(u8, python, '.') orelse fatal("invalid python version '{s}'", .{python});
        break :blk std.mem.indexOfScalarPos(u8, python, first + 1, '.') orelse fatal("invalid python version '{s}'", .{python});
    };
    const major_minor = python[0..second_dot];
    const name = std.fmt.allocPrint(arena, "python{s}", .{major_minor}) catch |e| oom(e);
    const data = std.fmt.allocPrint(arena, "#!/bin/sh\necho {s}\n", .{major_minor}) catch |e| oom(e);
    writeScript(arena, io, bin_dir, name, data);
    return name;
}

/// configure refuses to cross compile for macOS, but zig has what it needs. Returns the path to a
/// copy of configure that allows it, see writeTools for why this can't happen while jobs are running.
fn writeMacosConfigure(arena: std.mem.Allocator, io: std.Io, work_root_abs: []const u8, python: []const u8, upstream_path: []const u8) []const u8 {
    const refusal = "as_fn_error $? \"cross build not supported for $host\" \"$LINENO\" 5";
    const upstream = std.Io.Dir.cwd().readFileAlloc(io, upstream_path, arena, .unlimited) catch |err| fatal(
        "failed to read '{s}' with {t}",
        .{ upstream_path, err },
    );
    if (std.mem.indexOf(u8, upstream, refusal) == null) fatal("{s} no longer has '{s}', update updateconfig.zig", .{ upstream_path, refusal });
    const name = std.fmt.allocPrint(arena, "configure-macos-{s}", .{python}) catch |e| oom(e);
    const data = std.mem.replaceOwned(u8, arena, upstream, refusal, ":") catch |e| oom(e);
    writeScript(arena, io, work_root_abs, name, data);
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ work_root_abs, name }) catch |e| oom(e);
}

fn runJob(arena: std.mem.Allocator, io: std.Io, zig_exe: []const u8, job: *Job, progress: std.Progress.Node) void {
    const node = progress.start(job.name(arena), 0);
    defer node.end();
    runJobFallible(arena, io, zig_exe, job) catch |err| switch (err) {
        error.Fatal => {},
        error.OutOfMemory => |e| oom(e),
    };
}

fn jobFatal(arena: std.mem.Allocator, job: *Job, comptime fmt: []const u8, args: anytype) error{ Fatal, OutOfMemory } {
    job.outcome = .{ .fatal = try std.fmt.allocPrint(arena, fmt, args) };
    return error.Fatal;
}

fn runJobFallible(arena: std.mem.Allocator, io: std.Io, zig_exe: []const u8, job: *Job) error{ Fatal, OutOfMemory }!void {
    const cwd = std.Io.Dir.cwd();
    const target = job.target(arena);
    const arch = job.inputs[arch_input];
    const python = job.inputs[python_input];
    const work = try std.fmt.allocPrint(arena, work_root ++ "/{s}-{s}", .{ python, target });
    cwd.deleteTree(io, work) catch |err| return jobFatal(arena, job, "failed to delete '{s}' with {t}", .{ work, err });
    cwd.createDirPath(io, work) catch |err| return jobFatal(arena, job, "failed to create '{s}' with {t}", .{ work, err });

    // anything from the environment would make the result depend on this machine
    const environ = &job.environ;
    for ([_][]const u8{ "CFLAGS", "CPPFLAGS", "CXXFLAGS", "LDFLAGS", "LIBS", "CONFIG_SITE", "ZIG_PROGRESS" }) |name| {
        _ = environ.swapRemove(name);
    }
    const path = environ.get("PATH") orelse return jobFatal(arena, job, "PATH isn't set", .{});
    try environ.put("PATH", try std.fmt.allocPrint(arena, "{s}:{s}", .{ job.bin_dir, path }));
    try environ.put("CC", try std.fmt.allocPrint(arena, "zig-cc -target {s}", .{target}));
    try environ.put("CXX", try std.fmt.allocPrint(arena, "zig-cxx -target {s}", .{target}));
    try environ.put("AR", "zig-ar");
    try environ.put("RANLIB", "zig-ranlib");
    // zig doesn't have a readelf, configure requires one in cross compile mode but doesn't need it
    try environ.put("READELF", "false");
    try environ.put("PKG_CONFIG", "false");
    for (cross_answers) |answer| try environ.put(answer[0], answer[1]);
    if (std.mem.eql(u8, job.inputs[os_input], "macos")) {
        for (macos_answers) |answer| try environ.put(answer[0], answer[1]);
    }

    // HAVE_USABLE_WCHAR_T comes from a check that has to run, but the compiler can tell us this one
    const predefined = std.process.run(arena, io, .{
        .argv = &.{ zig_exe, "cc", "-target", target, "-dM", "-E", "-x", "c", "/dev/null" },
        .environ_map = environ,
    }) catch |err| return jobFatal(arena, job, "failed to run zig cc with {t}", .{err});
    if (predefined.term != .exited or predefined.term.exited != 0) {
        job.outcome = .{ .failed = try std.fmt.allocPrint(arena, "zig cc {s}", .{firstLine(predefined.stderr)}) };
        return;
    }
    try environ.put(
        "ac_cv_wchar_t_signed",
        if (std.mem.indexOf(u8, predefined.stdout, "__WCHAR_UNSIGNED__") == null) "yes" else "no",
    );

    const host_arch = if (std.mem.eql(u8, arch, "x86")) "i686" else arch;
    const host = if (std.mem.eql(u8, job.inputs[os_input], "macos"))
        try std.fmt.allocPrint(arena, "{s}-apple-darwin", .{host_arch})
    else
        try std.fmt.allocPrint(arena, "{s}-unknown-{s}-{s}", .{ host_arch, job.inputs[os_input], job.inputs[abi_input] });
    const result = std.process.run(arena, io, .{
        .argv = &.{
            job.configure,
            try std.fmt.allocPrint(arena, "--srcdir={s}", .{job.src}),
            "--without-ensurepip",
            try std.fmt.allocPrint(arena, "--host={s}", .{host}),
            "--build=" ++ build_triple,
            try std.fmt.allocPrint(arena, "--with-build-python={s}", .{job.build_python}),
        },
        .cwd = .{ .path = work },
        .environ_map = environ,
    }) catch |err| return jobFatal(arena, job, "failed to run configure with {t}", .{err});
    const log_path = try std.fmt.allocPrint(arena, "{s}/configure.log", .{work});
    cwd.writeFile(io, .{ .sub_path = log_path, .data = result.stdout }) catch |err| return jobFatal(
        arena,
        job,
        "failed to write '{s}' with {t}",
        .{ log_path, err },
    );
    if (result.term != .exited or result.term.exited != 0) {
        job.outcome = .{ .failed = try std.fmt.allocPrint(arena, "{s}, see {s}/config.log", .{ lastErrorLine(result.stderr), work }) };
        return;
    }
    if (std.mem.indexOf(u8, result.stdout, "checking whether we are cross compiling... yes\n") == null) return jobFatal(
        arena,
        job,
        "configure isn't cross compiling, the result would depend on this machine",
        .{},
    );

    const template_path = try std.fmt.allocPrint(arena, "{s}/pyconfig.h.in", .{job.src});
    const template = cwd.readFileAlloc(io, template_path, arena, .unlimited) catch |err| return jobFatal(
        arena,
        job,
        "failed to read '{s}' with {t}",
        .{ template_path, err },
    );
    const header_path = try std.fmt.allocPrint(arena, "{s}/pyconfig.h", .{work});
    const header = cwd.readFileAlloc(io, header_path, arena, .unlimited) catch |err| return jobFatal(
        arena,
        job,
        "failed to read '{s}' with {t}",
        .{ header_path, err },
    );
    try parseHeader(arena, job, template, header);
}

fn firstLine(str: []const u8) []const u8 {
    return str[0 .. std.mem.indexOfScalar(u8, str, '\n') orelse str.len];
}

fn lastErrorLine(stderr: []const u8) []const u8 {
    var result: []const u8 = "configure failed";
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "configure: error:")) result = line;
    }
    return result;
}

/// If `line` is a preprocessor directive `name`, returns what comes after it.
fn directiveArgs(line: []const u8, name: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed[0] != '#') return null;
    const directive = std.mem.trimStart(u8, trimmed[1..], &std.ascii.whitespace);
    if (!std.mem.startsWith(u8, directive, name)) return null;
    const rest = directive[name.len..];
    if (rest.len == 0 or !std.ascii.isWhitespace(rest[0])) return null;
    return std.mem.trimStart(u8, rest, &std.ascii.whitespace);
}

fn isIdentifier(str: []const u8) bool {
    if (str.len == 0) return false;
    for (str) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
        else => return false,
    };
    return true;
}

fn firstWord(str: []const u8) []const u8 {
    return str[0 .. std.mem.indexOfAny(u8, str, &std.ascii.whitespace) orelse str.len];
}

/// Reduces pyconfig.h to the names that are templated in pyconfig.h.in.
fn parseHeader(arena: std.mem.Allocator, job: *Job, template: []const u8, header: []const u8) error{ Fatal, OutOfMemory }!void {
    var templated: std.StringHashMapUnmanaged(void) = .empty;
    var template_it = std.mem.splitScalar(u8, template, '\n');
    while (template_it.next()) |line| {
        const name = directiveArgs(line, "undef") orelse continue;
        if (isIdentifier(name)) try templated.put(arena, name, {});
    }

    var values: std.StringHashMapUnmanaged(Value) = .empty;
    var universal = false;
    var header_it = std.mem.splitScalar(u8, header, '\n');
    while (header_it.next()) |line| {
        // WORDS_BIGENDIAN is also defined here, for universal builds which we do not use
        if (std.mem.startsWith(u8, line, "#if defined AC_APPLE_UNIVERSAL_BUILD")) {
            universal = true;
            continue;
        }
        if (universal) {
            if (std.mem.startsWith(u8, line, "#else")) universal = false;
            continue;
        }
        const name, const value_text = blk: {
            if (std.mem.startsWith(u8, line, "/*")) {
                const args = directiveArgs(line[2..], "undef") orelse continue;
                break :blk .{ firstWord(args), "undef" };
            }
            const args = directiveArgs(line, "define") orelse continue;
            const name = firstWord(args);
            const text = std.mem.trim(u8, args[name.len..], &std.ascii.whitespace);
            break :blk .{ name, if (text.len == 0) "defined" else text };
        };
        if (!templated.contains(name)) continue;
        const value = Value.parse(value_text) orelse return jobFatal(arena, job, "unsupported value '{s}' for '{s}'", .{ value_text, name });

        // the template can repeat a name, but there can only be one value for it
        const entry = try values.getOrPut(arena, name);
        if (entry.found_existing and !entry.value_ptr.eql(value)) return jobFatal(
            arena,
            job,
            "pyconfig.h has two different values for '{s}'",
            .{name},
        );
        entry.value_ptr.* = value;
    }
    if (values.count() != templated.count()) return jobFatal(
        arena,
        job,
        "pyconfig.h has {} of the {} names in pyconfig.h.in",
        .{ values.count(), templated.count() },
    );
    job.outcome = .{ .values = values };
}

/// Each input's values, sorted, so a set of them can be a bitmask of their indexes.
const Interned = struct {
    tables: [config.input_names.len][]const []const u8,

    fn init(arena: std.mem.Allocator, rows: []const Row) Interned {
        var interned: Interned = undefined;
        for (&interned.tables, 0..) |*table, input_index| {
            var list: std.ArrayList([]const u8) = .empty;
            for (rows) |row| {
                for (list.items) |item| {
                    if (std.mem.eql(u8, item, row.inputs[input_index])) break;
                } else list.append(arena, row.inputs[input_index]) catch |e| oom(e);
            }
            std.mem.sortUnstable([]const u8, list.items, {}, stringLessThan);
            if (list.items.len > 64) fatal("input {s} has more than 64 values", .{config.input_names[input_index]});
            table.* = list.items;
        }
        return interned;
    }
    fn bit(interned: Interned, input_index: usize, value: []const u8) u64 {
        for (interned.tables[input_index], 0..) |item, i| {
            if (std.mem.eql(u8, item, value)) return @as(u64, 1) << @intCast(i);
        }
        unreachable;
    }
};

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// A set of combinations: every input's set of values, multiplied together.
const Cube = [config.input_names.len]u64;

/// Merges into the fewest cubes it can in a fixed input order, last input first, which only depends
/// on the set of combinations. Merging two cubes that only differ in one input can't add a
/// combination that wasn't already in one of them.
fn mergeCubes(arena: std.mem.Allocator, start: []const Cube) []const Cube {
    var cubes: std.ArrayList(Cube) = .empty;
    cubes.appendSlice(arena, start) catch |e| oom(e);
    var input_index: usize = config.input_names.len;
    while (input_index > 0) {
        input_index -= 1;
        var merged: std.ArrayList(Cube) = .empty;
        next_cube: for (cubes.items) |cube| {
            for (merged.items) |*other| {
                for (cube, other.*, 0..) |a, b, i| {
                    if (i != input_index and a != b) break;
                } else {
                    other[input_index] |= cube[input_index];
                    continue :next_cube;
                }
            }
            merged.append(arena, cube) catch |e| oom(e);
        }
        cubes = merged;
    }
    return cubes.items;
}

/// Writes `NAME INPUT=VALUE,... VALUE` for every cube into `lines`. `used` says which inputs to list.
fn appendCubeLines(
    arena: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    interned: Interned,
    name: []const u8,
    cubes: []const Cube,
    used: u32,
    value: Value,
) void {
    for (cubes) |cube| {
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        writeCubeLine(w, interned, name, cube, used, value) catch oom(error.OutOfMemory);
        lines.append(arena, out.written()) catch |e| oom(e);
    }
}

fn writeCubeLine(w: *std.Io.Writer, interned: Interned, name: []const u8, cube: Cube, used: u32, value: Value) error{WriteFailed}!void {
    try w.writeAll(name);
    for (cube, 0..) |set, input_index| {
        if (used & (@as(u32, 1) << @intCast(input_index)) == 0) continue;
        try w.print(" {s}=", .{config.input_names[input_index]});
        var first = true;
        for (interned.tables[input_index], 0..) |item, i| {
            if (set & (@as(u64, 1) << @intCast(i)) == 0) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll(item);
        }
    }
    try w.writeByte(' ');
    try value.write(w);
}

fn rowCube(interned: Interned, row: Row, used: u32) Cube {
    var cube: Cube = @splat(0);
    for (&cube, row.inputs, 0..) |*set, input, input_index| {
        if (used & (@as(u32, 1) << @intCast(input_index)) != 0) set.* = interned.bit(input_index, input);
    }
    return cube;
}

/// Whether `rows` having the same values for the inputs in `used` means they have the same value.
fn determines(arena: std.mem.Allocator, interned: Interned, rows: []const Row, name: []const u8, used: u32) bool {
    var seen: std.AutoHashMapUnmanaged(Cube, Value) = .empty;
    for (rows) |row| {
        const entry = seen.getOrPut(arena, rowCube(interned, row, used)) catch |e| oom(e);
        const value = row.value(name);
        if (!entry.found_existing) {
            entry.value_ptr.* = value;
        } else if (!entry.value_ptr.eql(value)) return false;
    }
    return true;
}

/// The smallest set of inputs that determines the value, earlier inputs first when there's a tie.
fn smallestDeterminingInputs(arena: std.mem.Allocator, interned: Interned, rows: []const Row, name: []const u8) u32 {
    const all: u32 = (1 << config.input_names.len) - 1;
    for (0..config.input_names.len + 1) |size| {
        var used: u32 = 0;
        while (used <= all) : (used += 1) {
            if (@popCount(used) == size and determines(arena, interned, rows, name, used)) return used;
        }
    }
    unreachable;
}

fn mostCommonValue(arena: std.mem.Allocator, rows: []const Row, name: []const u8) Value {
    const Count = struct { value: Value, count: u32 };
    var counts: std.ArrayList(Count) = .empty;
    next_row: for (rows) |row| {
        const value = row.value(name);
        for (counts.items) |*count| {
            if (count.value.eql(value)) {
                count.count += 1;
                continue :next_row;
            }
        }
        counts.append(arena, .{ .value = value, .count = 1 }) catch |e| oom(e);
    }
    var best = counts.items[0];
    for (counts.items[1..]) |count| {
        if (count.count > best.count) best = count;
    }
    return best.value;
}

/// The lines for one name, the default then the combinations that differ from it.
fn reduce(arena: std.mem.Allocator, out: *std.ArrayList([]const u8), interned: Interned, rows: []const Row, name: []const u8) void {
    const default = mostCommonValue(arena, rows, name);
    out.append(arena, renderDefault(arena, name, default)) catch |e| oom(e);

    const used = smallestDeterminingInputs(arena, interned, rows, name);
    var values: std.ArrayList(Value) = .empty;
    for (rows) |row| {
        const value = row.value(name);
        if (value.eql(default)) continue;
        for (values.items) |existing| {
            if (existing.eql(value)) break;
        } else values.append(arena, value) catch |e| oom(e);
    }

    var lines: std.ArrayList([]const u8) = .empty;
    for (values.items) |value| {
        var cubes: std.ArrayList(Cube) = .empty;
        for (rows) |row| {
            if (!row.value(name).eql(value)) continue;
            const cube = rowCube(interned, row, used);
            for (cubes.items) |*existing| {
                if (std.mem.eql(u64, existing, &cube)) break;
            } else cubes.append(arena, cube) catch |e| oom(e);
        }
        appendCubeLines(arena, &lines, interned, name, mergeCubes(arena, cubes.items), used, value);
    }
    std.mem.sortUnstable([]const u8, lines.items, {}, stringLessThan);
    out.appendSlice(arena, lines.items) catch |e| oom(e);
}

fn renderDefault(arena: std.mem.Allocator, name: []const u8, value: Value) []const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.print("{s} ", .{name}) catch oom(error.OutOfMemory);
    value.write(&out.writer) catch oom(error.OutOfMemory);
    return out.written();
}

/// Unlike values, `verified` never leaves out an input: it has to mean exactly what was tested.
fn reduceVerified(arena: std.mem.Allocator, out: *std.ArrayList([]const u8), interned: Interned, rows: []const Row) void {
    out.append(arena, renderDefault(arena, config.verified_name, .absent)) catch |e| oom(e);
    const all: u32 = (1 << config.input_names.len) - 1;
    var lines: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "yes", "failed" }, [_]@FieldType(Row, "status"){ .yes, .failed }) |text, status| {
        var cubes: std.ArrayList(Cube) = .empty;
        for (rows) |row| {
            if (row.status == status) cubes.append(arena, rowCube(interned, row, all)) catch |e| oom(e);
        }
        appendCubeLines(arena, &lines, interned, config.verified_name, mergeCubes(arena, cubes.items), all, .{ .ident = text });
    }
    std.mem.sortUnstable([]const u8, lines.items, {}, stringLessThan);
    out.appendSlice(arena, lines.items) catch |e| oom(e);
}

/// Panics if the file doesn't mean the same thing as `rows`.
fn verifyRoundTrip(arena: std.mem.Allocator, text: []const u8, rows: []const Row, names: []const []const u8) void {
    const file = config.parse(arena, config_path, text);
    var listed: usize = 0;
    for (file.verified.when) |when| {
        var count: usize = 1;
        for (when.lists) |list| count *= list.?.len;
        listed += count;
    }
    if (listed != rows.len) std.debug.panic("the reduced verified lines list {} combinations but there are {}", .{ listed, rows.len });
    for (rows) |row| {
        const status = file.verified.eval(row.inputs);
        const expected = if (row.status == .yes) "yes" else "failed";
        if (status != .ident or !std.mem.eql(u8, status.ident, expected)) std.debug.panic("the reduced verified lines don't match {f}", .{row});
        if (row.status != .yes) continue;
        for (file.values, names) |entry, name| {
            std.debug.assert(std.mem.eql(u8, entry.name, name));
            if (!entry.eval(row.inputs).eql(row.value(name))) std.debug.panic("the reduced {s} doesn't match {f}", .{ name, row });
        }
    }
}

fn writeConfig(io: std.Io, rows: []const Row) void {
    // this runs after every batch and it allocates a lot, so it can't be left to the main arena
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const sorted = arena.dupe(Row, rows) catch |e| oom(e);
    std.mem.sortUnstable(Row, sorted, {}, Row.lessThan);

    var yes_rows: std.ArrayList(Row) = .empty;
    for (sorted) |row| {
        if (row.status == .yes) yes_rows.append(arena, row) catch |e| oom(e);
    }

    var names: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (yes_rows.items) |row| {
        var it = row.values.keyIterator();
        while (it.next()) |name| {
            const entry = seen.getOrPut(arena, name.*) catch |e| oom(e);
            if (!entry.found_existing) names.append(arena, name.*) catch |e| oom(e);
        }
    }
    std.mem.sortUnstable([]const u8, names.items, {}, stringLessThan);

    const interned: Interned = .init(arena, sorted);
    var lines: std.ArrayList([]const u8) = .empty;
    reduceVerified(arena, &lines, interned, sorted);
    for (names.items) |name| reduce(arena, &lines, interned, yes_rows.items, name);

    var out: std.Io.Writer.Allocating = .init(arena);
    writeLines(&out.writer, lines.items) catch oom(error.OutOfMemory);
    const text = out.written();
    verifyRoundTrip(arena, text, sorted, names.items);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = text }) catch |err| fatal(
        "failed to write '{s}' with {t}",
        .{ config_path, err },
    );
}

fn writeLines(w: *std.Io.Writer, lines: []const []const u8) error{WriteFailed}!void {
    try w.writeAll(
        \\# Generated by `zig build update-config`, do not edit. See "Generating static config" in README.md.
        \\# The format is described in config.zig.
        \\
    );
    for (lines) |line| {
        try w.writeAll(line);
        try w.writeByte('\n');
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}
fn oom(err: error{OutOfMemory}) noreturn {
    @panic(@errorName(err));
}

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const Inputs = config.Inputs;
const Value = config.Value;
