# taarch64

A user-mode AArch64 (ARM64) interpreter for small static Linux binaries, written
in [tlang](../README.md).

`taarch64` owns a flat guest address space, loads an `ET_EXEC` image into it,
decodes and executes the A64 integer subset, and translates `svc #0` calls onto
the host. It is an ordinary tlang program and does not depend on the compiler's
internals.

It is deliberately a small emulator, not a replacement for `qemu-aarch64`: the
goal is that a guest program either runs correctly or stops with a diagnostic
naming the instruction or syscall it could not handle.

## Scope

Supported guests:

* AArch64 Linux, little-endian, ELF64 `ET_EXEC`
* no `PT_INTERP` and no dynamic loader
* freestanding binaries built with `aarch64-linux-gnu-gcc -static -nostdlib`
* executables linked at the conventional `0x400000` base
* one thread, no signals, no `fork`/`clone`

Dynamic executables are rejected during loading with an explanation. A fully
static glibc binary loads, but glibc's startup uses NEON instructions that this
interpreter does not implement, so it stops with `unsupported instruction ...`.

## Build

```bash
./taarch64/build.sh              # build with the stage-0 compiler
./taarch64/build.sh --selfhost   # build with Build/tcomp (see Tools/selfhost.sh)
```

The host needs python3 and binutils. `aarch64-linux-gnu-gcc` and `qemu-aarch64`
are only needed to build and check guest programs.

## Run

```bash
./taarch64/taarch64 FILE.a64
```

Exactly one argument is accepted; guest arguments are not supported yet. The
guest's exit status is the process exit status.

## Machine model

| | |
|---|---|
| Guest memory | 16 MiB, flat, starting at `0x400000` |
| Registers | `x0`–`x30`, `sp`, `pc`, condition flags |
| SIMD registers | 32 × 128-bit, used only by `ldr q` / `str q` copies |
| Stack | top of guest memory, 1 MiB reserved below it |
| Heap | `brk`/anonymous `mmap` grow up from the end of the image |
| Syscalls | `x8` selects, `x0`–`x5` arguments, result in `x0` |

Guest pointers are real addresses: the loader copies each `PT_LOAD` segment to
`BASE + p_vaddr`, so no relocation or page table is involved. The startup stack
is zeroed (`sp = STACK_TOP - 64`), with no `argc`/`argv`/`envp`/auxiliary vector.

## Instruction coverage

The scalar integer A64 that `gcc -O2` emits for freestanding C, plus the
128-bit loads and stores it uses to copy small blocks:

* **branches** — `b`, `bl`, `b.cond`, `cbz`/`cbnz`, `tbz`/`tbnz`, `br`, `blr`, `ret`
* **immediates** — `adr`/`adrp`, add/subtract immediate, logical immediate,
  move-wide (`movz`/`movn`/`movk`), bitfield (`sbfm`/`bfm`/`ubfm`), `extr`
* **registers** — logical shifted, add/subtract shifted and extended, `csel`
  family, `ccmp`/`ccmn`, `udiv`/`sdiv`, register shifts and rotates, bit
  manipulation (`rbit`, `rev16`, `rev32`, `rev`, `clz`, `cls`), and the
  multiply-add family (`madd`/`msub`, long variants, `smulh`/`umulh`)
* **loads/stores** — byte/half/word/double with unsigned immediate, unscaled,
  pre/post-index and register offsets; sign-extending loads; literal loads;
  `ldp`/`stp`; and 128-bit `ldr q`/`str q`
* **system** — `nop` and other hints, `dsb`/`dmb`/`isb`, `svc`, and reads of
  `TPIDR_EL0`, `CNTVCT_EL0` and `CNTFRQ_EL0`

Anything else stops with the instruction word and program counter.

## Syscalls

Implemented: `close`, `read`, `write`, `lseek`, `exit`/`exit_group`, `brk`,
anonymous `mmap`, `munmap`/`mprotect`/`madvise` (as no-ops), `set_tid_address`,
`set_robust_list`, `clock_gettime`/`gettimeofday` (zeroed result), `getrandom`
(zeroed), `getpid`/`gettid` (1), `getuid`/`geteuid`/`getgid`/`getegid` (0).
`rseq` returns `-ENOSYS`. Any other number stops with a diagnostic naming it.
`close` also reports success without closing, and `lseek` reports success
without moving.

There is no `openat`, so a guest can only use descriptors it inherited.

## Checking a guest against qemu

`qemu-aarch64` is the reference oracle for new instruction coverage:

```bash
aarch64-linux-gnu-gcc -static -nostdlib -O2 -o hello.a64 hello.c
qemu-aarch64 hello.a64 > expected
./taarch64/taarch64 hello.a64 > actual
cmp expected actual

qemu-aarch64 hello.a64; echo $?      # compare exit statuses too
./taarch64/taarch64 hello.a64; echo $?
```

At the time of the optimizer fix, twelve freestanding programs (hello,
arithmetic and division, loops, arrays, strings/recursion, switch, `brk`
memory, bit operations, exit status, `mov`/`movk` bytes, and a 128-bit vector
copy) matched qemu byte for byte, including exit statuses. The compiler-side
regression they exposed is covered by [`Tests/diff_test.py`](../Tests/diff_test.py);
there is no committed `taarch64` test harness yet.

## Limitations

* Dynamic ELF, shared libraries, `PT_INTERP` and static-PIE are rejected.
* No threads, signals, `clone`, futex, TLS setup or file-backed `mmap`.
* No FP or general NEON/SIMD arithmetic; SIMD is storage for `ldr q`/`str q` only.
* No atomics/exclusive accesses, `openat`, sockets, `ioctl`, or `brk`/`mmap`
  behaviour beyond the list above.
* `clock_gettime`/`gettimeofday` return zeroed buffers, not host time.
* 16 MiB total guest memory; the image must fit and the heap cannot grow into
  the reserved stack region.
* Guest arguments, `argc` and the auxiliary vector are not set up.
* Linux x86-64 hosts only, because the host toolchain is tcomp.

## Layout

| File | Purpose |
|---|---|
| `src/taarch64.tl` | entry point, startup stack, `main` |
| `src/machine.tl` | guest registers, flat memory and byte/word accessors |
| `src/elf.tl` | `ET_EXEC` validation and `PT_LOAD` placement |
| `src/exec.tl` | A64 decoder, instruction groups and the run loop |
| `src/syscalls.tl` | Linux AArch64 syscall translation |
| `build.sh` | assemble/link wrapper for stage 0 or `Build/tcomp` |
