# Changelog

All notable changes to tlang and tcomp are recorded here. The compiler and the
language share one version, reported by `tcomp --version` and kept in sync by
`Tests/version_test.py`.

## 1.5.0

### License

- The project is released into the public domain under the Unlicense; see
  `UNLICENSE`.

### Added

- `Modules/tjson.tl`: a reusable JSON parser, tree accessor API and
  pretty/compact emitter. `Programs/tjson.tl` now imports it instead of
  carrying its own copy, and parsing rejects leading zeroes, incomplete
  fractions or exponents, raw control characters and unknown escapes.
  `json_get` also accepts quoted bracket keys such as `.["a.b"]` and matches
  escaped object keys after decoding them.
- `Modules/tjson.tl`: `json_pointer` implements RFC 6901 pointer resolution,
  including `~0`/`~1` decoding and strict array indices. `tjson get` and
  `tjson keys` accept `--pointer`; `json_get` accepts negative jq-style array
  indices. Decoded strings and keys now write non-ASCII `\uXXXX` escapes,
  including surrogate pairs, as UTF-8.
- `Modules/tjson.tl`: constructors and mutable array/object updates for
  building documents. `json_new_string` escapes text, `json_new_number`
  validates the number grammar, and updates return the node to keep. Direct
  and indirect cycles are rejected; in-place runs are extended when possible
  and copied otherwise.
- `Modules/tzip.tl`: ZIP archives with CRC-32. `zip_open` reads central
  directories and `zip_data`/`zip_extract` decompress stored and deflated
  entries, including both fixed and dynamic Huffman blocks. The writer picks
  stored or DEFLATE compression per entry, so repetitive files shrink without
  making incompressible or empty files larger.
- `Modules/tport.tl`: portable command-line helpers for paths, `PATH` lookup,
  process launch, stdin, binary file copy/move and recursive directory
  creation. `port_run` inherits the caller's environment and returns a
  shell-style status.
- `Tests/stdlib_test.py`: JSON and ZIP differential tests against Python's
  `json` and `zipfile` modules in both compilers, including compressed, binary,
  empty and UTF-8-named entries, large archives and writer round trips.
- `Tests/portability_test.py`: exercises the portable module in both compilers,
  including a 70 KB stdin read and a child process that checks its inherited
  environment.

### Changed

- `exec` now passes the caller's environment to the new program instead of an
  empty environment. A portable tool launched with `exec` keeps `PATH`, `HOME`
  and locale settings. The self-hosted compiler captures `argc/argv` when a
  program calls `exec`, since that is where `envp` starts.
- `Tools/tcomp-seed` was rebuilt at 1.5.0 so the checked-in bootstrap compiler
  reports the release version.

### Fixed

- `port_base("/")` returns `/`, and `port_copy` rejects directories and other
  non-regular sources and detects short reads instead of creating a truncated
  file.
- `json_child`, `json_get` and `json_has` handle invalid tree indices without
  an out-of-bounds access. The JSON and ZIP tests now exercise repository
  source, real archives and streamed archives with data descriptors.

### Removed

- The `--ir` and `--no-opt` options. The self-hosted compiler emits assembly
  directly and has no separate optimization mode, so `--ir` could only fail
  and `--no-opt` did nothing.

### Sizes

`tcomp` is 203,157 B; hello is 363 B and an empty `main` is 300 B. The
programs are tbox 6,767 B, tjson 27,728 B, tbf 4,464 B, tchip8 18,976 B and
tgameboy 30,529 B. The fixed point holds.

## 1.4.0

### Added

- `free`, `realloc`, `memmove` and `memcmp`. The arena now keeps power-of-two
  size-class free lists: `free` makes a block reusable, `realloc` shrinks in
  place or grows by copying, and `arena_release` drops free blocks above the
  mark. A fresh allocation keeps its exact capacity; a reused block may have
  spare slots for `append`.
- The C translator now emits `free` instead of dropping it, so translated C
  that releases memory no longer grows the arena for the life of the process.
- Filesystem navigation and identity builtins: `chdir`, `rmdir`, `truncate`,
  `ftruncate`, `getuid`, `geteuid`, `getgid` and `getegid`.
- Anonymous memory mappings: `mmap`, `munmap` and `mprotect`. The result of
  `mmap` is a byte buffer, so `ld8`/`st8` and `memcpy` address it directly.
- Blocking TCP over numeric IPv4: `tcp_connect`, `tcp_listen` and
  `tcp_accept`. There is no resolver, IPv6, UDP or TLS.

### Changed

- The Python stage-0 compiler is gone. `tcomp.tl` is the only compiler;
  `Tools/tcomp-seed` is a checked-in build used to bootstrap it, and `./tcomp`
  is a thin driver that assembles and links its output. The Python runtime,
  builtin metadata, ELF trimming and generators remain as the single source of
  truth. `Tests/diff_test.py` and `Tests/compare_test.py` were removed: with one
  compiler there is no optimized/unoptimized or stage-0/stage-1 comparison to
  make. Sizes are from the self-hosted compiler alone.

### Fixed

