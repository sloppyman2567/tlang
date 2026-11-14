# Changelog

All notable changes to tlang and tcomp are recorded here. The compiler and the
language share one version, reported by `tcomp --version` and kept in sync by
`Tests/version_test.py`.

## 1.1.0

### Added

- Runtime bounds checking for array indexing. An out-of-range index writes
  `tlang: index out of bounds` to stderr and exits with status 134; the check
  is a header load and two branches. `Tests/bounds_test.py` covers it in both
  compilers, and CI runs it.
- Both compilers now reject a program with no `fn main()`, a `main` that takes
  parameters, a duplicate `fn`, global or `struct`, and a call to a function
  that is never defined. Each error carries a source position; previously the
  self-hosted compiler left these to `as` and `ld`.
- `alloc` rejects negative or oversized counts with
  `tlang: invalid allocation size` instead of wrapping.

### Changed

- String indices are checked for negatives. The upper bound stays open: strings
  carry no length, and writing at `strlen(s)` is how a NUL-terminated buffer
  grows.
- `slice` rejects ranges outside its source string, `concat` and `slice` guard
  their length arithmetic against overflow, and an out-of-range `argv` index
  returns `""` instead of reading past the argument vector.
- Pointer arithmetic lowers to `ptr` rather than `arr`, so interior pointers
  are never bounds-checked as a whole array.
- `Tests/version_test.py` derives its expected version from
  `Bootstrap.__version__`, so a release bump edits two files instead of also
  editing the test that guards them.

### Sizes

`tcomp` grew from 106,157 B to 113,623 B (+7%) for the checks. Programs grew
with it: tbox 7,092 → 8,741 B, tjson 13,327 → 16,059 B, tbf 3,612 → 5,198 B,
tchip8 24,066 → 31,316 B, tgameboy 42,265 → 46,419 B. The fixed point holds at
113,623 B.

## 1.0.0

First release: a self-hosting compiler written in tlang, a syscall-only runtime,
the `Programs/` suite, the C translator, and the `taarch64` interpreter.
