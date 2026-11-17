# Kernel: a tlang operating system

**Status: K1 landed, plus the desktop and a filesystem.** `--freestanding` and the
machine builtins work in both compilers, `Kernel/build.sh` produces a bootable
`kernel.img`, QEMU boots it into long mode, and `Kernel/main.tl` is a
1280x1024x32 desktop with a window manager: six apps (terminal, editor, file
list, system panel, paint, viewer), focus and back-to-front order, draggable
windows with
band-only repaints, a taskbar and round app icons, a polled PS/2 keyboard and
mouse, and a persistent filesystem on the IDE slave disk. K2 (IDT, timer,
interrupt-driven input) is next. Everything below records the target, the
constraints measured against the toolchain, and the order of work.

## Target

A kernel written in tlang that boots on bare metal under QEMU, with no Linux
underneath: tcomp emits x86-64 machine code, a small boot stub puts the CPU in
long mode, and everything after that — memory, interrupts, processes, files — is
tlang.

The end state closes the loop with `taarch64/`: the kernel runs `taarch64` as a
user process, and `taarch64` runs a static musl AArch64 binary. At that point a
musl AArch64 program executes on a stack that contains no Linux and no C:
Python (stage 0) → tcomp → kernel → taarch64 → musl guest.

## What the toolchain gives us today

Measured on this machine, not assumed:

| Fact | Evidence |
|---|---|
| tcomp emits x86-64 ELF only; a hosted `_start` captures argv, calls `main` and exits with `mov eax,60; syscall` | `Bootstrap/isa.py` `compile_module`, `tcomp.tl` `emit_header` |
| Storing through a raw integer address already works, 8-byte granular | `let p = 0xb8000; p[0] = 0x1f48` → `mov [rax + rcx*8], rdx` |
| Builtins are one generated table → a plain `call` to a runtime symbol | `Bootstrap/builtin_spec.py`, `Tools/gen_builtins.py` |
| Runtime bodies are assembly strings, pruned by `resolve_used`, selected with `call`/`ret` | `Bootstrap/runtime.py`, `Runtime/runtime_gen.tl` |
| `alloc` is backed by Linux `brk`/`mmap` | `__t_alloc` in the runtime |
| No inline asm, no `extern fn`, no function pointers | both compilers |
| `--freestanding` selects the entry, drops argv and the exit syscall, and leaves the kernel runtime to the linker | `Bootstrap/isa.py`, `tcomp.tl` `emit_header` |
| QEMU 11.1.1 refuses an ELF64 image via `-kernel` | `Error loading uncompressed kernel without PVH ELF Note` |
| SeaBIOS boots a 512-byte MBR from `-drive if=ide`, and EDD reads (`int 13h AH=42h`) work there | `Tests/kernel_test.py` boots `Kernel/kernel.img` and reads its log |
| `grub-mkrescue` is installed but `xorriso` is not, so a GRUB ISO is not buildable here | `grub-mkrescue` aborts on the missing tool; `which` |
| OVMF (`/usr/share/edk2/x64`) is installed, but UEFI boots into a graphics mode, not VGA text | K1's console is `0xb8000` |
| Static guests (`-nostdlib`, `-static`) already run under `taarch64` | `taarch64/README.md` |

The two language items below are what turns that into something that can boot.
They are the whole of the compiler work for K1 and K2.

## How builtins work today

Worth stating once, because the additions reuse it rather than inventing a second
mechanism:

1. `Bootstrap/builtin_spec.py` lists `(name, id, arity, result kind, runtime
   symbol, argument kinds, stage-0-visible)`.
2. `Tools/gen_builtins.py` emits that into `Bootstrap/builtins_gen.py` and
   `Runtime/builtins_gen.tl`, so both compilers share one name→ID map.
3. A call lowers to `call __t_<symbol>`; the body comes from `Bootstrap/runtime.py`
   (hand-written assembly) and `resolve_used` pulls in only what is referenced.
4. `Tests/builtins_test.py` enforces that the generated tables match the source
   and that every symbol exists. `Tools/selfhost.py` refuses stale generated
   files.

## L1 — `--freestanding` build mode

**Goal:** compile a program that expects to be entered by our stub rather than by
the Linux loader.

CLI (both compilers, same flags):

