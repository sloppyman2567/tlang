# Kernel runtime for freestanding tlang programs.
#
# A --freestanding build emits only the program and calls into this file for
# everything the hosted runtime in Bootstrap/runtime.py does with syscalls:
# print, allocation, bounds/OOM diagnostics and exit.  It also holds the
# machine builtins (__k_*) that ordinary programs are refused.
#
# Target: x86-64, VBE mode 0x145 (1280x1024, 32 bits per pixel, linear
# framebuffer at 0xFD000000, 5120 bytes per row), a text console drawn from
# Kernel/font8.s at 2x, and a bump allocator over a static arena.

.intel_syntax noprefix
.text

# This file is linked as its own object, so every entry point a compiled
# program calls must be global.
.globl __t_print, __t_print_err, __t_print_char, __t_print_int
.globl __t_alloc, __t_exit, __t_bounds_fail
.globl __k_peek8, __k_peek16, __k_peek32, __k_peek64
.globl __k_poke8, __k_poke16, __k_poke32, __k_poke64
.globl __k_outb, __k_inb, __k_io_wait
.globl __k_hlt, __k_cli, __k_sti
.globl __k_lgdt, __k_lidt, __k_ltr, __k_invlpg
.globl __k_read_cr2, __k_read_cr3, __k_write_cr3, __k_rdtsc, __k_iretq
.globl __k_fb_fill, __k_fb_text, __k_fb_char, __k_fb_back, __k_fb_present
.globl __k_fb_indexed
.globl __k_fb_clip, __k_console_dirty
.globl __k_ata_read, __k_ata_write
.globl __k_console_init, __k_console_place, __k_console_hide
.globl __k_screen_base, __k_screen_pitch, __k_fb_base, __k_fb_pitch
.globl __k_stack_top

# ---------------------------------------------------------------- screen
# A pixel is one dword, 0x00RRGGBB.  The console is a 32x17 grid of 16x20
# cells; the font is the 8x8 bitmap in Kernel/font8.s drawn at 2x, so glyphs
# are 16 pixels tall.  The program draws the window chrome around the grid.
.set FB, 0xfd000000
.set PITCH, 5120
.set CELL_W, 16
.set CELL_H, 20
.set CON_COLS, 32
.set CON_ROWS, 17
.set SCREEN_W, 1280
.set SCREEN_H, 1024
.set CON_BG, 0x11141c
.set CON_FG, 0xeef2f8
.set DESKTOP, 0x080a10

# Fill a rectangle with one colour, clipped to the clip rectangle (the screen
# unless fb_clip narrowed it): the framebuffer is linear, so a rectangle that
# started outside it used to wrap into the next scanline and draw a line
# across the display.
#   rdi = x, rsi = y, rdx = width, rcx = height, r8 = 0x00RRGGBB
__k_fill_rect:
  test rdx, rdx
  jle .Lfr_done
  test rcx, rcx
  jle .Lfr_done
  mov r9, [rip + __k_clip_x1]
  lea rax, [rdi + rdx]
  cmp rax, r9
  jle .Lfr_xa
  mov rax, r9                 # right of the clip: drop the overflow
.Lfr_xa:
  mov r10, [rip + __k_clip_x0]
  cmp rdi, r10
  jge .Lfr_xb
  mov rdi, r10                # left of the clip: drop the overhang
.Lfr_xb:
  mov rdx, rax
  sub rdx, rdi
  jle .Lfr_done
  mov r9, [rip + __k_clip_y1]
  lea rax, [rsi + rcx]
  cmp rax, r9
  jle .Lfr_ya
  mov rax, r9
.Lfr_ya:
  mov r10, [rip + __k_clip_y0]
  cmp rsi, r10
  jge .Lfr_yb
  mov rsi, r10
.Lfr_yb:
  mov rcx, rax
  sub rcx, rsi
  jle .Lfr_done
  mov rax, rsi
  imul rax, [rip + __k_fb_pitch]
  shl rdi, 2
  add rax, rdi
  add rax, [rip + __k_fb_base]
  mov r10, rax                # current row
  mov r9, rdx                 # width in pixels
  mov r11, rcx                # rows left
.Lfr_row:
  mov rdi, r10
  mov ecx, r9d
  mov eax, r8d
  rep stosd
  add r10, [rip + __k_fb_pitch]
  dec r11
  jnz .Lfr_row
.Lfr_done:
  ret

# Draw one 8x8 glyph at 2x, transparent where the bits are clear.  The base and
# pitch come from the globals so the same code draws into the back buffer.
# Glyphs are clipped pixel by pixel.  A band repaint cuts through cells, and a
# glyph drawn without the clip puts part of a word outside the window being
# repainted, where it stays in the back buffer and reappears on the next one.
#   rdi = x, rsi = y, edx = colour, ecx = ASCII code
__k_glyph:
  push rbx
  push rbp
  push r12
  push r13
  push r14
  push r15
  mov r13, rdi                # x, for the clip test
  mov rbp, rsi                # y, for the clip test
  mov r15d, edx               # colour
  mov eax, ecx
  sub eax, 32
  js .Lg_blank
  cmp eax, 94
  jbe .Lg_have
