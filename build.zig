pub const Version = enum {
    @"3.11.13",
    @"3.12.11",
    pub fn libName(self: Version) []const u8 {
        return switch (self) {
            .@"3.11.13" => "3.11",
            .@"3.12.11" => "3.12",
        };
    }

    pub const latest: Version = .@"3.12.11";
};

/// There are 3 stages of the python exe, the first two are used compile and embed modules for
/// the next stage which is referred to as "freezing" modules.
const PythonExeStage = union(enum) {
    /// stage1: used to "freeze" the modules used by bootstrap
    freeze_module,
    /// stage2: used to freeze the remaining modules for the final exe
    bootstrap: Stage2FrozenMods,
    /// stage3: the final python exe
    final: struct {
        stage2: Stage2FrozenMods,
        deepfreeze_c: std.Build.LazyPath,
        frozen_headers: []const std.Build.LazyPath,
    },

    pub fn stage2FrozenMods(self: PythonExeStage) ?Stage2FrozenMods {
        return switch (self) {
            .freeze_module => null,
            .bootstrap => |mods| mods,
            .final => |final| final.stage2,
        };
    }
};
const Stage2FrozenMods = struct {
    getpath_h: std.Build.LazyPath,
    importlib_bootstrap_h: std.Build.LazyPath,
    importlib_bootstrap_external_h: std.Build.LazyPath,
    zipimport_h: std.Build.LazyPath,
};

