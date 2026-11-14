# taarch64

A user-mode AArch64 (ARM64) interpreter for static Linux binaries, written in
[tlang](../README.md).

`taarch64` owns a flat guest address space, loads an `ET_EXEC` image into it,
executes the A64 subset listed below, and translates `svc #0` calls onto the
host. It is an ordinary tlang program and does not depend on the compiler's
internals.

The acceptance test is a normal static musl binary: an unmodified
`printf`/`malloc`/`fgets`/`qsort` program runs and matches `qemu-aarch64` byte
for byte, including exit status.

```bash
./taarch64/taarch64 hello.musl          # hello, musl!
```

It is deliberately a small emulator, not a replacement for `qemu-aarch64`: the
goal is that a guest program either runs correctly or stops with a diagnostic
naming the instruction or syscall it could not handle.

That first musl run is the project milestone: tlang's compiler is self-hosting,
and the interpreter produced by `Build/tcomp` runs the same guests as the
stage-0 build. A language that compiles itself is now emulating another
architecture, end to end, from source.

## Scope

Supported guests:

* AArch64 Linux, little-endian, ELF64 `ET_EXEC`
* no `PT_INTERP` and no dynamic loader
* static binaries linked against musl, and freestanding ones built with
  `-static -nostdlib`
* executables linked at the conventional `0x400000` base
* one thread, no signals, no `fork`/`clone`

Dynamic executables are rejected during loading with an explanation. A static
glibc binary loads, but glibc's startup uses SIMD arithmetic this interpreter
does not implement, so it stops with `unsupported instruction ...`.

## Build

```bash
./taarch64/build.sh              # build with the stage-0 compiler
./taarch64/build.sh --selfhost   # build with Build/tcomp (see Tools/selfhost.sh)
```

The host needs python3 and binutils. A cross compiler, a musl sysroot and
`qemu-aarch64` are only needed to build and check guest programs.

## Run

```bash
./taarch64/taarch64 FILE.a64
```

Exactly one argument is accepted; guest arguments are not supported yet, so the
guest always sees `argc = 1` and `argv[0]` set to its own path. The guest's exit
status is the process exit status.

## Machine model

| | |
|---|---|
| Guest memory | 16 MiB, flat, starting at `0x400000` |
| Registers | `x0`–`x30`, `sp`, `pc`, condition flags |
| SIMD registers | 32 × 128-bit, storage plus the scalar moves listed below |
| Stack | top of guest memory, 1 MiB reserved below it |
| Heap | `brk`/anonymous `mmap` grow up from the end of the image |
| Syscalls | `x8` selects, `x0`–`x5` arguments, result in `x0` |

Guest pointers are real addresses: the loader copies each `PT_LOAD` segment to
`BASE + p_vaddr`, so no relocation or page table is involved.

The startup stack is a real Linux one: `argc`, `argv`, an empty `envp`, and an
auxiliary vector carrying `AT_PHDR`/`AT_PHENT`/`AT_PHNUM`, `AT_ENTRY`,
`AT_PAGESZ`, `AT_RANDOM` and `AT_EXECFN`. libc needs all of it: musl walks the
program headers through `AT_PHDR` to find `PT_TLS`, installs that block through
`TPIDR_EL0`, and seeds its stack canary from `AT_RANDOM`.

## Instruction coverage

The scalar integer A64 that `gcc -O2` emits for C, plus the vector instructions
needed to move constants in and out of the 128-bit registers:

* **branches** — `b`, `bl`, `b.cond`, `cbz`/`cbnz`, `tbz`/`tbnz`, `br`, `blr`, `ret`
* **immediates** — `adr`/`adrp`, add/subtract immediate, logical immediate,
  move-wide (`movz`/`movn`/`movk`), bitfield (`sbfm`/`bfm`/`ubfm`), `extr`
* **registers** — logical shifted, add/subtract shifted and extended, `csel`
  family, `ccmp`/`ccmn`, `udiv`/`sdiv`, register shifts and rotates, bit
  manipulation (`rbit`, `rev16`, `rev32`, `rev`, `clz`, `cls`), and the
  multiply-add family (`madd`/`msub`, long variants, `smulh`/`umulh`)
* **loads/stores** — byte/half/word/double with unsigned immediate, unscaled,
  pre/post-index and register offsets; sign-extending loads; literal loads;
  `ldp`/`stp`; and 128-bit `ldr q`/`str q` in all of those addressing forms
* **atomics** — `ldxr`/`ldaxr`, `stxr`/`stlxr` and `ldar`/`stlr` at byte through
  double, with a one-address exclusive monitor; this is how libc takes its
  stdio, malloc and TLS locks, and `dmb`/`dsb`/`isb` are accepted
* **SIMD moves** — `dup` (general), `umov` and `movi`; there is no vector
  arithmetic, so an auto-vectorized loop stops with a diagnostic
* **system** — hints (`nop`, `yield`, `wfe`, `wfi`, `sevl`, `bti`),
  `paciasp`/`autiasp` as no-ops (nothing is ever signed), `svc`, `brk` as a
  labelled diagnostic, and reads/writes of `TPIDR_EL0`, `CNTVCT_EL0`,
  `CNTFRQ_EL0` and `DCZID_EL0`. `DCZID_EL0` reports 64-byte blocks with `dc zva`
  prohibited, so libc's `memset` uses ordinary stores

Anything else stops with the instruction word and program counter.

## Syscalls