.Lg_blank:
  xor eax, eax                # anything unprintable is a space
.Lg_have:
  shl rax, 3
  lea rbx, [rip + __k_font]
  add rbx, rax                # rbx -> 8 scanlines of this glyph
  mov r12, [rip + __k_fb_pitch]
  mov rax, rsi
  imul rax, r12
  shl rdi, 2
  add rax, rdi
  add rax, [rip + __k_fb_base]  # rax -> first screen row of the glyph
  xor r14d, r14d              # scanline
.Lg_row:
  movzx r10d, byte ptr [rbx + r14]
  xor r11d, r11d              # column
.Lg_bit:
  test r10b, 0x80
  jz .Lg_skip
  # The block is two pixels wide and two tall; both must be inside the clip.
  mov rcx, r11
  shl rcx, 1
  add rcx, r13                # destination x
  cmp rcx, [rip + __k_clip_x0]
  jb .Lg_skip
  add rcx, 2
  cmp rcx, [rip + __k_clip_x1]
  ja .Lg_skip
  mov rdx, r14
  shl rdx, 1
  add rdx, rbp                # destination y
  cmp rdx, [rip + __k_clip_y0]
  jb .Lg_skip
  add rdx, 2
  cmp rdx, [rip + __k_clip_y1]
  ja .Lg_skip
  mov rdi, r14
  shl rdi, 1                  # two screen rows per scanline
  imul rdi, r12
  mov rsi, r11
  shl rsi, 3                  # column * 8 bytes: two pixels
  add rdi, rsi
  lea rsi, [rax + rdi]
  mov [rsi], r15d
  mov [rsi + 4], r15d
  add rsi, r12
  mov [rsi], r15d
  mov [rsi + 4], r15d
.Lg_skip:
  shl r10b, 1
  inc r11d
  cmp r11d, 8
  jb .Lg_bit
  inc r14d
  cmp r14d, 8
  jb .Lg_row
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbp
  pop rbx
  ret

# Record how far the console has repainted since the last console_dirty()
# call, in cell coordinates so a moved console keeps the report valid.
#   r13 = row, rbx = column
con_damage:
  cmp qword ptr [rip + __k_con_dmg], 0
  jne .Ldmg_union
  mov qword ptr [rip + __k_con_dmg], 1
  mov [rip + __k_con_dx0], rbx
  mov [rip + __k_con_dy0], r13
  lea rax, [rbx + 1]
  mov [rip + __k_con_dx1], rax
  lea rax, [r13 + 1]
  mov [rip + __k_con_dy1], rax
  ret
.Ldmg_union:
  cmp rbx, [rip + __k_con_dx0]
  jge .Ldmg_ux1
  mov [rip + __k_con_dx0], rbx
.Ldmg_ux1:
  cmp r13, [rip + __k_con_dy0]
  jge .Ldmg_uy1
  mov [rip + __k_con_dy0], r13
.Ldmg_uy1:
  lea rax, [rbx + 1]
  cmp rax, [rip + __k_con_dx1]
  jle .Ldmg_ux2
  mov [rip + __k_con_dx1], rax
.Ldmg_ux2:
  lea rax, [r13 + 1]
  cmp rax, [rip + __k_con_dy1]
  jle .Ldmg_uy2
  mov [rip + __k_con_dy1], rax
.Ldmg_uy2:
  ret

# Repaint one console cell from __k_text, and draw the cursor underline if
# this is the cell the cursor is on.  Repainting is also how an old underline
# is erased when the cursor moves.  A cell outside the clip rectangle is
# skipped entirely, which is what makes a band repaint cost only the band.
#   rdi = cell index (0 .. CON_COLS*CON_ROWS-1)
__k_paint_cell:
  push rbx
  push r12
  push r13
  cmp qword ptr [rip + __k_con_visible], 0
  je .Lpc_done
  mov r12, rdi                # cell index
  mov rax, rdi
  xor edx, edx
  mov ecx, CON_COLS
  div rcx                     # rax = row, rdx = column
  mov r13, rax                # row
  mov rbx, rdx                # column
  call con_damage
  mov rdi, rbx
  shl rdi, 4
  add rdi, [rip + __k_con_x]  # cell x
  mov rsi, r13
  imul rsi, rsi, CELL_H
  add rsi, [rip + __k_con_y]  # cell y
  mov rax, rdi
  add rax, CELL_W
  cmp rax, [rip + __k_clip_x0]
  jle .Lpc_done
  cmp rdi, [rip + __k_clip_x1]
  jge .Lpc_done
  mov rax, rsi
  add rax, CELL_H
  cmp rax, [rip + __k_clip_y0]
  jle .Lpc_done
  cmp rsi, [rip + __k_clip_y1]
  jge .Lpc_done
  push rdi
  push rsi
  mov rdx, CELL_W
  mov rcx, CELL_H
  mov r8d, CON_BG
  call __k_fill_rect
  pop rsi
  pop rdi
  lea rax, [rip + __k_text]
  movzx ecx, byte ptr [rax + r12]
  mov edx, CON_FG
  call __k_glyph
  mov rax, [rip + __k_cursor]
  cmp rax, r12
  jne .Lpc_done
  mov rdi, rbx
  shl rdi, 4
  add rdi, [rip + __k_con_x]
  add rdi, 2
  mov rsi, r13
  imul rsi, rsi, CELL_H
  add rsi, [rip + __k_con_y]
  add rsi, 16                 # underline just under the glyph
  mov rdx, 10
  mov rcx, 3
  mov r8d, CON_FG
  call __k_fill_rect