pub fn build(b: *std.Build) !void {
    const version: Version = b.option(Version, "version", "Python Version") orelse .latest;

    const replace_exe = b.addExecutable(.{
        .name = "replace",
        .root_module = b.createModule(.{
            .root_source_file = b.path("replace.zig"),
            .target = b.graph.host,
        }),
    });
    const makesetup_exe = b.addExecutable(.{
        .name = "makesetup",
        .root_module = b.createModule(.{
            .root_source_file = b.path("makesetup.zig"),
            .target = b.graph.host,
        }),
    });

    const conzig_exe = b.dependency("conzig", .{ .target = b.graph.host }).artifact("conzig");

    const upstream: *std.Build.Dependency = switch (version) {
        .@"3.11.13" => if (b.lazyDependency("upstream_3.11.13", .{})) |d| d else noUpstream(b),
        .@"3.12.11" => if (b.lazyDependency("upstream_3.12.11", .{})) |d| d else noUpstream(b),
    };

    const target = explicitTarget(b, b.standardTargetOptions(.{}));
    const host = explicitTarget(b, b.graph.host);
    const optimize = b.standardOptimizeOption(.{});

    const ssl_enabled = b.option(bool, "ssl", "enable ssl") orelse switch (target.result.os.tag) {
        .macos => false, // there's an issue building openssl on macos
        else => true,
    };

    const libs_host: Libs = .{ .zlib = null, .openssl = null };
    const libs_target: Libs = .{
        .zlib = (b.dependency("zlib", .{
            .target = target,
            .optimize = optimize,
        })).artifact("z"),
        .openssl = if (ssl_enabled) (if (b.lazyDependency("openssl", .{
            .target = target,
            .optimize = optimize,
        })) |dep| dep.artifact("openssl") else null) else null,
    };

    const makesetup_host = addMakesetup(b, version, upstream, libs_host, .{
        .os_tag = host.result.os.tag,
        .replace_exe = replace_exe,
        .makesetup_exe = makesetup_exe,
    });
    const makesetup_target = addMakesetup(b, version, upstream, libs_target, .{
        .os_tag = target.result.os.tag,
        .replace_exe = replace_exe,
        .makesetup_exe = makesetup_exe,
    });
    const pyconfig_host = addPyconfig(b, conzig_exe, version, upstream, host, .{ .zlib = null, .openssl = null });

    {
        const checkconfig_exe = b.addExecutable(.{
            .name = "checkconfig",
            .root_module = b.createModule(.{
                .root_source_file = b.path("checkconfig.zig"),
                .target = b.graph.host,
            }),
        });
        const check_config = b.addRunArtifact(checkconfig_exe);
        check_config.has_side_effects = true;
        check_config.stdio = .inherit;
        check_config.addDirectoryArg(upstream.path("."));
        _ = check_config.addOutputDirectoryArg("configure");
        check_config.addFileArg(pyconfig_host.header);
        b.step("check-config", "Show where conzig's config differs from running configure on this machine").dependOn(&check_config.step);
    }

    const freeze_module_exe = addPythonExe(b, upstream, host, .Debug, .{
        .name = "freeze_module",
        .makesetup_out = makesetup_host,
        .pyconfig = pyconfig_host,
        .stage = .freeze_module,
    });

    const stage2_frozen_mods: Stage2FrozenMods = .{
        .getpath_h = blk: {
            const freeze = b.addRunArtifact(freeze_module_exe);
            freeze.addArg("getpath");
            freeze.addFileArg(upstream.path("Modules/getpath.py"));
            break :blk freeze.addOutputFileArg("Python/frozen_modules/getpath.h");
        },
        .importlib_bootstrap_h = blk: {
            const freeze = b.addRunArtifact(freeze_module_exe);
            freeze.addArg("importlib._bootstrap");
            freeze.addFileArg(upstream.path("Lib/importlib/_bootstrap.py"));
            break :blk freeze.addOutputFileArg("Python/frozen_modules/importlib._bootstrap.h");
        },
        .importlib_bootstrap_external_h = blk: {
            const freeze = b.addRunArtifact(freeze_module_exe);
            freeze.addArg("importlib._bootstrap_external");
            freeze.addFileArg(upstream.path("Lib/importlib/_bootstrap_external.py"));
            break :blk freeze.addOutputFileArg("Python/frozen_modules/importlib._bootstrap_external.h");
        },
        .zipimport_h = blk: {
            const freeze = b.addRunArtifact(freeze_module_exe);
            freeze.addArg("zipimport");
            freeze.addFileArg(upstream.path("Lib/zipimport.py"));
            break :blk freeze.addOutputFileArg("Python/frozen_modules/zipimport.h");
        },
    };

    const frozen_headers, const deepfreeze_c = blk_deepfreeze_c: {
        const bootstrap_python_exe = addPythonExe(b, upstream, host, .Debug, .{
            .name = "bootstrap_python",
            .makesetup_out = makesetup_host,
            .pyconfig = pyconfig_host,
            .stage = .{ .bootstrap = stage2_frozen_mods },
        });
        const bootstrap_packaged = packagePython(b, version, upstream, bootstrap_python_exe);

        const frozen_headers = b.allocator.alloc(std.Build.LazyPath, frozen_modules.len) catch @panic("OOM");
        // don't free

        const freeze_step = b.step("freeze", "");
        for (frozen_modules, frozenModuleNames(version), frozen_headers) |mod_path, mod_name, *header| {
            const freeze = std.Build.Step.Run.create(b, b.fmt("run _freeze_module.py for '{s}'", .{mod_path}));
            freeze.addFileArg(bootstrap_packaged.exe);
            freeze.addFileArg(upstream.path("Programs/_freeze_module.py"));
            freeze.addArg(mod_name);
            freeze.addFileArg(upstream.path(mod_path));
            header.* = freeze.addOutputFileArg(b.fmt("frozen_modules/{s}.h", .{mod_name}));
            freeze_step.dependOn(&freeze.step);
        }

        const run = std.Build.Step.Run.create(b, "run deepfreeze.py");
        run.addFileArg(bootstrap_packaged.exe);
        run.addFileArg(upstream.path(switch (version) {
            .@"3.11.13" => "Tools/scripts/deepfreeze.py",
            else => "Tools/build/deepfreeze.py",
        }));
        run.addArg("-o");
        const deepfreeze_c = run.addOutputFileArg("deepfreeze.c");
        {
            // Need to create a custom step because std.Build.Step.Run doesn't
            // have addSuffixedOutputArg.
            const AddModules = struct {
                step: std.Build.Step,
                version: Version,
                run_deepfreeze: *std.Build.Step.Run,
                headers: []const std.Build.LazyPath,
            };
            const add_modules_make = struct {
                fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
                    _ = options;
                    const b2 = step.owner;
                    const self: *AddModules = @fieldParentPtr("step", step);
                    for (frozenModuleNames(self.version), self.headers) |mod_name, header| {
                        self.run_deepfreeze.addArg(b2.fmt("{s}:{s}", .{ header.getPath(b2), mod_name }));
                    }
                }
            }.make;
            const add_modules = b.allocator.create(AddModules) catch @panic("OOM");
            add_modules.* = .{
                .step = std.Build.Step.init(.{
                    .id = .custom,
                    .name = "add modules to run deepfreeze.py",
                    .owner = b,
                    .makeFn = &add_modules_make,
                }),
                .version = version,
                .run_deepfreeze = run,
                .headers = frozen_headers,
            };
            add_modules.step.dependOn(freeze_step);
            run.step.dependOn(&add_modules.step);
        }

        b.step("deepfreeze", "").dependOn(&run.step);
        break :blk_deepfreeze_c .{ frozen_headers, deepfreeze_c };
    };

    const final_exe = addPythonExe(b, upstream, target, optimize, .{
        .name = "python",
        .makesetup_out = makesetup_target,
        .pyconfig = addPyconfig(b, conzig_exe, version, upstream, target, libs_target),
        .stage = .{
            .final = .{
                .stage2 = stage2_frozen_mods,
                .frozen_headers = frozen_headers,
                .deepfreeze_c = deepfreeze_c,
            },
        },
    });
    const final_packaged = packagePython(b, version, upstream, final_exe);
    const install_final = b.addInstallDirectory(.{
        .source_dir = final_packaged.root,
        .install_dir = .prefix,
        .install_subdir = "",
    });
    b.getInstallStep().dependOn(&install_final.step);

    const ci_step = b.step("ci", "The build/test step to run on the CI");
    ci_step.dependOn(b.getInstallStep());
    try ci(b, version, ssl_enabled, upstream, ci_step, .{
        .replace_exe = replace_exe,
        .makesetup_exe = makesetup_exe,
        .conzig_exe = conzig_exe,
        .stage2_frozen_mods = stage2_frozen_mods,
        .frozen_headers = frozen_headers,
        .deepfreeze_c = deepfreeze_c,
    });
}

