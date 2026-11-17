# First-stage boot loader: the 512-byte MBR.
#
# Assembled for 0x7c00 and written to sector 0 of Kernel/kernel.img.  SeaBIOS
# loads it, it reads the next IMAGE_SECTORS sectors (the flat kernel image) to
# 0x7e00, switches to flat protected mode, copies the image to 1 MiB and jumps
# to _boot32 there.  The trampoline that enters long mode lives in boot.s, so
# this file stays small enough for one sector.
#
# There is no filesystem and no second stage: the disk is the image.

.set IMAGE_SECTORS, 192         # 96 KiB, checked by Kernel/build.sh

.code16
.intel_syntax noprefix
.globl _mbr

_mbr:
  cli
  xor ax, ax
  mov ds, ax
  mov es, ax
  mov ss, ax
  mov sp, 0x7c00
  sti
  mov [boot_drive], dl        # BIOS passes the boot drive in DL

  # Fast A20 gate: bit 1 of port 0x92.  It goes on before the disk is read and
  # again afterwards, because a VGA BIOS mode switch is free to drop it.
  in al, 0x92
  or al, 2
  and al, 0xfe
  out 0x92, al

# Read sectors 1..IMAGE_SECTORS to 0x7e00 with EDD (int 13h AH=42h), which
  # needs no CHS geometry and works on disks and disks-on-key alike.
  mov ax, 0x07e0
  mov es, ax
  mov ah, 0x41
  mov bx, 0x55aa
  mov dl, [boot_drive]
  int 0x13
  jc .Lno_edd
  cmp bx, 0xaa55
  jne .Lno_edd

  mov byte ptr [left], IMAGE_SECTORS
.Lread:
  mov byte ptr [tries], 3
.Lread_try:
  mov si, offset dap
  mov dl, [boot_drive]
  mov ah, 0x42
  int 0x13
  jnc .Lread_ok
  mov [err_code], ah
  xor ax, ax                  # reset the disk and try again
  mov dl, [boot_drive]
  int 0x13
  dec byte ptr [tries]
  jnz .Lread_try
  jmp .Lfail
.Lread_ok:
  add word ptr [dap + 4], 512 # next buffer offset, LBA += 1
  jnc .Lno_wrap
  add word ptr [dap + 6], 0x1000   # past 64 KiB: move the segment on instead
.Lno_wrap:
  add byte ptr [dap + 8], 1
  adc byte ptr [dap + 9], 0
  dec byte ptr [left]
  jnz .Lread
  jmp .Lloaded

.Lno_edd:
  mov byte ptr [err_code], 0x41
  jmp .Lfail

.Lno_vbe:
  mov byte ptr [err_code], 0x4f
  mov si, offset vbe_msg
  jmp .Lfail_print

.Lloaded:

  # Ask for mode 0x145 (1280x1024, 32 bits per pixel) and read the block that
  # describes it, so the framebuffer base and row pitch come from the BIOS and
  # are not assumed to be QEMU's 0xFD000000/5120.  They go in a boot-info block
  # at 0x1FF00, just past the image; Kernel/boot.s refuses to boot on a mode it
  # cannot draw with rather than painting into the wrong memory.
  # The block must live past the image (0x7e00 .. 0x1fe00), so it is addressed
  # as es:0xfe00 with es = 0x1000.  Putting it at linear 0xfe00 instead would
  # let the BIOS write 256 bytes over the image, which the copy to 1 MiB then
  # carries into .text.
  mov ax, 0x1000
  mov es, ax
  mov di, 0xfe00              # linear 0x1fe00: mode-info block
  mov ax, 0x4f01
  mov cx, 0x0145
  int 0x10
  cmp ax, 0x004f
  jne .Lno_vbe
  # The VBE call may clobber segment registers; the reads below still use the
  # mode-info block at es:di, so restore both after checking the status.
  mov ax, 0x1000
  mov es, ax
  mov di, 0xfe00
  cmp byte ptr es:[di + 0x19], 32    # 32bpp: 5120-byte rows imply 1280x1024
  jne .Lno_vbe
  mov edi, 0x1ff00            # linear 0x1ff00: the boot-info block
  mov eax, es:[di - 0x100 + 0x28]    # PhysBasePtr
  mov [edi], eax
  movzx eax, word ptr es:[di - 0x100 + 0x10]   # BytesPerScanLine
  mov [edi + 4], eax
  mov eax, 0x4b4e4c54         # 'TLNK'
  mov [edi + 8], eax

  mov ax, 0x4f02
  mov bx, 0x4145              # 0x4000: use the linear framebuffer
  int 0x10
  cmp ax, 0x004f
  jne .Lno_vbe

  # A VGA BIOS mode switch is free to drop the A20 gate, and the copy to 1 MiB
  # needs it, so set it once more.
  in al, 0x92
  or al, 2
  and al, 0xfe
  out 0x92, al

  xor ax, ax                  # the BIOS may clobber the segment registers
  mov ds, ax
  mov es, ax

  # Protected mode, flat segments.
  lgdt [gdt_desc]
  mov eax, cr0
  or eax, 1
  mov cr0, eax
  .byte 0x66, 0xea            # far jump with a 32-bit offset
  .long pm_entry
  .word 0x08

.code32
pm_entry:
  mov ax, 0x10
  mov ds, ax
  mov es, ax
  mov fs, ax
  mov gs, ax
  mov ss, ax
  mov esi, 0x7e00
  mov edi, 0x100000
  mov ecx, IMAGE_SECTORS * 128
  rep movsd
  mov eax, 0x100000
  jmp eax

.code16
.Lfail:
  mov si, offset fail_msg
.Lfail_print:
  lodsb
  test al, al
  je .Lfail_code
  call putc_al
  jmp .Lfail_print
.Lfail_code:
  mov al, [err_code]
  call puthex_al
  mov al, ' '
  call putc_al
  mov al, 'd'
  call putc_al
  mov al, [boot_drive]
  call puthex_al
  mov al, 10
  call putc_al
.Lfail_hang:
  hlt
  jmp .Lfail_hang

putc_al:
  mov dx, 0x3f8
  out dx, al
  ret

puthex_al:
  push ax
  push bx
  mov bx, offset hexdigits
  mov ah, al
  shr al, 4
  xlat
  call putc_al
  mov al, ah
  and al, 0x0f
  xlat
  call putc_al
  pop bx
  pop ax
  ret

hexdigits:
  .ascii "0123456789abcdef"
fail_msg:
  .asciz "tlang: disk read failed, int13h code "
vbe_msg:
  .asciz "tlang: vbe failed, code "
boot_drive:
  .byte 0
tries:
  .byte 0
left:
  .byte 0
err_code:
  .byte 0

# EDD disk address packet; buffer offset advances one sector per read.
.align 4
dap:
  .byte 16, 0
  .word 1
  .word 0
  .word 0x07e0
  .quad 1

.align 8
gdt:
  .quad 0
  .quad 0x00cf9a000000ffff    # 0x08: 32-bit code, flat
  .quad 0x00cf92000000ffff    # 0x10: data, flat
gdt_desc:
  .word gdt_desc - gdt - 1
  .long gdt

.org 510
.word 0xaa55