.Lpc_done:
  pop r13
  pop r12
  pop rbx
  ret

# Move the text up one row and repaint the window.
__k_scroll:
  lea rdi, [rip + __k_text]
  lea rsi, [rip + __k_text + CON_COLS]
  mov ecx, CON_COLS * (CON_ROWS - 1)
  rep movsb
  lea rdi, [rip + __k_text + CON_COLS * (CON_ROWS - 1)]
  mov ecx, CON_COLS
  mov al, 32
  rep stosb
  sub qword ptr [rip + __k_cursor], CON_COLS
  xor ebx, ebx
.Lscroll_paint:
  mov rdi, rbx
  call __k_paint_cell
  inc rbx
  cmp rbx, CON_COLS * CON_ROWS
  jb .Lscroll_paint
  ret

# __k_cursor is a linear cell index into the 32x17 text buffer.  Every byte
# also goes to COM1 so a headless run can read the console log.
__k_putc:
  push rbx
  mov ebx, edi
  call __k_console_init
  cmp bl, 12
  je .Lk_putc_clear
  cmp bl, 8
  je .Lk_putc_bksp
  cmp bl, 10
  jne .Lk_putc_serial
  mov edi, 13                 # CR before LF on a serial terminal
  call __k_serial_putc
.Lk_putc_serial:
  mov edi, ebx
  call __k_serial_putc
  cmp bl, 10
  je .Lk_putc_nl
  cmp bl, 13
  je .Lk_putc_done
  mov rax, [rip + __k_cursor]
  lea rdx, [rip + __k_text]
  mov ecx, ebx
  mov byte ptr [rdx + rax], cl
  mov rdi, rax
  call __k_paint_cell
  mov rdi, [rip + __k_cursor]
  inc rdi
  mov [rip + __k_cursor], rdi
  call __k_paint_cell         # underline at the new position
  mov rdi, [rip + __k_cursor]
  dec rdi
  call __k_paint_cell         # clear the underline left behind
  mov rax, [rip + __k_cursor]
  xor edx, edx
  mov ecx, CON_COLS
  div rcx
  test rdx, rdx
  jne .Lk_putc_done
  cmp rax, CON_ROWS
  jb .Lk_putc_done
  call __k_scroll
  jmp .Lk_putc_done
.Lk_putc_nl:
  mov rdi, [rip + __k_cursor]
  mov rax, rdi
  xor edx, edx
  mov ecx, CON_COLS
  div rcx
  inc rax
  imul rax, rax, CON_COLS
  mov [rip + __k_cursor], rax
  call __k_paint_cell         # erases the underline on the old row
  mov rdi, [rip + __k_cursor]
  cmp rdi, CON_ROWS * CON_COLS
  jb .Lk_putc_nl_paint
  call __k_scroll
  jmp .Lk_putc_done
.Lk_putc_nl_paint:
  call __k_paint_cell
  jmp .Lk_putc_done
.Lk_putc_done:
  pop rbx
  ret

# Form feed: blank the window and go home, as a shell's clear does.
.Lk_putc_clear:
  lea rdi, [rip + __k_text]
  mov ecx, CON_COLS * CON_ROWS
  mov al, 32
  rep stosb
  mov qword ptr [rip + __k_cursor], 0
  cmp qword ptr [rip + __k_con_visible], 0
  je .Lk_putc_clear_done
  mov rdi, [rip + __k_con_x]
  mov rsi, [rip + __k_con_y]
  mov edx, CON_COLS * CELL_W
  mov ecx, CON_ROWS * CELL_H
  mov r8d, CON_BG
  call __k_fill_rect
  xor edi, edi
  call __k_paint_cell
.Lk_putc_clear_done:
  pop rbx
  ret