fn noUpstream(b: *std.Build) *std.Build.Dependency {
    const dependency = b.allocator.create(std.Build.Dependency) catch @panic("OOM");
    dependency.* = .{ .builder = b };
    return dependency;
}

fn addMakesetup(
    b: *std.Build,
    version: Version,
    upstream: *std.Build.Dependency,
    libs: Libs,
    args: struct {
        os_tag: std.Target.Os.Tag,
        replace_exe: *std.Build.Step.Compile,
        makesetup_exe: *std.Build.Step.Compile,
    },
) std.Build.LazyPath {
    const is_posix = (args.os_tag != .windows);

    const stdlib_modules_common = .{
        ._ssl = (libs.openssl != null),
        .zlib = (libs.zlib != null),

        // Modules that should always be present (POSIX and Windows):
        ._asyncio = true,
        ._bisect = true,
        ._contextvars = true,
        ._csv = true,
        ._datetime = true,
        ._decimal = false, // depends on libmpdec, disabled until it's available
        ._heapq = true,
        ._json = true,
        ._lsprof = true,
        ._multiprocessing = true,
        ._opcode = true,
        ._pickle = true,
        ._queue = true,
        ._random = true,
        ._socket = (args.os_tag != .windows),
        ._statistics = true,
        ._struct = true,
        ._zoneinfo = true,
        .array = true,
        .audioop = true,
        .binascii = true,
        .cmath = true,
        .math = true,
        .mmap = true,
        .select = true,

        // text encodings and unicode
        ._codecs_cn = false,
        ._codecs_hk = false,
        ._codecs_iso2022 = false,
        ._codecs_jp = false,
        ._codecs_kr = false,
        ._codecs_tw = false,
        ._multibytecodec = true,
        .unicodedata = true,

        // Modules with some UNIX dependencies
        ._posixsubprocess = is_posix,
        .fcntl = is_posix,
        ._posixshmem = is_posix,
        .grp = is_posix,
        .ossaudiodev = (args.os_tag == .linux),
        .resource = (args.os_tag == .linux),
        .spwd = (args.os_tag == .linux),
        .syslog = is_posix,
        .termios = is_posix,

        ._md5 = true,
        ._sha1 = true,
        ._sha3 = true,
        ._blake2 = true,

        ._bz2 = false,
        ._lzma = false,

        ._dbm = false,
        ._gdbm = false,
        .readline = false,
        .pyexpat = false,
        ._elementtree = false,
        ._crypt = false,
        .nis = false,
        ._curses = false,
        ._curses_panel = false,
        ._sqlite3 = false,
        ._hashlib = false,
        ._uuid = false,
        ._tkinter = false,
        ._scproxy = false,
        ._xxtestfuzz = false,
        ._testbuffer = false,
        ._testinternalcapi = false,
        ._testcapi = false,
        ._testclinic = false,
        ._testimportmultiple = false,
        ._testmultiphase = false,
        ._ctypes_test = false,
        .xxlimited = false,
        .xxlimited_35 = false,
        ._xxsubinterpreters = false,
    };
    const @"stdlib_modules_3.11.13" = .{
        ._ctypes = true,
        ._typing = true,
        ._sha256 = true,
        ._sha512 = true,
    };
    const @"stdlib_modules_3.12.11" = .{
        ._ctypes = false,
        ._sha2 = false,
        .xxsubtype = false,
        ._xxinterpchannels = false,
    };

    const setup_bootstrap = blk: {
        const replace = b.addRunArtifact(args.replace_exe);
        replace.addFileArg(upstream.path("Modules/Setup.bootstrap.in"));
        const out = replace.addOutputFileArg("Setup.bootstrap");

        const pwd_enabled = is_posix;
        const value_str = if (pwd_enabled) "" else "#";
        replace.addArg(b.fmt("MODULE_PWD_TRUE={s}", .{value_str}));
        break :blk out;
    };

    const setup_stdlib = blk_stdlib: {
        const replace = b.addRunArtifact(args.replace_exe);
        replace.addFileArg(upstream.path("Modules/Setup.stdlib.in"));
        const out = replace.addOutputFileArg("Setup.stdlib");
        replace.addArg("MODULE_{NAME}_TRUE=MODULE_{NAME}_TRUE");
        replace.addArg("MODULE_BUILDTYPE=static");
        addReplaceModuleArgs(b, replace, @TypeOf(stdlib_modules_common), stdlib_modules_common);
        switch (version) {
            .@"3.11.13" => addReplaceModuleArgs(b, replace, @TypeOf(@"stdlib_modules_3.11.13"), @"stdlib_modules_3.11.13"),
            .@"3.12.11" => {
                replace.addArg("MODULE__CTYPES_MALLOC_CLOSURE=");
                addReplaceModuleArgs(b, replace, @TypeOf(@"stdlib_modules_3.12.11"), @"stdlib_modules_3.12.11");
            },
        }
        break :blk_stdlib out;
    };

    const generate = b.addRunArtifact(args.makesetup_exe);
    generate.addDirectoryArg(upstream.path("."));
    const makesetup_out = generate.addOutputDirectoryArg("gen");
    generate.addFileArg(setup_bootstrap);
    generate.addFileArg(setup_stdlib);
    generate.addFileArg(upstream.path("Modules/Setup"));
    return makesetup_out;
}

