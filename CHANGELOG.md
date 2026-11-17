# Changelog

All notable changes to tlang and tcomp are recorded here. The compiler and the
language share one version, reported by `tcomp --version` and kept in sync by
`Tests/version_test.py`.

## 1.2.0

A big update: tlang now builds freestanding binaries with machine builtins,
boots its own desktop kernel, and gives emulator authors bit primitives and
byte-addressed memory access without giving up bounds checks by default. The
compiler is still self-hosting; stage 2 and stage 3 remain byte-identical.

### Added

- Freestanding builds (`--freestanding`, `--entry`, `-T`) and the machine
  builtins they unlock. The compiler emits `call __k_<name>` stubs and no
  syscalls; `Kernel/kruntime.s` supplies them. Both compilers dispatch all 35
  builtins from the generated metadata.
- `Kernel/` is a bootable 1280x1024 desktop with a terminal, editor, files,
  paint and image viewer over TLFS on the IDE slave disk. `Kernel/build.sh`
  checks the image against the MBR's 192-sector load window.
- A logical right shift `>>>` (and `>>>=`) alongside the arithmetic `>>`, so
  emulators can extract unsigned bit fields from negative values without a
  trailing `& 0xFF` mask.
- Bit primitives for emulator work: `clz`, `rbit`, `bswap16/32/64`,
  `sext8/16/32`, `udiv`, `umod` and `rol8`/`ror8`. They replace the masking,
  sign-extension and 64-iteration unsigned-divide loops hand-written in
  tgameboy, tchip8 and taarch64, and are emitted only when used. taarch64's
  width-parameterised helpers are now `soft_udiv`, `soft_rbit` and `soft_clz`,
  since builtin names are reserved.
- Unchecked byte-addressed memory primitives `ld8/16/32/64`, `st8/16/32/64`,
  `memcpy` and `memset`, and a `--no-bounds` build flag that drops ordinary
  index checks. Both are aimed at emulator hot loops; checks stay on by
  default.
- Dense integer `switch` statements compile to a range check and a jump table
  in both compilers; sparse and string switches keep the compare chain.
  taarch64 now uses two such tables: instruction classes switch on bits 28:25,
  and syscall numbers on `number >> 5`.

### Changed

- Smaller binaries from four local rewrites: folding `lea` addresses into call
  arguments and dropping unreachable instructions in stage 0, following jumps
  to prove a compare result dead at a branch, and skipping the startup argv
  capture in the self-hosted compiler unless `argc`, `argv` or `env` is used.
  tbox drops 489 B, tjson 1.4 KB and tgameboy 5 KB; the compiler drops 12%.

### Fixed

- `const` names cannot be written through an index or a field in either
  compiler; stage 0 previously accepted `C[0] = v`.
- The self-hosted compiler accepts machine builtins with three to six
  arguments and the `str` argument of `fb_text`.
- Both compilers agree on the `float()` argument diagnostic and on `const`
  in other diagnostics; stage 0 reports imported files with the relative path
  the user wrote.
- `--entry` now selects the function `_start` calls in hosted builds too, and
  no longer passes a stray `-e main` to `ld`.
- The Wayland module reads environment variables with `env()` instead of
  slicing `/proc/self/environ`. Its entries are NUL-separated, so once `slice()`
  was bounds-checked against `strlen()`, every entry after the first was
  rejected and `tw_open` died before connecting. `Tests/wayland_test.py` now
  times out if the client never connects, so this cannot hang CI again.

### Sizes

`tcomp` is 158,970 B (stage 0 builds it at 173,665 B); hello is 321 B and an
empty `main` is 256 B. The fixed point holds.

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
