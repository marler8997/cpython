# cpython

Builds [cpython](https://github.com/python/cpython) with [Zig](https://ziglang.org/).

There are no system dependencies; the only thing required to build this package is [Zig](https://ziglang.org/).

Supports building a static python executable for linux with the musl abi (i.e. `zig build -Dtarget=x86_64-linux-musl`).

This project also supports building multiple versions of python.

## Generating static config

`config.txt` holds the `pyconfig.h` values for every combination of inputs that has been tested. The inputs are the Zig version, Python version, OS, CPU and ABI, and they're listed in `config.zig`. Values come from upstream's real `configure` run with `zig cc` in cross compile mode, so nothing is executed for the target and the result doesn't depend on the machine or what's installed on it.

```sh
zig build update-config  # test the combinations config.txt doesn't list yet and add them
zig build verify-config  # test every combination for this Zig version again and change nothing
zig build check-config   # test nothing, fail if config.txt is missing a combination
```

`update-config` does nothing if every combination is already listed, so to add a Python version or move to a new Zig version, change `build.zig.zon` or Zig and run it. It saves as it goes, so it can be stopped and run again. A combination that `configure` can't do is recorded as `failed` so it isn't tried again.

If `verify-config` gets a different result for a combination that was already tested, something that affects config isn't one of the inputs. To add an input, append it to `input_names` in `config.zig` and enumerate it in `updateconfig.zig`. Combinations already in `config.txt` don't have the new input, so `update-config` tests them again.

Review the result with `git diff config.txt`. The format is described in `config.zig`:

```
verified zig=0.16.0 python=3.11.13,3.12.11 os=linux arch=x86_64 abi=gnu glibc=2.30,2.31 yes
verified zig=0.16.0 python=3.11.13,3.12.11 os=linux arch=x86_64 abi=musl glibc=none yes
HAVE_CRYPT_H 1
HAVE_CRYPT_H abi=gnu,gnuabi64,gnuabin32,gnueabi,gnueabihf,gnux32 undef
```

Each value reduces to a default plus the combinations that differ from it, using only the inputs it depends on. `verified` always lists every input, because it has to mean exactly what was tested. Linux and macOS targets are tested, with every glibc from 2.16 (Python needs `getauxval` to link) up to the newest Zig has. A build uses the newest tested glibc that isn't newer than its target, and a combination that isn't verified fails with a message.

Something only becomes an input if it changes a value. `glibc` is one because it decides functions like `close_range` and `strlcpy`.