fn addReplaceModuleArgs(b: *std.Build, replace: *std.Build.Step.Run, comptime Modules: type, modules: Modules) void {
    inline for (std.meta.fields(Modules)) |field| {
        const name = field.name;
        const value = @field(modules, name);
        var upcase_buf: [100]u8 = undefined;
        for (name, 0..) |c, i| {
            upcase_buf[i] = std.ascii.toUpper(c);
        }
        const value_str = if (value) "" else "#";
        replace.addArg(b.fmt("MODULE_{s}_TRUE={s}", .{ upcase_buf[0..name.len], value_str }));
    }
}

fn packagePython(b: *std.Build, version: Version, upstream: *std.Build.Dependency, exe: *std.Build.Step.Compile) struct {
    root: std.Build.LazyPath,
    exe: std.Build.LazyPath,
} {
    const write_files = b.addNamedWriteFiles(exe.name);
    _ = write_files.addCopyDirectory(upstream.path("Lib"), b.fmt("lib/python{s}", .{version.libName()}), .{});
    const empty_dir = b.addWriteFiles().getDirectory();
    _ = write_files.addCopyDirectory(empty_dir, b.fmt("lib/python{s}/lib-dynload", .{version.libName()}), .{});
    if (exe.producesPdbFile()) {
        _ = write_files.addCopyFile(exe.getEmittedPdb(), b.fmt("bin/{s}.pdb", .{exe.name}));
    }
    return .{
        .root = write_files.getDirectory(),
        .exe = write_files.addCopyFile(
            exe.getEmittedBin(),
            b.fmt("bin/{s}", .{exe.out_filename}),
        ),
    };
}

