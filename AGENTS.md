# AGENTS.md

Project-specific guidance for coding agents. See `README.md` for the full
architecture, test list and known limitations.

## Ground rules

- tlang is self-hosting. A language or compiler change must land in both
  `Bootstrap/` (stage 0, Python) and `tcomp.tl` (self-hosted), and stage 2 and
  stage 3 must remain byte-identical.
- The release version is `1.1.0`; `Bootstrap.__version__` and
  `tcomp.tl`'s `TLANG_VERSION` must agree (`Tests/version_test.py`). A release
  bumps both and adds a `CHANGELOG.md` entry.
- `Bootstrap/runtime.py`, `Bootstrap/builtin_spec.py` and `Tools/gen_kinds.py`
  are sources of truth. `Runtime/runtime_gen.tl`, `Runtime/kinds_gen.tl`,
  `Runtime/builtins_gen.tl`, `Bootstrap/kindrules_gen.py` and
  `Bootstrap/builtins_gen.py` are generated; never edit them by hand.
- Match the style of the surrounding code and do not add dependencies.
- `taarch64` is always lowercase.
- A program needs exactly one parameterless `fn main()`; a function, global
  or struct defined twice, or a call to a function that is never defined, is a
  compile error. Both compilers must report these with a source position;
  `Tests/errors_test.py` covers them.
- Array indexing is bounds-checked by default, and string indices are
  checked for negatives. Keep `Tests/bounds_test.py` passing in both
  compilers, and keep the generated runtime's `__t_bounds_fail` path in sync.
- Update `README.md` when a compiler size, timing, test count or the layout
  changes.

## Build and check

```bash
python3 Tests/version_test.py    # stage 0 and tcomp.tl report tcomp 1.1.0
python3 Tests/run_tests.py       # golden output, exit status, binary size
python3 Tests/diff_test.py       # optimized and --no-opt builds agree
python3 Tests/compare_test.py    # stage 0 and self-hosted compiler agree
python3 Tests/builtins_test.py   # builtin metadata contract
python3 Tests/runtime_test.py    # runtime dependency and assembly contract
python3 Tests/sourcemap_test.py  # imported-file diagnostics
python3 Tests/bounds_test.py     # checked indexing and runtime guards
Tools/selfhost.sh --verify       # stages 2 and 3 must be byte-identical
```

Run the broader suites when the change touches them:

```bash
python3 Tests/programs_test.py
python3 Tests/errors_test.py
python3 Tests/modules_test.py
python3 Tests/floats_test.py
python3 Tests/io_test.py
```

## Generated modules

After changing the runtime, the kind rule or builtin metadata, regenerate before
running tests:

```bash
python3 Tools/gen_runtime.py
python3 Tools/gen_kinds.py
python3 Tools/gen_builtins.py
```

All three scripts accept `--check`; `Tools/selfhost.sh` fails on stale output.

## Tests

Add cases under `Tests/Cases/` as `NAME.tl`, optionally with `NAME.in`,
`NAME.out` and `NAME.code`. `Tests/run_tests.py --update` rewrites golden
files, so inspect the diff before trusting it.