```
tcomp build --freestanding [--entry NAME] [-T SCRIPT] FILE
```

`--entry` defaults to `main`; `tcomp run` rejects `--freestanding` with a named
error, since there is nothing to exec into. The arena is the kernel runtime's
business, not a compiler option.

Codegen, in `compile_module` (stage 0) and `emit_header` (tcomp, which used to
emit the argv capture unconditionally):

- no `mov rax, [rsp]` argv capture and no `__t_argc_val`/`__t_argv_val` writes;
- `call .Lfn___init`, then `call .Lfn_<entry>`;
- **no exit syscall**: fall through to `.Lk_halt: hlt; jmp .Lk_halt`;
- no 64 MiB arena, no `.data` diagnostics and no `.bss`: the kernel runtime owns
  that state, so the image is program code plus program data only;
- global slots stay RIP-relative, so the image runs at any load address;
- `Bootstrap/driver.py::build` takes the link mode (`-e`, `-T`, and no `-s`) and
  keeps the symbol table for a kernel.

Runtime selection, `resolve_used(used, freestanding)`:

- the hosted bodies stay exactly as they are;
- in freestanding mode the kernel-provided entries (`print`, `print_err`,
  `print_char`, `print_int`, `alloc`, `exit`, `bounds_fail`) and every `__k_*`
  symbol are left out of the emitted assembly and left to the linker;
- `Kernel/kruntime.s` defines them: VGA text output, a bump allocator over a
  1 MiB `.bss` arena, the diagnostics, a halt loop and the `__k_*` stubs;
- so the compiler holds no second copy of the kernel runtime and the generators
  are untouched — the earlier plan's `Bootstrap/kruntime.py` would have been a
  third copy of the same assembly;
- `print` writes to VGA text in K1 and to COM1 from K2, so `print` keeps working
  on bare metal — the kernel is written in the same tlang a normal program is.

Link: `Kernel/kernel.ld` (load at 1 MiB, `ENTRY(_start)`), and `Kernel/build.sh`
produces `kernel.elf` (the linked image), `kernel.bin` (flat bytes) and
`kernel.img` (MBR plus the flat image, 98,816 B). Measured now: 78,112 B ELF
and 69,392 B flat, with the 1 MiB arena, the page tables, the 64 KiB stack, the
filesystem buffers and one screen of back buffer in `.bss` costing no file
bytes.

**Stub ↔ kernel ABI**, fixed for K1 and versioned in the doc:

| Item | Contract |
|---|---|
| Entry | `_start`, called with `rsp` 16-byte aligned, interrupts off |
| `rdi` | 0 for now; K3 passes the address of a boot-info block at `0x9000` |
| Boot info | `u64 magic`, `u64 e820_count`, then 24-byte E820 entries |
| `.bss` | the stub zeroes the image's `.bss` before calling `_start` |
| paging | identity-mapped RAM, `WP` on; higher-half comes with K3 |

**Acceptance, met:** `Tests/freestanding_test.py` checks the assembly (no
`syscall`, no argv capture, halt tail, no hosted arena), links an image through
`Kernel/kernel.ld`, and checks that both refusals name `--freestanding`;
`print("x")` without the flag still behaves as today (all 32 golden cases are
unchanged).

## L2 — machine builtins

Kernel-only builtins, added to the same `BUILTIN_SPECS` table. Rather than a new
field on all 59 rows, `builtin_spec.py` carries two sets, `HOSTED_ONLY` and
`KERNEL_ONLY`; the generator emits them as `BUILTIN_MODES` (stage 0) and as
`builtin_hosted`/`builtin_kernel`/`builtin_arity` (tcomp). `--freestanding` is
what enables them: a kernel builtin in a hosted build is an error naming the
flag, and a hosted-only builtin in a kernel build is the mirror error. All 23
take integer addresses/values and return an integer, so tcomp handles them in
one generated-arity path instead of 23 hand-written branches.