# Backspace: step back, blank the cell, and erase it on the serial log too.
.Lk_putc_bksp:
  mov rdi, [rip + __k_cursor]
  test rdi, rdi
  je .Lk_putc_done
  lea rax, [rip + __k_text]
  mov byte ptr [rax + rdi], 32
  dec rdi
  mov [rip + __k_cursor], rdi
  call __k_paint_cell
  mov rdi, [rip + __k_cursor]
  inc rdi
  call __k_paint_cell
  mov edi, 8
  call __k_serial_putc
  mov edi, 32
  call __k_serial_putc
  mov edi, 8
  call __k_serial_putc
  jmp .Lk_putc_done

# Place the console text grid at a pixel origin and repaint it.  The window
# manager draws the frame, title bar and close box around it, so this only
# moves text.
__k_console_place:
  mov [rip + __k_con_x], rdi
  mov [rip + __k_con_y], rsi
  mov qword ptr [rip + __k_con_visible], 1
  push rbx
  xor ebx, ebx
.Lplace_loop:
  mov rdi, rbx
  call __k_paint_cell
  inc rbx
  cmp rbx, CON_COLS * CON_ROWS
  jb .Lplace_loop
  pop rbx
  # The caller repaints the window it lives in, so the cells just drawn are
  # accounted for.
  mov qword ptr [rip + __k_con_dmg], 0
  xor eax, eax
  ret

__k_console_hide:
  mov qword ptr [rip + __k_con_visible], 0
  mov qword ptr [rip + __k_con_dmg], 0
  xor eax, eax
  ret

# The first byte of output owns the screen: blank the framebuffer and bring up
# COM1.  Kernel/boot.s calls this before _start, so the program can paint the
# desktop and window chrome first.
__k_console_init:
  cmp byte ptr [rip + __k_console_ready], 0
  jne .Lcon_done
  mov byte ptr [rip + __k_console_ready], 1
  # Drawing goes to the screen until fb_back() switches it to the back buffer.
  # Both start wherever the VBE mode info said the framebuffer is.
  mov rax, [rip + __k_screen_base]
  mov [rip + __k_fb_base], rax
  mov rax, [rip + __k_screen_pitch]
  mov [rip + __k_fb_pitch], rax
  xor edi, edi
  xor esi, esi
  mov edx, 1280
  mov ecx, 1024
  mov r8d, DESKTOP
  call __k_fill_rect
  lea rdi, [rip + __k_text]
  mov ecx, CON_COLS * CON_ROWS
  mov al, 32
  rep stosb
  mov qword ptr [rip + __k_cursor], 0
  mov rdi, [rip + __k_con_x]
  mov rsi, [rip + __k_con_y]
  mov edx, CON_COLS * CELL_W
  mov ecx, CON_ROWS * CELL_H
  mov r8d, CON_BG
  call __k_fill_rect
  xor edi, edi
  call __k_paint_cell
  jmp __k_serial_init
.Lcon_done:
  ret

# COM1 at 115200 8N1.  A missing UART costs output, never a hang.
__k_serial_init:
  cmp byte ptr [rip + __k_serial_ready], 0
  jne .Lser_ready
  mov dx, 0x3f9
  xor al, al
  out dx, al
  mov dx, 0x3fb
  mov al, 0x80
  out dx, al
  mov dx, 0x3f8
  mov al, 1
  out dx, al
  mov dx, 0x3f9
  xor al, al
  out dx, al
  mov dx, 0x3fb
  mov al, 3
  out dx, al
  mov dx, 0x3fa
  mov al, 0xc7
  out dx, al
  mov dx, 0x3fc
  mov al, 3
  out dx, al
  mov byte ptr [rip + __k_serial_ready], 1
.Lser_ready:
  ret

# Bounded wait for the transmit register, then send the byte in edi.
__k_serial_putc:
  push rcx
  push rdx
  mov ecx, 100000
  mov rdx, 0x3fd
.Lser_wait:
  in al, dx
  test al, 0x20
  jne .Lser_send
  dec ecx
  jnz .Lser_wait
  jmp .Lser_done
.Lser_send:
  mov rdx, 0x3f8
  mov eax, edi
  out dx, al
.Lser_done:
  pop rdx
  pop rcx
  ret

# ---------------------------------------------------------------- drawing
# fb_fill(x, y, width, height, colour)
__k_fb_fill:
  jmp __k_fill_rect

# fb_text(x, y, colour, text): 16x16 glyphs, one byte per character.
__k_fb_text:
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov r12, rdi
  mov r13, rsi
  mov r15d, edx
  mov r14, rcx
.Lfbt_loop:
  movzx ecx, byte ptr [r14]
  test cl, cl
  je .Lfbt_done
  mov rdi, r12
  mov rsi, r13
  mov edx, r15d
  call __k_glyph
  add r12, CELL_W
  inc r14
  jmp .Lfbt_loop
