# conzig

Defines what each value in a C project's config header means, separately from how that value gets
answered. A definition says "this header exists" or "this is a big endian target". Whether the answer
comes from a table of known results, a compile check or the target is up to whatever evaluates it.

## Format

A file is a flat list of definitions, one per line. Lines starting with `#` are comments.

```
NAME ? PASS|FAIL KIND [ARGS] [ATTRS] [if EXPR] [assume EXPR]
    BODY
NAME sizeof "TYPE"
NAME VALUE
```

`PASS` and `FAIL` are the values for when the check is true and false, usually `1|undef`:

```
HAVE_ALLOCA_H ? 1|undef have-header alloca.h
HAVE_ZLIB_H ? 1|undef when build.zlib
SIZEOF_LONG sizeof long
RETSIGTYPE :void
```

Indented lines after a definition are its body. `local` before the name makes a helper that other
definitions can use but that isn't a value in the header. A definition can only use names defined
above it. When `if` is false the value is `FAIL` without checking anything.

These are true or false, so they need `? PASS|FAIL`:

| Kind | True when |
|---|---|
| `have-header FILE` | the header can be included |
| `have-function NAME` | the headers in `include=` declare it and it links, it can be a macro |
| `have-type "TYPE"` | the headers in `include=` define the type |
| `have-member "TYPE" FIELD` | the type has the field |
| `have-decl NAME` | the headers in `include=` declare the constant, variable or macro |
| `compiles` + body | the complete program in the body compiles, for what none of those cover |
| `links` + body | the complete program in the body links, for what none of those cover |
| `runs` + body | the complete program in the body exits with 0, `assume` is required |
| `exists PATH` | the path exists where the program runs, `assume` is required |
| `when EXPR` | the expression is true |

These have a value of their own:

| Kind | Value |
|---|---|
| `sizeof "TYPE"` | its size in bytes |
| `alignof "TYPE"` | its alignment in bytes |
| `select` + body | the first line of the body that matches, as `VALUE if EXPR`, the last has no `if` |

A value uses the same syntax as a `ConfigHeader` config file: `undef`, `defined`, `false`, `true`, an
integer, a `"string"` or `:an ident`. Strings and idents are used verbatim, with no escapes. A `PASS`
or `FAIL` ident can't have spaces, because a space ends `PASS|FAIL`.

`runs` and `exists` ask about the machine the program will run on, which can't be checked when cross
compiling, so `assume` says what to expect there.

Attributes are `include=FILE`, `define=NAME[=VALUE]` and `lib=NAME`. They can repeat or be a comma
separated list. A `prelude` line
gives attributes that apply to every check. Values with spaces go in double quotes.

## Expressions

`&&`, `||`, `!`, parentheses, and `==`, `!=`, `<`, `<=`, `>`, `>=`. The operands are:

- `true` and `false`
- integers, and versions like `2.34`
- enum literals like `.windows`
- names: an input, which has a dot like `target.os.tag`, or a definition from above

The project decides which inputs exist and passes them in, such as `target.os.tag`.
Nothing here knows about any one project or target.

The host and the target are different things when cross compiling, so inputs should say which one
they mean, like `target.os.tag` or `host.os.tag`. `runs` and `exists` are about the target.

## Resolving

    conzig check FILE
    conzig resolve FILE [--also FILE...] [--target TRIPLE] [--zig PATH] [NAME=VALUE...]
                   --resolved OUT [--unresolved OUT] [--needed OUT] [--error-unused-inputs]
    conzig header RESOLVED TEMPLATE OUT

`resolve` answers what it can with the inputs it's given. The results go in `--resolved`, which is a
`ConfigHeader` config file with a line for each value, leaving out `local` ones.

Everything else goes in `--unresolved`, which is a file in this same format for another run to
continue from. So a project can resolve some values ahead of time and commit them, then resolve the
rest during the build with more inputs. Leaving `--unresolved` out means there's nothing left to come
back for, so anything unresolved is an error that says what it needs.

The unresolved file starts with `input NAME=VALUE` lines for the inputs it has been given, because
its results are only right for those. Giving the next run a different value for one is an error. It
also has `local` copies of the resolved values that the rest use.

`--target` is a whole Zig target like `x86_64-linux-gnu.2.39`. It gives the inputs `target.os.tag`,
`target.cpu.arch`, `target.cpu.endian`, `target.abi.tag` and `target.triple`. Part of a target is
given by passing those inputs directly, like `target.os.tag=linux`, which resolves what only depends
on them and leaves the rest for a later run.

`--zig` is the path to Zig, which needs `--target`. Compile checks run `zig cc -target TRIPLE`. Without
it, the definitions that need a compiler are unresolved. Nothing has to run, so this works when cross
compiling. A target that Zig can't build a trivial program for is an error. It gives the input
`zig.version`, so results can't be reused with a different Zig or target.

`--also` adds another file, as if it came after the ones before it.

`--needed` writes what the next run would have to be given to finish, one per line: the name of each
input, and `compiler` if a check is left.

`--error-unused-inputs` makes it an error to give an input that no definition uses, which catches a
build working out something that isn't needed.

`header` turns a resolved file into a C header by replacing each `#undef NAME` line in an autoconf
template. A template line with no value, or a value that isn't in the template, is an error.