| Builtin | Emission | Purpose |
|---|---|---|
| `peek8/16/32/64(addr)` | `movzx eax, byte/word/dword/qword ptr [rdi]` | read physical memory, byte-granular |
| `poke8/16/32/64(addr, v)` | `mov byte/word/dword/qword ptr [rdi], sil/si/esi/rsi` | write physical memory, byte-granular |
| `outb(port, v)`, `inb(port)` | `mov edx, edi; mov eax, esi; out dx, al` / `in al, dx` | COM1, PIC, PIT, ATA |
| `io_wait()` | `out 0x80, al` | settle slow ISA devices |
| `hlt()`, `cli()`, `sti()` | the instruction | idle, critical sections |
| `lgdt(addr)`, `lidt(addr)`, `ltr(sel)` | `lgdt/lidt [rdi]`, `ltr ax` | descriptor tables, TSS |
| `invlpg(addr)` | `invlpg [rdi]` | paging flushes |
| `read_cr2()`, `read_cr3()`, `write_cr3(v)` | `mov rax/rdi, cr2/cr3` | page-fault address, address space switch |
| `rdtsc()` | `rdtsc; shl rdx, 32; or rax, rdx` | timing |
| `iretq(frame)` | `mov rsp, rdi; iretq` | return to ring 3 |

Notes on the shape:

- **No `ptr8`.** `poke8(base + i, v)` gives byte addressing with ordinary integer
  arithmetic, so no new pointer kind, no index-scale rule, and no change to
  `p[i]` on `alloc` pointers. The kernel needs byte stores, not byte pointers.
- **`iretq` takes the frame address** because a `call` would push a return
  address the instruction cannot consume.
- **No fault recovery.** A bad address triple-faults; that is the same "runs
  correctly or dies loudly" contract the rest of the project keeps.
- **Rejected: inline-asm builtins.** Emitting the instruction at the call site
  would save one `call`/`ret`, measured against an `out` instruction's I/O
  latency. Not worth a second codegen mechanism; revisit only if a hot path
  later proves it.

Steps, as built:

1. `builtin_spec.py`: append the 23 rows (IDs 37–59, symbol `__k_<name>`) and
   the two mode sets.
2. `Tools/gen_builtins.py`: emit `BUILTIN_MODES` and the three name predicates.
3. `Bootstrap/lower.py`: mode check in the builtin call path.
4. `tcomp.tl::parse_builtin`: the same check, plus `parse_machine`, one path for
   every machine builtin.
5. `Kernel/kruntime.s`: the stubs, global so a separate object can define them.
6. `Tests/builtins_test.py` and `Tests/runtime_test.py`: modes match the source,
   kernel symbols are `__k_*`, and the freestanding resolver emits nothing.
7. `Tests/machine_builtins_test.py`: compiles every machine builtin, links the
   result with the kernel runtime, and checks `_start`.

**Acceptance, met:** all 23 compile in kernel mode, host mode refuses them by
name, `Kernel/main.tl` (print, alloc, len, print_char) links into
`Kernel/kernel.elf`, and the self-hosting fixed point still holds at 122,279 B.

## L3 — deferred language work

Function pointers and inline asm. K1–K4 are writable without them (dispatch by
`if` chains, all I/O through L2 builtins). Function pointers become worth adding
when the driver and syscall tables want real dispatch; inline asm never, if L2
stays sufficient.

Ordering: L1 then L2, each landing in both compilers with tests green before the
next starts. Rough diff: ~120 lines across the two compilers, ~150 lines of
kernel runtime stubs, ~80 lines of generator and test changes. The hosted path
changes only by the new `mode` field.

## Kernel milestones

Each milestone ends with something observable in QEMU and a headless check, so
progress never depends on someone watching a window.

**K1 — boots and prints. Done.** `Kernel/mbr.s` is the 512-byte boot sector:
fast A20, EDD reads of 192 sectors to `0x7e00`, flat protected mode, then a copy
to 1 MiB. `Kernel/boot.s` is linked into the image at 1 MiB and does the rest:
zero `.bss`, identity-map the first GiB with 2 MiB pages, enable PAE/LME/PG and
far-jump to 64-bit code, which loads `__k_stack_top` and calls `_start` from
`Kernel/main.tl`. Output goes to VGA text and COM1 in parallel, and
`Tests/kernel_test.py` boots the image, reads the serial log and ends the run
through port `0xf4`. *Passes when* the log shows `tlang kernel`, `arena: 4
cells` and `A` — it does. Size as built: ~230 lines of asm.