fn addPythonExe(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    args: struct {
        name: []const u8,
        makesetup_out: std.Build.LazyPath,
        pyconfig: Pyconfig,
        stage: PythonExeStage,
    },
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = args.name,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe.root_module.addCMacro("Py_BUILD_CORE", "");
    exe.root_module.addCMacro("_GNU_SOURCE", "");
    switch (optimize) {
        .Debug => {},
        .ReleaseSafe, .ReleaseSmall, .ReleaseFast => {
            const release_date = switch (args.pyconfig.version) {
                .@"3.11.13" => "June 3, 2025",
                .@"3.12.11" => "June 3, 2025",
            };
            // need to redefine __DATE__ and __TIME__ for a reproducible build
            exe.root_module.addCMacro("__DATE__", b.fmt("\"{s}\"", .{release_date}));
            exe.root_module.addCMacro("__TIME__", "\"00:00:00\"");
        },
    }
    exe.root_module.addCMacro("PLATFORM", switch (target.result.os.tag) {
        .linux => "\"linux\"",
        .macos => "\"darwin\"",
        .windows => "\"win32\"",
        else => std.debug.panic("todo: populate PLATFORM for os '{s}'", .{@tagName(target.result.os.tag)}),
    });
    exe.root_module.addIncludePath(args.pyconfig.header.dirname());
    exe.root_module.addIncludePath(upstream.path("."));
    exe.root_module.addIncludePath(upstream.path("Include"));
    exe.root_module.addIncludePath(upstream.path("Include/internal"));
    if (args.stage.stage2FrozenMods()) |mods| {
        exe.root_module.addIncludePath(mods.getpath_h.dirname().dirname());
        exe.root_module.addIncludePath(mods.importlib_bootstrap_h.dirname().dirname().dirname());
        exe.root_module.addIncludePath(mods.importlib_bootstrap_external_h.dirname().dirname().dirname());
        exe.root_module.addIncludePath(mods.zipimport_h.dirname().dirname().dirname());
    }

    switch (args.stage) {
        .freeze_module, .bootstrap => {},
        .final => |final| switch (args.pyconfig.version) {
            .@"3.11.13" => {},
            else => for (final.frozen_headers) |h| {
                exe.root_module.addIncludePath(h.dirname().dirname());
            },
        },
    }

    const flags_common = [_][]const u8{
        "-fwrapv",
        "-std=c11",
        "-fvisibility=hidden",
        "-DVPATH=\"\"",
    };

    {
        const AddModules = struct {
            step: std.Build.Step,
            upstream: *std.Build.Dependency,
            exe: *std.Build.Step.Compile,
            module_compile_args_file: std.Build.LazyPath,
        };
        const add_modules_make = struct {
            fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
                _ = options;
                const io = step.owner.graph.io;
                const self: *AddModules = @fieldParentPtr("step", step);
                const file_path = self.module_compile_args_file.getPath2(step.owner, step);

                const module_compile_args = try std.Io.Dir.cwd().readFileAlloc(io, file_path, step.owner.allocator, .unlimited);
                defer step.owner.allocator.free(module_compile_args);

                var files: std.ArrayList([]const u8) = .empty;
                defer files.deinit(step.owner.allocator);

                var line_it = std.mem.splitScalar(u8, module_compile_args, '\n');
                while (line_it.next()) |line| {
                    if (line.len == 0) continue;
                    if (std.mem.startsWith(u8, line, "# ")) continue;
                    if (std.mem.endsWith(u8, line, ".c")) {
                        try files.append(step.owner.allocator, line);
                    } else if (std.mem.startsWith(u8, line, "-I")) {
                        const path = line[2..];
                        const prefix = "$(srcdir)/";
                        if (!std.mem.startsWith(u8, path, prefix)) std.debug.panic(
                            "expected include path to start with '-I{s}' but got: '{s}'",
                            .{ prefix, line },
                        );
                        const inc_sub_path = step.owner.dupe(path[prefix.len..]);
                        self.exe.root_module.addIncludePath(self.upstream.path(inc_sub_path));
                    } else std.debug.panic("todo: parse module-compile-args line '{s}'", .{line});
                }

                self.exe.root_module.addCSourceFiles(.{
                    .root = self.upstream.path("."),
                    .files = files.items,
                    .flags = &flags_common,
                });
            }
        }.make;
        const add_modules = b.allocator.create(AddModules) catch @panic("OOM");
        add_modules.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("add module sources/includes to {s} exe", .{exe.name}),
                .owner = b,
                .makeFn = &add_modules_make,
            }),
            .upstream = upstream,
            .exe = exe,
            .module_compile_args_file = args.makesetup_out.path(b, "module-compile-args.txt"),
        };
        add_modules.module_compile_args_file.addStepDependencies(&add_modules.step);
        exe.step.dependOn(&add_modules.step);
    }

    exe.root_module.addCSourceFiles(.{
        .root = upstream.path("."),
        .files = switch (args.stage) {
            .freeze_module => concat(b.allocator, &.{
                &.{
                    "Programs/_freeze_module.c",
                    "Modules/getbuildinfo.c",
                    "Modules/getpath_noop.c",
                },
                switch (args.pyconfig.version) {
                    .@"3.11.13" => &library_src_omit_frozen.@"3.11.13",
                    .@"3.12.11" => &library_src_omit_frozen.@"3.12.11",
                },
            }),
            .bootstrap => concat(b.allocator, &.{
                &.{
                    "Programs/_bootstrap_python.c",
                    "Modules/getbuildinfo.c",
                },
                switch (args.pyconfig.version) {
                    .@"3.11.13" => &library_src_omit_frozen.@"3.11.13",
                    .@"3.12.11" => &library_src_omit_frozen.@"3.12.11",
                },
            }),
            .final => concat(b.allocator, &.{
                &.{
                    "Programs/python.c",
                    "Modules/getbuildinfo.c",
                    "Python/frozen.c",
                },
                switch (args.pyconfig.version) {
                    .@"3.11.13" => &library_src_omit_frozen.@"3.11.13",
                    .@"3.12.11" => &library_src_omit_frozen.@"3.12.11",
                },
            }),
        },
        .flags = concat(b.allocator, &.{
            &flags_common,
            switch (args.pyconfig.version) {
                // workaround dictobject.c memcpy alignment issue
                .@"3.11.13" => &.{"-fno-sanitize=alignment"},
                // tokenizer.c uses pointer overflow in restore_fstring_buffers
                .@"3.12.11" => &.{"-fno-sanitize=pointer-overflow"},
            },
        }),
    });

    exe.root_module.addCSourceFile(.{
        .file = args.makesetup_out.path(b, "config.c"),
        .flags = &flags_common,
    });

    switch (args.stage) {
        .freeze_module => {},
        .bootstrap, .final => exe.root_module.addCSourceFile(.{
            .file = upstream.path("Modules/getpath.c"),
            .flags = &(flags_common ++ [_][]const u8{
                "-DPREFIX=\"\"",
                "-DEXEC_PREFIX=\"\"",
                b.fmt("-DVERSION=\"{s}\"", .{args.pyconfig.version.libName()}),
                "-DPLATLIBDIR=\"lib\"",
            }),
        }),
    }
    switch (args.stage) {
        .freeze_module, .bootstrap => {},
        .final => |final| {
            exe.root_module.addCSourceFile(.{ .file = final.deepfreeze_c, .flags = &flags_common });
        },
    }

    if (target.result.os.tag == .windows) {
        exe.root_module.addCSourceFile(.{
            .file = upstream.path("Python/dynload_win.c"),
            .flags = &flags_common,
        });
    } else {
        exe.root_module.addCSourceFile(.{
            .file = upstream.path("Python/dynload_shlib.c"),
            .flags = &(flags_common ++ .{
                "-DSOABI=\"cpython-311-x86_64-linux-gnu\"",
            }),
        });
    }

    if (args.pyconfig.libs.zlib) |zlib| exe.root_module.linkLibrary(zlib);
    if (args.pyconfig.libs.openssl) |openssl| exe.root_module.linkLibrary(openssl);

    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("ws2_32", .{});
        exe.root_module.linkSystemLibrary("api-ms-win-core-path-l1-1-0", .{});
    }

    // TODO: do we need this
    // exe.rdynamic = true;

    return exe;
}

