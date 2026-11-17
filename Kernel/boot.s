# Long-mode trampoline, linked into the kernel image at 1 MiB.
#
# The MBR copies the flat image to 1 MiB and jumps to _boot32 with flat
# protected-mode segments.  This file zeroes .bss, identity-maps the first
# gigabyte plus the top quarter (where QEMU's VBE framebuffer sits) with 2 MiB
# pages, turns on paging and long mode, and calls the tlang entry point with a
# real stack and interrupts off.

.section .boot, "ax"
.code32
.intel_syntax noprefix
.globl _boot32

_boot32:
  cli
  lgdt [boot_gdt_desc]        # this GDT, which has the 64-bit code segment
  mov ax, 0x10
  mov ds, ax
  mov es, ax
  mov fs, ax
  mov gs, ax
  mov ss, ax

  # .bss is not part of the flat image, so zero it before anything uses it.
  # The page tables live here too, which is why this happens before paging.
  mov edi, offset __bss_start
  mov ecx, offset __bss_end
  sub ecx, edi
  add ecx, 3
  shr ecx, 2
  xor eax, eax
  rep stosd

  # The MBR left the framebuffer base and pitch in a boot-info block at 0x1FF00.
  # Drawing uses them, so a block this kernel cannot draw with stops the boot
  # here with a message instead of painting over memory that is not the screen.
  mov eax, [0x1ff08]
  cmp eax, 0x4b4e4c54
  jne .Lbad_info
  mov eax, [0x1ff04]          # BytesPerScanLine
  cmp eax, 5120               # the desktop draws with 5120-byte rows
  jne .Lbad_pitch
  mov edx, [0x1ff00]          # PhysBasePtr
  cmp edx, 0xc0000000         # only the top gigabyte is mapped for it
  jb .Lbad_base
  mov [__k_screen_base], edx
  mov [__k_screen_pitch], eax
  mov [__k_fb_base], edx
  mov [__k_fb_pitch], eax

  # PML4[0] -> PDPT[0] -> PD: 512 entries of 2 MiB each cover the first GiB.
  mov dword ptr [pt_pml4], offset pt_pdpt + 3
  mov dword ptr [pt_pdpt], offset pt_pd + 3
  mov edi, offset pt_pd
  mov eax, 0x83               # present, writable, 2 MiB page
  xor ecx, ecx
.Lmap:
  mov [edi + ecx * 8], eax
  add eax, 0x200000
  inc ecx
  cmp ecx, 512
  jb .Lmap

  # PDPT[3] -> PD_hi: 1 GiB at 0xC0000000, which covers QEMU's VBE linear
  # framebuffer at 0xFD000000.  The address is below 512 GiB, so it rides on
  # PML4[0], the same entry as the first gigabyte.
  mov dword ptr [pt_pdpt + 24], offset pt_pd_hi + 3
  mov edi, offset pt_pd_hi
  mov eax, 0xc0000083         # present, writable, 2 MiB page
  xor ecx, ecx
.Lmap_hi:
  mov [edi + ecx * 8], eax
  add eax, 0x200000
  inc ecx
  cmp ecx, 512
  jb .Lmap_hi

  mov eax, offset pt_pml4
  mov cr3, eax
  mov eax, cr4
  or eax, 0x20                # PAE
  mov cr4, eax
  mov ecx, 0xc0000080         # EFER
  rdmsr
  or eax, 0x100               # LME
  wrmsr
  mov eax, cr0
  or eax, 0x80010001          # PG | WP | PE
  mov cr0, eax
  .byte 0xea                  # far jump into 64-bit code
  .long l64_entry
  .word 0x18

.code64
l64_entry:
  mov ax, 0x10
  mov ds, ax
  mov es, ax
  mov fs, ax
  mov gs, ax
  mov ss, ax
  lea rsp, [rip + __k_stack_top]
  call __k_console_init       # the VBE mode is already set by the MBR
  xor edi, edi                # no boot-info block yet; K3 fills it in
  call _start

  # _start halts on its own; this is only a safety net.
  cli
.Lhalt:
  hlt
  jmp .Lhalt

.section .boot, "ax"
.align 8
boot_gdt:
  .quad 0
  .quad 0x00cf9a000000ffff    # 0x08: 32-bit code, flat
  .quad 0x00cf92000000ffff    # 0x10: data, flat
  .quad 0x00af9a000000ffff    # 0x18: 64-bit code, flat
boot_gdt_desc:
  .word boot_gdt_desc - boot_gdt - 1
  .quad boot_gdt

# Boot failures: a message on COM1 and a halt.  Reached only by jump from the
# boot-info check above.
.Lbad_info:
  mov esi, offset msg_info
  jmp .Lboot_fail
.Lbad_pitch:
  mov esi, offset msg_pitch
  jmp .Lboot_fail
.Lbad_base:
  mov esi, offset msg_base
.Lboot_fail:
  mov dx, 0x3f8
.Lboot_fail_put:
  lodsb
  test al, al
  jz .Lboot_fail_halt
  out dx, al
  jmp .Lboot_fail_put
.Lboot_fail_halt:
  cli
.Lboot_fail_loop:
  hlt
  jmp .Lboot_fail_loop

msg_info:
  .asciz "tlang: no boot info from the MBR\n"
msg_pitch:
  .asciz "tlang: VBE row pitch is not 5120\n"
msg_base:
  .asciz "tlang: framebuffer below 0xC0000000, not mapped\n"

.section .bss
.align 4096
pt_pml4:
  .zero 4096
pt_pdpt:
  .zero 4096
pt_pd:
  .zero 4096
pt_pd_hi:
  .zero 4096