**K1.5 — the shell.** `Kernel/main.tl` runs a prompt over the polled keyboard:
scancode set 1 to ASCII with Shift, a 255-byte line buffer, Backspace erasing
both the buffer and the screen, and six commands. Polling means no IDT and no
PIC yet: the loop reads port `0x64` bit 0 and port `0x60`. The clear screen and
backspace are handled in `__k_putc` (form feed and `0x08`), so the runtime owns
the screen and the serial mirror. `Tests/kernel_test.py` types a typo plus
Backspace, `echo hello kernel`, a bad command and `halt` through QEMU's monitor
and checks the serial log, so the shell is exercised without a window.

**K1.6 — the desktop.** The MBR switches to VBE mode 0x145 (1280x1024, 32 bits
per pixel) before protected mode; the linear framebuffer at 0xFD000000 is
mapped by `Kernel/boot.s` along with the first gigabyte, and `__k_putc` draws
glyphs from `Kernel/font8.s` (generated from a console font by
`Tools/make_font.py`) at 2x into a 32x17 grid while still mirroring every byte
to COM1. `Kernel/main.tl` draws everything else: a gradient wallpaper, round
app icons, a taskbar with one button per app, and two draggable windows with
gradient title bars, round close buttons and drop shadows. Shapes go through
`span8`, which blends the two boundary pixels of a row, so circles and rounded
corners are antialiased in true colour. The terminal window owns the runtime's
console grid (`console_place` moves it, `console_hide` parks it); the system
panel is drawn entirely by tlang. The PS/2 mouse is polled on the auxiliary
port -- 3-byte packets, sign bits, a saved backdrop under the pointer, click
edges -- and `Tests/kernel_test.py` walks the relative pointer to the close
button and the launcher, types commands and checks the COM1 log.