`x8` selects the call. Success returns the result; failure returns the negated
errno, exactly as the kernel does, so libc's wrappers take their normal error
path instead of seeing a success that did nothing.

| `x8` | call | behaviour |
|---|---|---|
| 29 | `ioctl` | `-ENOTTY`: the guest never sees a terminal, so stdio uses full buffering |
| 57 | `close` | marks descriptor 0–2 closed in the guest's own table |
| 63 / 65 | `read`, `readv` | one host read, scattered over the caller's buffers |
| 64 / 66 | `write`, `writev` | loops over short host writes, in order |
| 93 / 94 | `exit`, `exit_group` | process exit with `x0 & 255` |
| 96 | `set_tid_address` | remembers the pointer, returns the virtual tid |
| 99 | `set_robust_list` | accepted: one thread, no list to track |
| 113 | `clock_gettime` | real time from `/proc/uptime` plus `/proc/stat`'s `btime` |
| 114 | `gettimeofday` | the same clock, timezone argument ignored as Linux does |
| 172–178 | `getpid`, `getppid`, `getuid`, … | the single virtual process: pid/tid 1, ppid and ids 0 |
| 214 | `brk` | grows or shrinks the break, refuses below the image or past the heap limit |
| 215 | `munmap` | zeroes the range; unmapped pages are never handed out again |
| 222 | `mmap` | anonymous only, page-aligned, from the same bump pointer; `MAP_FIXED` is honoured by raising the break above the range |
| 226 | `mprotect` | range-checked; one flat address space means permissions are not enforced |
| 233 | `madvise` | `MADV_DONTNEED` zeroes the range, other advice is accepted |
| 278 | `getrandom` | bytes from `/proc/sys/kernel/random/uuid`; zeros if `/proc` is unavailable |
| 293 | `rseq` | `-ENOSYS`, so libc falls back to its lock-based path |

Everything else stops with the number and program counter. In particular there
is no `openat` (a guest can only use the descriptors it inherited), no
file-backed `mmap`, no `lseek` — the host descriptor cannot be repositioned, so
the call stops rather than claim success — and no threads, signals or sockets.

## Running a musl hello world

Any static musl toolchain works; this is the exact form used to check the
interpreter:

```bash
cat > hello.c <<'EOF'
#include <stdio.h>
int main(void) { printf("hello, musl!\n"); return 0; }
EOF

# With a musl cross compiler:
aarch64-linux-musl-gcc -static -O1 -o hello.musl hello.c

# Or with a cross gcc pointed at a musl sysroot:
aarch64-linux-gnu-gcc -nostdinc -isystem /usr/aarch64-linux-gnu/lib/musl/include \
  -static -O1 -o hello.musl hello.c -L/usr/aarch64-linux-gnu/lib/musl/lib

qemu-aarch64 hello.musl                 # hello, musl!
./taarch64/taarch64 hello.musl          # hello, musl!
```

At startup musl calls `set_tid_address`, `ioctl(1, TIOCGWINSZ, …)`,
`writev(1, …)` and `exit_group`, so those four are the difference between
`hello` working and stopping on the first `puts`.

## Checking a guest against qemu

`qemu-aarch64` is the reference oracle for new instruction and syscall coverage:

```bash
qemu-aarch64 hello.musl > expected; echo $? > expected.code
./taarch64/taarch64 hello.musl > actual; echo $? > actual.code
cmp expected actual && cmp expected.code actual.code
```

Verified this way, byte for byte and exit status included: a musl hello world,
`printf` formatting, `malloc`/`free` with several hundred allocations, stdio
`fread`/`fgets` from stdin, 130 KB of buffered output, `qsort`, and freestanding
`-nostdlib` programs covering arithmetic, division, branches, `brk` memory,
128-bit copies, `clz`/`rbit`/`rev`, `extr` and `__int128` shifts. There is no
committed `taarch64` harness yet.

## Limitations

* Dynamic ELF, shared libraries, `PT_INTERP` and static-PIE are rejected.
* No threads, signals, `clone`, futex or file-backed `mmap`.
* No SIMD arithmetic: vectors are storage for `ldr q`/`str q` and the scalar
  `dup`/`umov`/`movi` moves. An auto-vectorized loop stops with a diagnostic.
* No atomics beyond the exclusive load/store family; no `dmb` ordering effects,
  which is invisible with a single guest thread.
* No `openat`, `lseek`, sockets or `ioctl` other than the terminal probes.
* `munmap`/`madvise` zero memory instead of returning it, and `mprotect` is
  accepted without enforcement: there is one flat, writable address space.
* Time comes from `/proc/uptime` and `/proc/stat`; CPU-time clocks are
  `-EINVAL`, and `getrandom` is only as random as
  `/proc/sys/kernel/random/uuid`.
* 16 MiB total guest memory; the image must fit and the heap cannot grow into
  the reserved stack region.
* Guest arguments, `argc > 1` and a real `envp` are not set up yet.
* Linux x86-64 hosts only, because the host toolchain is tcomp.

## Layout

| File | Purpose |
|---|---|
| `src/taarch64.tl` | entry point, Linux startup stack, `main` |
| `src/machine.tl` | guest registers, flat memory, byte/word accessors, exclusive monitor |
| `src/elf.tl` | `ET_EXEC` validation and `PT_LOAD` placement |
| `src/exec.tl` | A64 decoder, instruction groups and the run loop |
| `src/syscalls.tl` | Linux AArch64 syscall translation, clock and entropy |
| `build.sh` | assemble/link wrapper for stage 0 or `Build/tcomp` |