.Lfbt_done:
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

# Blit palette-indexed pixels out of a buffer at a whole-pixel scale.  The
# buffer starts with 16 palette dwords, then one index byte per pixel, which is
# exactly what the paint app saves and the viewer loads, so a saved picture
# carries its palette and there is no decoder to get wrong.  The clip rectangle
# is tested per destination pixel, or a band repaint would put the picture
# outside the band and outside the window.
#   rdi = x, rsi = y, rdx = scale (clamped to 1..4)
#   rcx = buffer (palette, then pixels), r8 = width, r9 = height
__k_fb_indexed:
  push rbx
  push rbp
  push r12
  push r13
  push r14
  push r15
  sub rsp, 56
  mov rbx, rdi                # x0
  mov r12, rsi                # y0
  mov r13, rdx                # scale
  cmp r13, 1
  jge .Lfi_scale_lo
  mov r13, 1
.Lfi_scale_lo:
  cmp r13, 4
  jle .Lfi_scale_ok
  mov r13, 4
.Lfi_scale_ok:
  mov r14, rcx                # palette: 16 dwords
  mov rbp, r8                 # width
  mov [rsp + 32], r9          # height
  lea r15, [rcx + 64]         # pixel indices, after the palette
  mov qword ptr [rsp + 0], 0  # source row
.Lfi_row:
  mov rax, [rsp + 0]
  cmp rax, [rsp + 32]
  jae .Lfi_done
  imul rax, rbp
  add rax, r15
  mov [rsp + 8], rax          # row pointer
  mov rax, [rsp + 0]
  imul rax, r13
  add rax, r12
  mov [rsp + 40], rax         # destination y of this row
  mov qword ptr [rsp + 16], 0 # source column
.Lfi_col:
  mov rcx, [rsp + 16]
  cmp rcx, rbp
  jae .Lfi_next_row
  mov rdx, [rsp + 8]
  movzx edx, byte ptr [rdx + rcx]
  and edx, 15                 # the palette holds 16 entries
  mov edx, [r14 + rdx * 4]    # colour of this pixel
  mov rax, rcx
  imul rax, r13
  add rax, rbx
  mov [rsp + 48], rax         # destination x of this column
  mov r8, [rip + __k_clip_y0]
  mov r9, [rsp + 40]
  mov r10, r13
.Lfi_blk_row:
  test r10, r10
  jz .Lfi_next_col
  mov rax, r9
  cmp rax, r8
  jb .Lfi_blk_row_next
  cmp rax, [rip + __k_clip_y1]
  jae .Lfi_next_col            # this and every later row is below the clip
  imul rax, [rip + __k_fb_pitch]
  add rax, [rip + __k_fb_base]
  mov rdi, [rsp + 48]
  shl rdi, 2
  add rax, rdi
  mov r11, [rip + __k_clip_x0]
  mov rcx, [rsp + 48]
  mov rsi, r13
.Lfi_blk_col:
  test rsi, rsi
  jz .Lfi_blk_row_next
  cmp rcx, r11
  jb .Lfi_blk_col_next
  cmp rcx, [rip + __k_clip_x1]
  jae .Lfi_blk_row_next       # right of the clip: the rest of this row goes
  mov [rax], edx
  add rax, 4
.Lfi_blk_col_next:
  inc rcx
  dec rsi
  jmp .Lfi_blk_col
.Lfi_blk_row_next:
  inc r9
  dec r10
  jmp .Lfi_blk_row
.Lfi_next_col:
  inc qword ptr [rsp + 16]
  jmp .Lfi_col
.Lfi_next_row:
  inc qword ptr [rsp + 0]
  jmp .Lfi_row
.Lfi_done:
  add rsp, 56
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbp
  pop rbx
  xor eax, eax
  ret

# ---------------------------------------------------------------- print
__t_print:
  jmp __k_write

__t_print_err:
  jmp __k_write

__k_write:
  push rbx
  mov rbx, rdi
.Lk_write_loop:
  movzx edi, byte ptr [rbx]
  test dil, dil
  je .Lk_write_done
  call __k_putc
  inc rbx
  jmp .Lk_write_loop
.Lk_write_done:
  pop rbx
  ret

__t_print_char:
  jmp __k_putc

__t_print_int:
  push rbx
  sub rsp, 48
  mov rax, rdi
  lea rsi, [rsp + 47]
  mov byte ptr [rsi], 0
  xor r8d, r8d
  test rax, rax
  jns .Lk_pi_abs
  neg rax
  mov r8d, 1
.Lk_pi_abs:
  mov ebx, 10
.Lk_pi_loop:
  xor edx, edx
  div rbx
  add dl, 48
  dec rsi
  mov byte ptr [rsi], dl
  test rax, rax
  jne .Lk_pi_loop
  test r8d, r8d
  je .Lk_pi_write
  dec rsi
  mov byte ptr [rsi], 45