const Pyconfig = struct {
    version: Version,
    libs: Libs,
    header: std.Build.LazyPath,
};

const Libs = struct {
    zlib: ?*std.Build.Step.Compile,
    openssl: ?*std.Build.Step.Compile,
};

fn addPyconfig(
    b: *std.Build,
    conzig_exe: *std.Build.Step.Compile,
    version: Version,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    libs: Libs,
) Pyconfig {
    if (target.result.os.tag == .windows) return .{
        .version = version,
        .libs = libs,
        .header = upstream.path("PC/pyconfig.h"),
    };

    const resolve = b.addRunArtifact(conzig_exe);
    resolve.addArg("resolve");
    resolve.addFileArg(b.path("config-common"));
    resolve.addArg("--also");
    resolve.addFileArg(b.path(b.fmt("config-{t}", .{version})));
    resolve.addArgs(&.{
        "--target",
        target.query.zigTriple(b.allocator) catch @panic("OOM"),
        "--zig",
        b.graph.zig_exe,
        b.fmt("libs.zlib={}", .{libs.zlib != null}),
        "--error-unused-inputs",
        "--resolved",
    });
    const resolved = resolve.addOutputFileArg("pyconfig.conf");

    const header = b.addRunArtifact(conzig_exe);
    header.addArg("header");
    header.addFileArg(resolved);
    header.addFileArg(upstream.path("pyconfig.h.in"));
    return .{
        .version = version,
        .libs = libs,
        .header = header.addOutputFileArg("pyconfig.h"),
    };
}

