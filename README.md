# cpython

Builds [cpython](https://github.com/python/cpython) with [Zig](https://ziglang.org/).

There are no system dependencies; the only thing required to build this package is [Zig](https://ziglang.org/).

Supports building a static python executable for linux with the musl abi (i.e. `zig build -Dtarget=x86_64-linux-musl`).

This project also supports building multiple versions of python.

## Config

`config-common` and the `config-VERSION` file for each Python version define what every `pyconfig.h` value means, in the format described in [conzig/README.md](conzig/README.md). During the build, `conzig` resolves them from the target and `zig cc` compile checks, then writes `pyconfig.h` from upstream's `pyconfig.h.in`. Nothing is executed for the target. A value missing from either side is a build error.

Native targets are spelled out explicitly so that Zig uses its own libc rather than the headers and libraries on the machine.

`zig build check-config` runs upstream's `configure` on this machine and shows where `conzig`'s native config differs. It needs a shell and a C compiler, so it's a one-off check and nothing else depends on it. A difference isn't always a mistake, since `configure` sees the machine's libc and libraries, while `conzig` sees Zig's libc and only the libraries the build links.