.Lk_pi_write:
  mov rdi, rsi
  call __k_write
  add rsp, 48
  pop rbx
  ret

# ---------------------------------------------------------------- allocator
# Bump allocation over __k_arena.  Blocks keep the hosted 16-byte header
# (capacity then length) so append(), len() and itoa() work unchanged.
__t_alloc:
  test rdi, rdi
  js .Lk_alloc_bad
  cmp rdi, 131070
  ja .Lk_alloc_oom
  mov rcx, [rip + __k_arena_pos]
  lea rax, [rip + __k_arena]
  add rax, rcx
  mov rdx, rdi
  shl rdx, 3
  add rdx, 16
  add rcx, rdx
  cmp rcx, 1048576
  ja .Lk_alloc_oom
  mov [rip + __k_arena_pos], rcx
  lea r8, [rax + 16]
  mov [r8 - 16], rdi
  mov [r8 - 8], rdi
  mov rdi, r8
  mov rcx, rdx
  sub rcx, 16
  xor eax, eax
  rep stosb
  mov rax, r8
  ret
.Lk_alloc_oom:
  lea rdi, [rip + __t_oom_msg]
  call __k_write
  jmp __k_halt
.Lk_alloc_bad:
  lea rdi, [rip + __t_bad_alloc_msg]
  call __k_write
  jmp __k_halt

# ---------------------------------------------------------------- stopping
__t_exit:
  jmp __k_halt

__k_halt:
  cli
.Lk_halt_loop:
  hlt
  jmp .Lk_halt_loop

__t_bounds_fail:
  lea rdi, [rip + __t_oob_msg]
  call __k_write
  jmp __k_halt

# ---------------------------------------------------------------- mem ops
# The hosted runtime generates these; a kernel build has no syscall runtime, so
# the two pure primitives live here.  memcpy/memset stay hosted-only for now.
__t_memmove:
  mov rax, rdi
  test rdx, rdx
  je .Lk_mm_done
  cmp rdi, rsi
  jbe .Lk_mm_forward
  mov rcx, rsi
  add rcx, rdx
  cmp rdi, rcx
  jae .Lk_mm_forward
  lea rsi, [rsi + rdx - 1]
  lea rdi, [rdi + rdx - 1]
  mov rcx, rdx
  std
  rep movsb
  cld
  ret
.Lk_mm_forward:
  mov rcx, rdx
  rep movsb
.Lk_mm_done:
  ret

__t_memcmp:
  xor eax, eax
  test rdx, rdx
  je .Lk_mc_done
.Lk_mc_loop:
  mov r8b, [rdi]
  mov r9b, [rsi]
  cmp r8b, r9b
  jne .Lk_mc_diff
  inc rdi
  inc rsi
  dec rdx
  jne .Lk_mc_loop
.Lk_mc_done:
  ret
.Lk_mc_diff:
  movzx eax, r8b
  movzx ecx, r9b
  sub rax, rcx
  ret

# ---------------------------------------------------------------- machine
# Every stub follows the call ABI: rdi, rsi, rdx, rcx, r8, r9 in, rax out.
__k_peek8:
  movzx eax, byte ptr [rdi]
  ret
__k_peek16:
  movzx eax, word ptr [rdi]
  ret
__k_peek32:
  mov eax, dword ptr [rdi]
  ret
__k_peek64:
  mov rax, [rdi]
  ret

__k_poke8:
  mov [rdi], sil
  xor eax, eax
  ret
__k_poke16:
  mov [rdi], si
  xor eax, eax
  ret
__k_poke32:
  mov [rdi], esi
  xor eax, eax
  ret
__k_poke64:
  mov [rdi], rsi
  xor eax, eax
  ret

__k_outb:
  mov rdx, rdi
  mov rax, rsi
  out dx, al
  xor eax, eax
  ret
__k_inb:
  mov rdx, rdi
  xor eax, eax
  in al, dx
  movzx eax, al
  ret
__k_io_wait:
  xor eax, eax
  out 0x80, al
  ret

__k_hlt:
  hlt
  xor eax, eax
  ret
__k_cli:
  cli
  xor eax, eax
  ret
__k_sti:
  sti
  xor eax, eax
  ret

__k_lgdt:
  lgdt [rdi]
  xor eax, eax
  ret
__k_lidt:
  lidt [rdi]
  xor eax, eax
  ret
__k_ltr:
  mov eax, edi
  ltr ax
  xor eax, eax
  ret
__k_invlpg:
  invlpg [rdi]
  xor eax, eax
  ret

__k_read_cr2:
  mov rax, cr2
  ret
__k_read_cr3:
  mov rax, cr3
  ret
__k_write_cr3:
  mov cr3, rdi
  xor eax, eax
  ret