/// Spells out a native target so Zig uses its own libc rather than the headers and libraries on this
/// machine, which the definitions don't describe. What was native about it stays the same.
fn explicitTarget(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.ResolvedTarget {
    if (!target.query.isNative()) return target;
    const t = target.result;
    if (t.os.tag == .windows) return target;
    // zig 0.16 can't pass this to the libraries it builds for an exe, so it has to be the default
    const standard = t.standardDynamicLinkerPath();
    if (!t.dynamic_linker.eql(standard)) std.debug.panic(
        "this machine's dynamic linker '{s}' isn't the standard '{s}'",
        .{ t.dynamic_linker.get() orelse "", standard.get() orelse "" },
    );
    var query: std.Target.Query = .{
        .cpu_arch = t.cpu.arch,
        .cpu_model = .native,
        .os_tag = t.os.tag,
        .abi = t.abi,
    };
    switch (t.os.versionRange()) {
        .linux => |linux| {
            query.os_version_min = .{ .semver = linux.range.min };
            query.os_version_max = .{ .semver = linux.range.max };
            if (t.isGnuLibC()) query.glibc_version = linux.glibc;
        },
        .semver => |range| {
            query.os_version_min = .{ .semver = range.min };
            query.os_version_max = .{ .semver = range.max };
        },
        else => {},
    }
    return b.resolveTargetQuery(query);
}

const python_src = struct {
    const common = [_][]const u8{
        "Python/_warnings.c",
        "Python/Python-ast.c",
        "Python/Python-tokenize.c",
        "Python/asdl.c",
        "Python/ast.c",
        "Python/ast_opt.c",
        "Python/ast_unparse.c",
        "Python/bltinmodule.c",
        "Python/ceval.c",
        "Python/codecs.c",
        "Python/compile.c",
        "Python/context.c",
        "Python/dynamic_annotations.c",
        "Python/errors.c",
        "Python/frame.c",
        "Python/frozenmain.c",
        "Python/future.c",
        "Python/getargs.c",
        "Python/getcompiler.c",
        "Python/getcopyright.c",
        "Python/getplatform.c",
        "Python/getversion.c",
        "Python/hamt.c",
        "Python/hashtable.c",
        "Python/import.c",
        "Python/importdl.c",
        "Python/initconfig.c",
        "Python/marshal.c",
        "Python/modsupport.c",
        "Python/mysnprintf.c",
        "Python/mystrtoul.c",
        "Python/pathconfig.c",
        "Python/preconfig.c",
        "Python/pyarena.c",
        "Python/pyctype.c",
        "Python/pyfpe.c",
        "Python/pyhash.c",
        "Python/pylifecycle.c",
        "Python/pymath.c",
        "Python/pystate.c",
        "Python/pythonrun.c",
        "Python/pytime.c",
        "Python/bootstrap_hash.c",
        "Python/specialize.c",
        "Python/structmember.c",
        "Python/symtable.c",
        "Python/sysmodule.c",
        "Python/thread.c",
        "Python/traceback.c",
        "Python/getopt.c",
        "Python/pystrcmp.c",
        "Python/pystrtod.c",
        "Python/pystrhex.c",
        "Python/dtoa.c",
        "Python/formatter_unicode.c",
        "Python/fileutils.c",
        "Python/suggestions.c",
    };
    pub const @"3.11.13" = common;
    pub const @"3.12.11" = common ++ .{
        "Python/assemble.c",
        "Python/flowgraph.c",
        "Python/ceval_gil.c",
        "Python/instrumentation.c",
        "Python/intrinsics.c",
        "Python/legacy_tracing.c",
        "Python/tracemalloc.c",
        "Python/perf_trampoline.c",
    };
};

const object_src = struct {
    const common = [_][]const u8{
        "Objects/abstract.c",
        "Objects/boolobject.c",
        "Objects/bytes_methods.c",
        "Objects/bytearrayobject.c",
        "Objects/bytesobject.c",
        "Objects/call.c",
        "Objects/capsule.c",
        "Objects/cellobject.c",
        "Objects/classobject.c",
        "Objects/codeobject.c",
        "Objects/complexobject.c",
        "Objects/descrobject.c",
        "Objects/enumobject.c",
        "Objects/exceptions.c",
        "Objects/genericaliasobject.c",
        "Objects/genobject.c",
        "Objects/fileobject.c",
        "Objects/floatobject.c",
        "Objects/frameobject.c",
        "Objects/funcobject.c",
        "Objects/interpreteridobject.c",
        "Objects/iterobject.c",
        "Objects/listobject.c",
        "Objects/longobject.c",
        "Objects/dictobject.c",
        "Objects/odictobject.c",
        "Objects/memoryobject.c",
        "Objects/methodobject.c",
        "Objects/moduleobject.c",
        "Objects/namespaceobject.c",
        "Objects/object.c",
        "Objects/obmalloc.c",
        "Objects/picklebufobject.c",
        "Objects/rangeobject.c",
        "Objects/setobject.c",
        "Objects/sliceobject.c",
        "Objects/structseq.c",
        "Objects/tupleobject.c",
        "Objects/typeobject.c",
        "Objects/unicodeobject.c",
        "Objects/unicodectype.c",
        "Objects/unionobject.c",
        "Objects/weakrefobject.c",
    };
    pub const @"3.11.13" = common ++ .{
        "Objects/accu.c",
    };
    pub const @"3.12.11" = common ++ .{
        "Objects/typevarobject.c",
    };
};

const parser_src = [_][]const u8{
    // PEGEN_OBJS
    "Parser/pegen.c",
    "Parser/pegen_errors.c",
    "Parser/action_helpers.c",
    "Parser/parser.c",
    "Parser/string_parser.c",
    "Parser/peg_api.c",

    // POBJS
    "Parser/token.c",

    //
    "Parser/myreadline.c",
    "Parser/tokenizer.c",
};

const module_src = [_][]const u8{
    "Modules/main.c",
    "Modules/gcmodule.c",
};

const library_src_omit_frozen = struct {
    pub const @"3.11.13" = parser_src ++ object_src.@"3.11.13" ++ python_src.@"3.11.13" ++ module_src;
    pub const @"3.12.11" = parser_src ++ object_src.@"3.12.11" ++ python_src.@"3.12.11" ++ module_src;
};

const frozen_modules = [_][]const u8{
    "Lib/importlib/_bootstrap.py",
    "Lib/importlib/_bootstrap_external.py",
    "Lib/zipimport.py",
    "Lib/abc.py",
    "Lib/codecs.py",
    "Lib/io.py",
    "Lib/_collections_abc.py",
    "Lib/_sitebuiltins.py",
    "Lib/genericpath.py",
    "Lib/ntpath.py",
    "Lib/posixpath.py",
    "Lib/os.py",
    "Lib/site.py",
    "Lib/stat.py",
    "Lib/importlib/util.py",
    "Lib/importlib/machinery.py",
    "Lib/runpy.py",
    "Lib/__hello__.py",
    "Lib/__phello__/__init__.py",
    "Lib/__phello__/ham/__init__.py",
    "Lib/__phello__/ham/eggs.py",
    "Lib/__phello__/spam.py",
    "Tools/freeze/flag.py",
};

fn frozenModuleNames(version: Version) *const [frozen_modules.len][]const u8 {
    return switch (version) {
        .@"3.11.13" => &frozen_module_name_sets.@"3.11",
        else => &frozen_module_name_sets.@"after_3.11",
    };
}
const frozen_module_name_sets = struct {
    pub const @"3.11" = makeNames(.@"3.11");
    pub const @"after_3.11" = makeNames(.@"after_3.11");
    fn makeNames(when: enum { @"3.11", @"after_3.11" }) [frozen_modules.len][]const u8 {
        var names: [frozen_modules.len][]const u8 = undefined;
        for (&names, frozen_modules) |*name_ref, path| {
            if (std.mem.eql(u8, "Tools/freeze/flag.py", path)) {
                name_ref.* = "frozen_only";
                continue;
            }

            const name = blk_name: {
                const path_prefix = "Lib/";
                const path_suffix = blk: {
                    const init_suffix = "/__init__.py";
                    if (std.mem.endsWith(u8, path, init_suffix)) break :blk init_suffix;
                    break :blk ".py";
                };
                var name_buf: [path.len - path_prefix.len - path_suffix.len]u8 = undefined;
                for (&name_buf, path[path_prefix.len..][0..name_buf.len]) |*name_char, path_char| {
                    name_char.* = switch (path_char) {
                        '/' => switch (when) {
                            .@"3.11" => '_',
                            .@"after_3.11" => '.',
                        },
                        else => |c| c,
                    };
                }
                break :blk_name name_buf;
            };
            name_ref.* = &name;
        }
        return names;
    }
};

fn ci(
    b: *std.Build,
    version: Version,
    ssl_enabled: bool,
    upstream: *std.Build.Dependency,
    ci_step: *std.Build.Step,
    args: struct {
        replace_exe: *std.Build.Step.Compile,
        makesetup_exe: *std.Build.Step.Compile,
        conzig_exe: *std.Build.Step.Compile,
        stage2_frozen_mods: Stage2FrozenMods,
        frozen_headers: []const std.Build.LazyPath,
        deepfreeze_c: std.Build.LazyPath,
    },
) !void {
    const CiTarget = struct { triple: []const u8, ssl: bool };
    const ci_targets = [_]CiTarget{
        // .{ .triple = "x86_64-windows", .ssl = false },
        // .{ .triple = "aarch64-windows", .ssl = true },
        // .{ .triple = "x86-windows", .ssl = true },

        .{ .triple = "x86_64-macos", .ssl = false },
        .{ .triple = "aarch64-macos", .ssl = false },

        .{ .triple = "x86_64-linux-musl", .ssl = true },
        .{ .triple = "x86_64-linux-gnu", .ssl = true },
        .{ .triple = "aarch64-linux-musl", .ssl = false },
        .{ .triple = "aarch64-linux-gnu", .ssl = false },
        // .{ .triple = "arm-linux-musl", .ssl = true }, // zlib doesn't build
        .{ .triple = "riscv64-linux-musl", .ssl = false },
        .{ .triple = "powerpc64le-linux-musl", .ssl = false },
        // .{ .triple = "x86-linux-musl", .ssl = false },
        // .{ .triple = "x86-linux-gnu", .ssl = false },
        .{ .triple = "s390x-linux-musl", .ssl = false },
    };

    for (ci_targets) |ci_target| {
        const target = b.resolveTargetQuery(try std.Target.Query.parse(
            .{ .arch_os_abi = ci_target.triple },
        ));
        const optimize: std.builtin.OptimizeMode = .ReleaseFast;
        const target_dest_dir: std.Build.InstallDir = .{ .custom = ci_target.triple };
        const install = b.step(b.fmt("install-{s}", .{ci_target.triple}), "");
        ci_step.dependOn(install);

        const libs: Libs = .{
            .zlib = (b.dependency("zlib", .{
                .target = target,
                .optimize = optimize,
            })).artifact("z"),
            .openssl = if (ssl_enabled and ci_target.ssl) (if (b.lazyDependency("openssl", .{
                .target = target,
                .optimize = optimize,
            })) |dep| dep.artifact("openssl") else null) else null,
        };
        const makesetup = addMakesetup(b, version, upstream, libs, .{
            .os_tag = target.result.os.tag,
            .replace_exe = args.replace_exe,
            .makesetup_exe = args.makesetup_exe,
        });
        const exe = addPythonExe(b, upstream, target, optimize, .{
            .name = "python",
            .makesetup_out = makesetup,
            .pyconfig = addPyconfig(b, args.conzig_exe, version, upstream, target, libs),
            .stage = .{ .final = .{
                .stage2 = args.stage2_frozen_mods,
                .frozen_headers = args.frozen_headers,
                .deepfreeze_c = args.deepfreeze_c,
            } },
        });

        install.dependOn(
            &b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = target_dest_dir } }).step,
        );
    }
}

fn concat(allocator: std.mem.Allocator, lists: []const []const []const u8) []const []const u8 {
    var total: usize = 0;
    for (lists) |list| {
        total += list.len;
    }
    const result = allocator.alloc([]const u8, total) catch @panic("OOM");
    var index: usize = 0;
    for (lists) |list| {
        for (list) |s| {
            result[index] = s;
            index += 1;
        }
    }
    std.debug.assert(index == total);
    return result;
}

const std = @import("std");