- `mmap` now returns `0` on failure instead of a negative errno, which a byte
  buffer cannot be compared against. TCP rejects ports outside 1–65535, IPv4
  addresses with empty octets, and octets longer than three digits instead of
  truncating the port or wrapping the octet to a small value.
- `newbuf` rejects a negative size with the allocator diagnostic, and `realloc`
  keeps a struct's field type so field access still compiles.
- Forward calls now keep their return type: prescan records explicit return
  annotations and infers literal returns, so `"x" + f()` converts an int return
  to a string instead of passing the integer to `concat` as a pointer. This was
  a real miscompilation in the self-hosted compiler that made the shipped
  stage-2 binary crash on those programs.
- Generated arity diagnostics use `str(count)` explicitly, which compiles
  correctly regardless of the forward-call typing above.

- Closing a directory fd with `close_fd` now releases its `read_dir` cursor,
  just as `close_dir` does. Reusing the fd number for another directory no
  longer continues the previous directory's iteration. `close_dir` is now a
  thin alias for `close_fd`, and `builtins_test.py` validates generated-builtin
  dependency flags so a missing runtime helper fails at metadata check time.

### Sizes

`tcomp` is 203,027 B; hello is 363 B and an empty `main` is 300 B. The fixed
point holds and the checked-in seed emits the same assembly as stage 2.

## 1.3.0

### Added

- Directory and metadata builtins: `open_dir`, `read_dir`, `close_dir`,
  `file_mode`, `is_dir`, `is_file`, `symlink`, `readlink` and `chmod`.
  `read_dir` keeps up to four buffered directory cursors, skips `.` and `..`,
  and returns each name as a separate string.
- Process builtins: `fork`, `exec`, `waitpid`, `pipe`, `dup2`, `kill` and
  `getppid`. `waitpid` returns the raw wait status, and `exec` marshals a
  string array into `argv` (at most 128 entries; longer arrays fail with `-1`
  instead of being truncated). Both groups are hosted-only, generated through
  the shared builtin pipeline, and covered by `Tests/linux_extra_test.py`.

### Changed

- Generated builtin dispatch now uses the shared `types_ok` kind rule, so the
  self-hosted compiler accepts an untyped array where stage 0 does
  (`pipe(alloc(2))` used to be rejected by stage 1 alone).
- Wrong argument counts for generated builtins now produce the same named
  diagnostic in both compilers (`chmod() takes 2 argument(s), got 1`), instead
  of a generic token error in the self-hosted one.

### Fixed

- `read_dir` copies each entry to the start of its freshly allocated buffer;
  an earlier version left the string empty after `newbuf` clobbered `rdi`.
- `close_dir` releases the `read_dir` cursor, so a reused fd cannot continue
  reading the previous directory's entries.
- `exec` NULL-terminates argv at the real argument count, so a dirty stack can
  no longer make the new program see up to 128 arguments.
- `waitpid(pid, WNOHANG)` returns `0` when no child is ready instead of reading
  an uninitialised status slot.
- A fifth concurrent `read_dir` cursor now returns `""` cleanly instead of
  reading past the four-slot cursor arrays in BSS.

### Sizes

`tcomp` is 182,842 B (stage 0 builds it at 199,195 B); hello is still 321 B.
The fixed point holds.

## 1.2.2

### Added

- Common Linux builtins for source portability: `now()` (nanoseconds since the
  epoch), `sleep_ns(n)`, `random_int()`, `getpid()`, `mkdir(path, mode)`,
  `unlink(path)`, `rename(old, new)`, `getcwd()`, `open_fd(path, flags)`,
  `close_fd(fd)` and `file_mtime(path)`. They are hosted-only, work in both
  compilers, and are covered by `Tests/portability_test.py`.

### Fixed

- The self-hosted compiler now captures `argc` when a program uses `argv()`.
  `argv()` bounds-checks against the count, so programs that used `argv` without
  `argc` or `env` always saw an empty argument vector.
- The optimizer no longer folds `INT_MIN / -1` or `INT_MIN % -1` into a
  constant. x86 `idiv` traps on both, so the unoptimized build used to raise
  SIGFPE while the optimized build printed a value. Both builds now trap.

### Changed

- Plain builtins listed in `GENERATED_BUILTINS` now get their `tcomp.tl` dispatch
  and runtime emission generated from `Bootstrap/builtin_spec.py`. Adding one
  needs a spec entry, a runtime helper and regeneration, but no hand-written
  compiler branch; the new Linux builtins are the first users.

### Sizes

`tcomp` is 166,639 B (stage 0 builds it at 178,896 B); hello is still 321 B.
The fixed point holds.

## 1.2.1

### Added

- A project icon (`tlang-icon.svg` and `tlang-icon.png`) and CI/version badges
  in the README header.

### Changed

- `VERSION` is now the single source of truth for the compiler version. Stage 0
  reads it in `Bootstrap/__init__.py`; `Tools/gen_version.py` generates the
  `Runtime/version_gen.tl` constant that `tcomp.tl` imports. A release bump
  edits one file, and CI checks the generated copy is current.

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