__k_rdtsc:
  rdtsc
  shl rdx, 32
  or rax, rdx
  ret
# The interrupt frame lives at `frame`: switch stacks and return from it.
__k_iretq:
  mov rsp, rdi
  iretq

# ---------------------------------------------------------------- disk
# 512-byte sectors on the primary slave (drive 1), which holds the filesystem
# disk.  The kernel image is on the master and is never written, so a bug in a
# save can only damage data.
#   ata_read(lba, count, addr), ata_write(lba, count, addr)
__k_ata_read:
  mov r8d, 0x20               # READ SECTORS
  jmp ata_xfer

__k_ata_write:
  mov r8d, 0x30               # WRITE SECTORS
  jmp ata_xfer

ata_xfer:
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov r12, rdi                # current LBA
  mov r13, rsi                # sectors left
  mov r14, rdx                # memory
  test r13, r13
  jle .Lata_ok
.Lata_sector:
  mov rdx, 0x1f6              # drive 1 plus the top four LBA bits
  mov eax, r12d
  shr eax, 24
  and eax, 0x0f
  or eax, 0xf0
  out dx, al
  mov rdx, 0x1f7              # 400 ns settle: four reads of the status port
  in al, dx
  in al, dx
  in al, dx
  in al, dx
  call ata_ready
  jc .Lata_fail
  mov rdx, 0x1f2
  mov eax, 1
  out dx, al
  mov rdx, 0x1f3
  mov eax, r12d
  out dx, al
  mov rdx, 0x1f4
  mov eax, r12d
  shr eax, 8
  out dx, al
  mov rdx, 0x1f5
  mov eax, r12d
  shr eax, 16
  out dx, al
  mov rdx, 0x1f7
  mov eax, r8d
  out dx, al
  call ata_drq
  jc .Lata_fail
  mov rdx, 0x1f0
  mov rcx, 256
  cmp r8d, 0x20
  jne .Lata_out
  mov rdi, r14
  rep insw
  jmp .Lata_next
.Lata_out:
  mov rsi, r14
  rep outsw
.Lata_next:
  add r14, 512
  inc r12
  dec r13
  jnz .Lata_sector
  call ata_ready
  jc .Lata_fail
.Lata_ok:
  xor eax, eax
  jmp .Lata_done
.Lata_fail:
  mov rax, -1
.Lata_done:
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

# Wait for BSY to clear; carry set means the drive never answered.
ata_ready:
  push rcx
  push rdx
  mov rcx, 2000000
.Lrdy_loop:
  mov dx, 0x1f7
  in al, dx
  test al, 0x80
  jz .Lrdy_ok
  dec rcx
  jnz .Lrdy_loop
  stc
  jmp .Lrdy_done
.Lrdy_ok:
  test al, 1
  jnz .Lrdy_err
  clc
  jmp .Lrdy_done
.Lrdy_err:
  stc
.Lrdy_done:
  pop rdx
  pop rcx
  ret

# Wait for DRQ with the drive idle; carry set on error or timeout.
ata_drq:
  push rcx
  push rdx
  mov rcx, 2000000
.Ldrq_loop:
  mov dx, 0x1f7
  in al, dx
  test al, 0x80
  jnz .Ldrq_again
  test al, 8
  jnz .Ldrq_ok
  test al, 1
  jnz .Ldrq_err
.Ldrq_again:
  dec rcx
  jnz .Ldrq_loop
  stc
  jmp .Ldrq_done
.Ldrq_ok:
  clc
  jmp .Ldrq_done
.Ldrq_err:
  stc
.Ldrq_done:
  pop rdx
  pop rcx
  ret

# fb_char(x, y, colour, code): one glyph, for text that lives in a buffer.
__k_fb_char:
  jmp __k_glyph

# ---------------------------------------------------------------- compositing
# Drawing goes to a back buffer and is presented in one copy.  Painting the
# screen directly means the erase is visible between the wallpaper fill and the
# window redraws, which a remote viewer samples as "every window vanishes".
#   fb_back(): switch drawing to the back buffer, returning its address
__k_fb_back:
  lea rax, [rip + __k_back]
  mov [rip + __k_fb_base], rax
  mov qword ptr [rip + __k_fb_pitch], PITCH
  ret

#   fb_present(x0, y0, x1, y1): copy that rectangle of the back buffer out
__k_fb_present:
  push rbx
  push r12
  push r13
  push r14
  test rdi, rdi
  jns .Lfp_x0
  xor edi, edi
.Lfp_x0:
  test rsi, rsi
  jns .Lfp_y0
  xor esi, esi
.Lfp_y0:
  cmp rdx, SCREEN_W
  jle .Lfp_x1
  mov edx, SCREEN_W
.Lfp_x1:
  cmp rcx, SCREEN_H
  jle .Lfp_y1
  mov ecx, SCREEN_H