**K1.7 — apps and a filesystem. Done.** The desktop became a window manager:
a table of six windows in parallel arrays, back-to-front order, focus follows
the window that was clicked, and one window per app kind. Four apps: the
terminal (the runtime's console grid, placed in the frame), an editor over a
text buffer (arrows, backspace, Enter, Ctrl+S, whole-line scrolling), a file
list whose entries open the editor, and the system panel. Shapes still go
through `span8`, and a drag still repaints one band.

Storage is TLFS on the IDE slave, reached through two new machine builtins,
`ata_read` and `ata_write` (PIO, drive 1, ports `0x1f0`-`0x1f7`): sector 0 is a
superblock, sector 1 a directory of 16 entries of 32 bytes (20-byte name, 4-byte
size), and entry `i` owns 16 sectors from LBA `2 + i*16`, so a file is at most
8 KiB and a save is two writes. `fb_char` was added beside them so text held in
a buffer can be drawn, which is what the editor and the file list need.
The kernel image is on the master disk and is never written.

Artwork is drawn, not shipped. `main.tl` keeps a 96x64 canvas of palette indices
whose first 64 bytes are the 16 colours, so the buffer is exactly the file TLFS
stores: `Ctrl+S` saves it as `art` (`fs_save` selector 2) and the viewer reads it
back into its own buffer (`fs_load` selector 3) and blits it with `fb_indexed`.
That builtin draws whole-pixel blocks and tests the clip per destination pixel,
so a zoom is exact and a band repaint cannot paint outside the window. Nothing
about a picture is compiled in, so `kernel.bin` is 16 KB smaller than it was
with a portrait baked into the image.

Size as built: 78,112 B ELF, 69,392 B flat, 98,816 B image in a 192-sector
(96 KiB) load window; the MBR bumps the EDD segment past 64 KiB, since its
buffer offset is a 16-bit field. That window ends at `0x1FE00`, which is where
the MBR asks the VBE BIOS to describe the mode and stores base and pitch in a
boot-info block at `0x1FF00`; both must stay outside the image, since the copy
to 1 MiB would otherwise plant BIOS data in `.text`. `Kernel/boot.s` refuses to
boot on a block it cannot draw with, and `Kernel/build.sh` reads
`IMAGE_SECTORS` from `mbr.s` and fails if the image would reach either block.
`Tests/kernel_test.py` drives the mouse and the keyboard, writes a file, edits
it with Ctrl+S, halts, boots again over the same disk image and reads the
edited file back.

Drawing above the runtime follows one rule: every visible change adds its
rectangle to a damage union (`damage`) and the loop copies the union out once
per frame (`frame`). `fb_clip` narrows the runtime's fills and glyphs to the
band a drag
touched, and `console_dirty` reports the cells the runtime painted, so the
window manager presents them through the z-order instead of letting terminal
text land on a window above it. TLFS writes data before the directory entry,
clamps a size read back from the directory to 8 KiB, and reports a failed disk
instead of formatting over it.

**K2 — serial console.** The kernel `print` moves to COM1 at `0x3f8`, so output
goes to `-serial stdio` and the boot log becomes a file a test can grep. GDT/IDT,
PIC remap, timer tick, keyboard scancodes via `inb`. *Passes when* the serial log
prints and a timer counter increments without triple-faulting. Size: ~400 lines.

**K3 — memory.** E820 map from the boot-info block, a physical page allocator,
paging with `WP` and `NX`, and a kernel heap replacing the bump arena. *Passes
when* a self-test allocates and frees thousands of pages, scribbles a pattern
through each, and reconciles with the E820 map. Size: ~700 lines.

**K4 — user mode.** Per-process address spaces, TSS for the ring-0 stack,
`int 0x80` entry, `write`/`exit`/`brk`/`mmap` for user programs, cooperative then
preemptive scheduling. *Passes when* two tlang user programs interleave and both
exit with the expected status. Size: ~1200 lines.

**K5 — storage and programs.** ATA PIO (or virtio-blk over MMIO), a small
read-only filesystem, an ELF loader, and `exec`. *Passes when* a program is
loaded from the disk image and run by name from a shell. Size: ~800 lines.

**K6 — the payoff.** Port `taarch64` into the kernel: it already has a syscall
layer, so the kernel implements those numbers and `taarch64` runs as a user
process. *Passes when* the musl AArch64 hello world prints inside the tlang OS,
with `qemu-aarch64` still agreeing on the same binary. Size: reuse plus ~400
lines of glue.

## Decisions, and the recommendation

| Question | Recommendation | Why |
|---|---|---|
| Which architecture? | x86-64 | tcomp has one backend. AArch64 bare metal would mean a new backend, or booting through `taarch64` as "firmware", which defeats the exercise |
| Which boot path? | our own 512-byte MBR plus a long-mode trampoline; no GRUB, no UEFI | QEMU refuses an ELF64 `-kernel`, `grub-mkrescue` needs `xorriso` (not installed), and UEFI boots into graphics mode, not VGA text. A raw MBR is ~120 lines of asm, boots in the default machine, and keeps the image a plain flat binary |
| New builtin mechanism or reuse? | reuse: kernel-runtime stubs behind a `mode` field | one table, one generator, one contract test, both compilers unchanged in structure |
| Monolithic or microkernel? | monolithic | one address space is simpler to debug; the emulator keeps the user/kernel boundary honest later |
| Where does the code live? | `Kernel/` next to `taarch64/` | same pattern: own `build.sh`, own README, no compiler changes smuggled in |
| How is it tested? | headless QEMU + serial log | `Tests/kernel_test.py` boots the image, greps the serial output, exits 77 "skipped" when `qemu-system-x86_64` is missing |

## Risks

- **The language is where the work is.** L1 and L2 are ~60% of K1 and K2. If that
  is not interesting, the honest alternative is to keep `taarch64` hosted on
  Linux and build the OS *services* (scheduler, fd table, VFS) as tlang programs
  first, then port them to bare metal once the kernel exists.
- **Interrupts are the sharp edge.** A bad IDT entry is a triple fault with no
  output. The serial console in K2 is what keeps that debuggable, so it lands
  before any interrupt work.
- **Scope explosion.** "Run musl binaries" is K6. A text-mode kernel with a shell
  and a filesystem is already a real OS and is K1–K5.
- **Two compilers.** Every builtin lands twice and must keep stage 2 and stage 3
  byte-identical, so L1 and L2 land as small, separately tested steps, with the
  generated tables refreshed and `Tools/selfhost.py` re-run each time.

## Not in scope for this plan

SMP, APIC/IOAPIC beyond the legacy PIC, networking, USB, graphics beyond the
VBE linear framebuffer, power management, and any hardware other than QEMU's
default devices.