.Lfp_y1:
  cmp rdi, rdx
  jge .Lfp_done
  cmp rsi, rcx
  jge .Lfp_done
  mov r12, rcx
  sub r12, rsi                # rows to copy
  mov r13, rdx
  sub r13, rdi                # dwords per row
  mov rax, rsi
  imul rax, [rip + __k_screen_pitch]
  shl rdi, 2
  add rax, rdi
  lea r14, [rip + __k_back]
  add r14, rax                # source row
  mov rbx, [rip + __k_screen_base]
  add rbx, rax                # screen row
.Lfp_row:
  mov rsi, r14
  mov rdi, rbx
  mov rcx, r13
  rep movsd
  add r14, [rip + __k_screen_pitch]
  add rbx, [rip + __k_screen_pitch]
  dec r12
  jnz .Lfp_row
.Lfp_done:
  pop r14
  pop r13
  pop r12
  pop rbx
  xor eax, eax
  ret

# Restrict the rectangles the runtime fills to a clip rectangle, so a band
# repaint costs the band instead of the windows on it.  Glyphs are not clipped:
# one that lands outside redraws pixels the band already holds, and a branch
# per bit is not worth saving them.
#   fb_clip(x0, y0, x1, y1)
__k_fb_clip:
  test rdi, rdi
  jns .Lclip_x0
  xor edi, edi
.Lclip_x0:
  test rsi, rsi
  jns .Lclip_y0
  xor esi, esi
.Lclip_y0:
  cmp rdx, SCREEN_W
  jle .Lclip_x1
  mov edx, SCREEN_W
.Lclip_x1:
  cmp rcx, SCREEN_H
  jle .Lclip_y1
  mov ecx, SCREEN_H
.Lclip_y1:
  mov [rip + __k_clip_x0], rdi
  mov [rip + __k_clip_y0], rsi
  mov [rip + __k_clip_x1], rdx
  mov [rip + __k_clip_y1], rcx
  xor eax, eax
  ret

# The console cells repainted since the last call, as 1 plus four byte fields
# (x0, y0, x1, y1) in cells, or 0 when nothing changed.  The caller decides how
# to get them onto the screen through the z-order.
__k_console_dirty:
  cmp qword ptr [rip + __k_con_dmg], 0
  je .Lcd_none
  mov qword ptr [rip + __k_con_dmg], 0
  mov rax, [rip + __k_con_dx0]
  mov rcx, [rip + __k_con_dy0]
  shl rcx, 8
  or rax, rcx
  mov rcx, [rip + __k_con_dx1]
  shl rcx, 16
  or rax, rcx
  mov rcx, [rip + __k_con_dy1]
  shl rcx, 24
  or rax, rcx
  inc rax                     # 1-based: 0 means nothing changed
  ret
.Lcd_none:
  xor eax, eax
  ret

# ---------------------------------------------------------------- data
.data
# Where drawing goes: the screen until fb_back() points it at the back buffer.
__k_fb_base:
  .quad FB
__k_fb_pitch:
  .quad PITCH
# The real screen, recorded by Kernel/boot.s from the VBE mode info block.
__k_screen_base:
  .quad FB
__k_screen_pitch:
  .quad PITCH
# Nothing is clipped until a band repaint says otherwise.
__k_clip_x0:
  .quad 0
__k_clip_y0:
  .quad 0
__k_clip_x1:
  .quad SCREEN_W
__k_clip_y1:
  .quad SCREEN_H
__t_oom_msg:
  .ascii "tlang: out of memory\n"
__t_bad_alloc_msg:
  .ascii "tlang: invalid allocation size\n"
__t_oob_msg:
  .ascii "tlang: index out of bounds\n"
# Console origin and visibility, so a window manager can place or hide it.
__k_con_x:
  .quad 516
__k_con_y:
  .quad 228
__k_con_visible:
  .quad 1

.bss
# One screen of pixels to compose into; .bss costs no file bytes and boot.s
# zeroes it.
.align 64
__k_back:
  .zero 1280 * 1024 * 4

.align 16
__k_arena:
  .zero 1048576
__k_arena_pos:
  .zero 8
__k_cursor:
  .zero 8
__k_text:
  .zero CON_COLS * CON_ROWS
__k_serial_ready:
  .zero 8
__k_console_ready:
  .zero 8
# Cells the console repainted since the last console_dirty(), in cell
# coordinates so a moved console keeps the report valid.
__k_con_dmg:
  .zero 8
__k_con_dx0:
  .zero 8
__k_con_dy0:
  .zero 8
__k_con_dx1:
  .zero 8
__k_con_dy1:
  .zero 8

# Boot stack; Kernel/boot.s loads rsp from __k_stack_top before calling _start.
.align 16
__k_stack:
  .zero 65536
__k_stack_top:

.section .note.GNU-stack,"",@progbits
