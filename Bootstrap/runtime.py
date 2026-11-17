"""The tlang runtime: hand-written assembly, emitted only when a program uses it.

Every entry declares its dependencies, so a program that never prints ships no
I/O code at all.  All of it runs on raw Linux syscalls; there is no libc.
"""

from .builtins_gen import BUILTINS

ARENA_SIZE = 64 * 1024 * 1024
MAX_ALLOC = (ARENA_SIZE - 16) // 8
OOM_MSG = "tlang: out of memory\n"
OOB_MSG = "tlang: index out of bounds\n"
BAD_ALLOC_MSG = "tlang: invalid allocation size\n"

# name -> (assembly body, dependencies)
RUNTIME = {
    "strlen": (
        """__t_strlen:
  xor eax, eax
.Lt_strlen_loop:
  cmp byte ptr [rdi + rax], 0
  je .Lt_strlen_done
  inc rax
  jmp .Lt_strlen_loop
.Lt_strlen_done:
  ret""",
        [],
    ),
    "str_offset": (
        """__t_str_offset:
  lea rax, [rdi + rsi]
  ret""",
        [],
    ),
    "str_diff": (
        """__t_str_diff:
  mov rax, rdi
  sub rax, rsi
  ret""",
        [],
    ),
    # Bit primitives used by emulators.  Each is a leaf with no dependencies.
    "clz": (
        """__t_clz:
  mov rax, rdi
  test rax, rax
  je .Lt_clz_zero
  bsr rax, rax
  xor rax, 63
  ret
.Lt_clz_zero:
  mov rax, 64
  ret""",
        [],
    ),
    "rbit": (
        """__t_rbit:
  mov rax, rdi
  xor rcx, rcx
  mov r8d, 64
.Lt_rbit_loop:
  shr rax, 1
  rcl rcx, 1
  dec r8
  jnz .Lt_rbit_loop
  mov rax, rcx
  ret""",
        [],
    ),
    "bswap16": (
        """__t_bswap16:
  mov eax, edi
  rol ax, 8
  movzx rax, ax
  ret""",
        [],
    ),
    "bswap32": (
        """__t_bswap32:
  mov eax, edi
  bswap eax
  ret""",
        [],
    ),
    "bswap64": (
        """__t_bswap64:
  mov rax, rdi
  bswap rax
  ret""",
        [],
    ),
    "sext8": (
        """__t_sext8:
  movsx rax, dil
  ret""",
        [],
    ),
    "sext16": (
        """__t_sext16:
  movsx rax, di
  ret""",
        [],
    ),
    "sext32": (
        """__t_sext32:
  movsxd rax, edi
  ret""",
        [],
    ),
    "udiv": (
        """__t_udiv:
  mov rax, rdi
  xor edx, edx
  div rsi
  ret""",
        [],
    ),
    "umod": (
        """__t_umod:
  mov rax, rdi
  xor edx, edx
  div rsi
  mov rax, rdx
  ret""",
        [],
    ),
    "rol8": (
        """__t_rol8:
  mov eax, edi
  mov ecx, esi
  rol al, cl
  movzx rax, al
  ret""",
        [],
    ),
    "ror8": (
        """__t_ror8:
  mov eax, edi
  mov ecx, esi
  ror al, cl
  movzx rax, al
  ret""",
        [],
    ),
    # Unchecked guest-memory primitives.  A newbuf string is just bytes, so
    # these need no header and no bounds branch; callers that want a trap use
    # ordinary indexing or --bounds (the default).
    "ld8": (
        """__t_ld8:
  mov rax, rdi
  add rax, rsi
  movzx rax, byte ptr [rax]
  ret""",
        [],
    ),
    "ld16": (
        """__t_ld16:
  mov rax, rdi
  add rax, rsi
  movzx rax, word ptr [rax]
  ret""",
        [],
    ),
    "ld32": (
        """__t_ld32:
  mov rax, rdi
  add rax, rsi
  mov eax, dword ptr [rax]
  ret""",
        [],
    ),
    "ld64": (
        """__t_ld64:
  mov rax, rdi
  add rax, rsi
  mov rax, qword ptr [rax]
  ret""",
        [],
    ),
    "st8": (
        """__t_st8:
  add rdi, rsi
  mov byte ptr [rdi], dl
  ret""",
        [],
    ),
    "st16": (
        """__t_st16:
  add rdi, rsi
  mov word ptr [rdi], dx
  ret""",
        [],
    ),
    "st32": (
        """__t_st32:
  add rdi, rsi
  mov dword ptr [rdi], edx
  ret""",
        [],
    ),
    "st64": (
        """__t_st64:
  add rdi, rsi
  mov qword ptr [rdi], rdx
  ret""",
        [],
    ),
    "memcpy": (
        """__t_memcpy:
  mov rax, rdi
  mov rcx, rdx
  rep movsb
  ret""",
        [],
    ),
    "memset": (
        """__t_memset:
  mov r8, rdi
  mov rcx, rdx
  mov eax, esi
  rep stosb
  mov rax, r8
  ret""",
        [],
    ),
    "print": (
        """__t_print:
  push rdi
  call __t_strlen
  mov rdx, rax
  pop rsi
  mov eax, 1
  mov edi, 1
  syscall
  ret""",
        ["strlen"],
    ),
    "print_err": (
        """__t_print_err:
  push rdi
  call __t_strlen
  mov rdx, rax
  pop rsi
  mov eax, 1
  mov edi, 2
  syscall
  ret""",
        ["strlen"],
    ),
    "print_char": (
        """__t_print_char:
  sub rsp, 16
  mov byte ptr [rsp], dil
  mov rsi, rsp
  mov edx, 1
  mov edi, 1
  mov eax, 1
  syscall
  add rsp, 16
  ret""",
        [],
    ),
    "print_int": (
        """__t_print_int:
  push rbx
  sub rsp, 40
  mov rax, rdi
  lea rsi, [rsp + 40]
  xor r8d, r8d
  test rax, rax
  jns .Lt_pi_abs
  neg rax
  mov r8d, 1
.Lt_pi_abs:
  mov ebx, 10
.Lt_pi_loop:
  xor edx, edx
  div rbx
  add dl, 48
  dec rsi
  mov byte ptr [rsi], dl
  test rax, rax
  jne .Lt_pi_loop
  test r8d, r8d
  je .Lt_pi_write
  dec rsi
  mov byte ptr [rsi], 45
.Lt_pi_write:
  lea rdx, [rsp + 40]
  sub rdx, rsi
  mov eax, 1
  mov edi, 1
  syscall
  add rsp, 40
  pop rbx
  ret""",
        [],
    ),
    "alloc": (
        # Every block carries a 16-byte header: capacity and length, both in
        # 8-byte slots.  `alloc` starts full -- n zeroed elements -- and
        # `__t_append` grows by reallocating when the length reaches capacity.
        # Reject negative or overflowing counts before scaling by eight.
        """__t_alloc:
  test rdi, rdi
  js .Lt_alloc_bad
  cmp rdi, %d
  ja .Lt_alloc_oom
  mov rcx, [rip + __t_arena_pos]
  lea rax, [rip + __t_arena]
  add rax, rcx
  mov rdx, rdi
  shl rdx, 3
  add rdx, 16
  add rcx, rdx
  mov [rip + __t_arena_pos], rcx
  cmp rcx, %d
  ja .Lt_alloc_oom
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
.Lt_alloc_oom:
  lea rsi, [rip + __t_oom_msg]
  mov edx, %d
  mov eax, 1
  mov edi, 2
  syscall
  mov eax, 60
  mov edi, 1
  syscall
.Lt_alloc_bad:
  lea rsi, [rip + __t_bad_alloc_msg]
  mov edx, %d
  mov eax, 1
  mov edi, 2
  syscall
  mov eax, 60
  mov edi, 134
  syscall""" % (MAX_ALLOC, ARENA_SIZE, len(OOM_MSG), len(BAD_ALLOC_MSG)),
        [],
    ),
    "bounds_fail": (
        """__t_bounds_fail:
  lea rsi, [rip + __t_oob_msg]
  mov edx, %d
  mov eax, 1
  mov edi, 2
  syscall
  mov eax, 60
  mov edi, 134
  syscall""" % len(OOB_MSG),
        [],
    ),
    "alen": (
        """__t_alen:
  mov rax, [rdi - 8]
  ret""",
        [],
    ),
    # The arena is a forward-only bump allocator. A mark is an offset from
    # __t_arena, so a caller can discard all allocations made after it. The
    # caller is responsible for not keeping pointers into a released region.
    "arena_mark": (
        """__t_arena_mark:
  mov rax, [rip + __t_arena_pos]
  ret""",
        [],
    ),
    "arena_release": (
        """__t_arena_release:
  mov [rip + __t_arena_pos], rdi
  xor eax, eax
  ret""",
        [],
    ),
    "append": (
        # append x to a: rdi = array, rsi = value.  Fill in place while there is
        # capacity, otherwise double it and copy.  Returns the array, so the
        # caller assigns it back (`a = append(a, x)`).
        """__t_append:
  push rbx
  push r12
  push r13
  mov rbx, rdi
  mov r12, rsi
  mov r13, [rbx - 8]
  mov rdx, [rbx - 16]
  cmp r13, rdx
  jl .Lt_ap_store
  mov rdi, rdx
  shl rdi, 1
  cmp rdi, 4
  jge .Lt_ap_cap
  mov rdi, 4
.Lt_ap_cap:
  call __t_alloc
  xor ecx, ecx
.Lt_ap_copy:
  cmp rcx, r13
  jge .Lt_ap_copied
  mov r8, [rbx + rcx*8]
  mov [rax + rcx*8], r8
  inc rcx
  jmp .Lt_ap_copy
.Lt_ap_copied:
  mov [rax - 8], r13
  mov rbx, rax
.Lt_ap_store:
  mov [rbx + r13*8], r12
  inc r13
  mov [rbx - 8], r13
  mov rax, rbx
  pop r13
  pop r12
  pop rbx
  ret""",
        ["alloc"],
    ),
    "itoa": (
        """__t_itoa:
  push rbx
  sub rsp, 48
  mov rax, rdi
  lea rsi, [rsp + 48]
  xor r8d, r8d
  test rax, rax
  jns .Lt_ia_abs
  neg rax
  mov r8d, 1
.Lt_ia_abs:
  mov ebx, 10
.Lt_ia_loop:
  xor edx, edx
  div rbx
  add dl, 48
  dec rsi
  mov byte ptr [rsi], dl
  test rax, rax
  jne .Lt_ia_loop
  test r8d, r8d
  je .Lt_ia_copy
  dec rsi
  mov byte ptr [rsi], 45
.Lt_ia_copy:
  lea rdx, [rsp + 48]
  sub rdx, rsi
  push rsi
  push rdx
  lea rdi, [rdx + 8]
  shr rdi, 3
  call __t_alloc
  pop rdx
  pop rsi
  xor ecx, ecx
.Lt_ia_cp:
  cmp rcx, rdx
  jge .Lt_ia_done
  mov r8b, [rsi + rcx]
  mov [rax + rcx], r8b
  inc rcx
  jmp .Lt_ia_cp
.Lt_ia_done:
  mov byte ptr [rax + rdx], 0
  add rsp, 48
  pop rbx
  ret""",
        ["alloc"],
    ),
    # Float to text: six fractional digits, then trailing zeros and the point
    # trimmed (1.5 -> "1.5", 2.0 -> "2"). Splitting the integer and fractional
    # parts before scaling keeps 9300000000000 exact, where value * 1e6 would
    # overflow; anything too large for a 64-bit integer uses exponent form.
    "ftoa": (
        """__t_ftoa:
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 48
  mov r12, rdi
  xor r15d, r15d
  test r12, r12
  jns .Lt_ft_sign_done
  mov r15d, 1
  mov rax, 0x7fffffffffffffff
  and r12, rax
.Lt_ft_sign_done:
  mov rax, r12
  shr rax, 52
  and eax, 0x7ff
  cmp eax, 0x7ff
  je .Lt_ft_special
  xor r13d, r13d
  movq xmm0, r12
  mov rax, 0x43e0000000000000
  movq xmm1, rax
  ucomisd xmm0, xmm1
  jb .Lt_ft_split
  mov rax, 0x4024000000000000
  movq xmm1, rax
.Lt_ft_norm:
  ucomisd xmm0, xmm1
  jb .Lt_ft_normed
  divsd xmm0, xmm1
  inc r13
  jmp .Lt_ft_norm
.Lt_ft_normed:
  movq r12, xmm0
.Lt_ft_split:
  movq xmm0, r12
  cvttsd2si r14, xmm0
  cvtsi2sd xmm1, r14
  subsd xmm0, xmm1
  mov rax, 0x412e848000000000
  movq xmm2, rax
  mulsd xmm0, xmm2
  cvtsd2si rax, xmm0
  cmp rax, 1000000
  jl .Lt_ft_rounded
  xor eax, eax
  inc r14
.Lt_ft_rounded:
  mov r12, rax
  mov edi, 4
  call __t_alloc
  mov rbx, rax
  mov r8, rax
  test r15d, r15d
  je .Lt_ft_int
  mov byte ptr [r8], 45
  inc r8
.Lt_ft_int:
  lea r9, [rsp + 32]
  mov rax, r14
  test rax, rax
  jne .Lt_ft_idigits
  dec r9
  mov byte ptr [r9], 48
  jmp .Lt_ft_icopy
.Lt_ft_idigits:
  mov rcx, 10
.Lt_ft_iloop:
  xor edx, edx
  div rcx
  add dl, 48
  dec r9
  mov byte ptr [r9], dl
  test rax, rax
  jne .Lt_ft_iloop
.Lt_ft_icopy:
  lea rcx, [rsp + 32]
  cmp r9, rcx
  jge .Lt_ft_frac
  mov al, [r9]
  mov [r8], al
  inc r9
  inc r8
  jmp .Lt_ft_icopy
.Lt_ft_frac:
  mov byte ptr [r8], 46
  inc r8
  mov rcx, 100000
.Lt_ft_floop:
  mov rax, r12
  xor edx, edx
  div rcx
  mov r12, rdx
  add al, 48
  mov byte ptr [r8], al
  inc r8
  mov rax, rcx
  xor edx, edx
  mov r10, 10
  div r10
  mov rcx, rax
  test rcx, rcx
  jne .Lt_ft_floop
.Lt_ft_trim:
  cmp byte ptr [r8 - 1], 48
  jne .Lt_ft_trim_dot
  dec r8
  jmp .Lt_ft_trim
.Lt_ft_trim_dot:
  cmp byte ptr [r8 - 1], 46
  jne .Lt_ft_suffix
  dec r8
.Lt_ft_suffix:
  test r13, r13
  je .Lt_ft_end
  mov byte ptr [r8], 101
  inc r8
  lea r9, [rsp + 32]
  mov rax, r13
  mov rcx, 10
.Lt_ft_eloop:
  xor edx, edx
  div rcx
  add dl, 48
  dec r9
  mov byte ptr [r9], dl
  test rax, rax
  jne .Lt_ft_eloop
.Lt_ft_ecopy:
  lea rcx, [rsp + 32]
  cmp r9, rcx
  jge .Lt_ft_end
  mov al, [r9]
  mov [r8], al
  inc r9
  inc r8
  jmp .Lt_ft_ecopy
.Lt_ft_end:
  mov byte ptr [r8], 0
  mov rax, rbx
  jmp .Lt_ft_exit
.Lt_ft_special:
  mov edi, 2
  call __t_alloc
  mov rbx, rax
  mov r8, rax
  test r15d, r15d
  je .Lt_ft_spec_kind
  mov byte ptr [r8], 45
  inc r8
.Lt_ft_spec_kind:
  mov rax, r12
  shl rax, 12
  test rax, rax
  jne .Lt_ft_spec_nan
  mov dword ptr [r8], 0x666e69
  jmp .Lt_ft_spec_done
.Lt_ft_spec_nan:
  mov dword ptr [r8], 0x6e616e
.Lt_ft_spec_done:
  mov rax, rbx
.Lt_ft_exit:
  add rsp, 48
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret""",
        ["alloc"],
    ),
    "concat": (
        """__t_concat:
  push rbx
  push r12
  push r13
  push r14
  mov rbx, rdi
  mov r14, rsi
  call __t_strlen
  mov r12, rax
  mov rdi, r14
  call __t_strlen
  mov r13, rax
  mov rdx, r12
  add rdx, r13
  jc .Lt_cc_bad
  push rdx
  lea rdi, [rdx + 8]
  shr rdi, 3
  call __t_alloc
  pop rdx
  xor ecx, ecx
.Lt_cc_a:
  cmp rcx, r12
  jge .Lt_cc_b
  mov r8b, [rbx + rcx]
  mov [rax + rcx], r8b
  inc rcx
  jmp .Lt_cc_a
.Lt_cc_b:
  xor ecx, ecx
.Lt_cc_b2:
  cmp rcx, r13
  jge .Lt_cc_done
  mov r8b, [r14 + rcx]
  mov r9, r12
  add r9, rcx
  mov [rax + r9], r8b
  inc rcx
  jmp .Lt_cc_b2
.Lt_cc_done:
  mov byte ptr [rax + rdx], 0
  pop r14
  pop r13
  pop r12
  pop rbx
  ret
.Lt_cc_bad:
  call __t_bounds_fail""",
        ["strlen", "alloc", "bounds_fail"],
    ),
    "slice": (
        """__t_slice:
  push rbx
  push r12
  push r13
  push r14
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  test r12, r12
  js .Lt_sl_bad
  test r13, r13
  js .Lt_sl_bad
  mov r14, r12
  add r14, r13
  jc .Lt_sl_bad
  call __t_strlen
  cmp r14, rax
  ja .Lt_sl_bad
  lea rdi, [r13 + 8]
  shr rdi, 3
  call __t_alloc
  add rbx, r12
  xor ecx, ecx
.Lt_sl_loop:
  cmp rcx, r13
  jge .Lt_sl_done
  mov r8b, [rbx + rcx]
  mov [rax + rcx], r8b
  inc rcx
  jmp .Lt_sl_loop
.Lt_sl_done:
  mov byte ptr [rax + r13], 0
  pop r14
  pop r13
  pop r12
  pop rbx
  ret
.Lt_sl_bad:
  call __t_bounds_fail""",
        ["alloc", "strlen", "bounds_fail"],
    ),
    "str_eq": (
        """__t_str_eq:
  xor ecx, ecx
.Lt_seq_loop:
  mov al, [rdi + rcx]
  mov dl, [rsi + rcx]
  cmp al, dl
  jne .Lt_seq_ne
  test al, al
  je .Lt_seq_eq
  inc rcx
  jmp .Lt_seq_loop
.Lt_seq_eq:
  mov eax, 1
  ret
.Lt_seq_ne:
  xor eax, eax
  ret""",
        [],
    ),
    # Byte-wise ordering, like strcmp: the first differing byte decides and a
    # prefix sorts before the longer string.
    "str_cmp": (
        """__t_str_cmp:
  xor ecx, ecx
.Lt_sc_loop:
  movzx eax, byte ptr [rdi + rcx]
  movzx edx, byte ptr [rsi + rcx]
  cmp eax, edx
  jb .Lt_sc_lt
  ja .Lt_sc_gt
  test eax, eax
  je .Lt_sc_eq
  inc rcx
  jmp .Lt_sc_loop
.Lt_sc_lt:
  mov rax, -1
  ret
.Lt_sc_gt:
  mov rax, 1
  ret
.Lt_sc_eq:
  xor eax, eax
  ret""",
        [],
    ),
    "int": (
        """__t_int:
  xor eax, eax
  xor ecx, ecx
.Lt_int_skip:
  cmp byte ptr [rdi], 32
  jne .Lt_int_sign
  inc rdi
  jmp .Lt_int_skip
.Lt_int_sign:
  cmp byte ptr [rdi], 45
  jne .Lt_int_loop
  mov ecx, 1
  inc rdi
.Lt_int_loop:
  movzx edx, byte ptr [rdi]
  sub edx, 48
  cmp edx, 9
  ja .Lt_int_done
  imul rax, rax, 10
  add rax, rdx
  inc rdi
  jmp .Lt_int_loop
.Lt_int_done:
  test ecx, ecx
  je .Lt_int_ret
  neg rax
.Lt_int_ret:
  ret""",
        [],
    ),
    "read_line": (
        """__t_read_line:
.Lt_rl_refill:
  mov rax, [rip + __t_buf_pos]
  cmp rax, [rip + __t_buf_len]
  jl .Lt_rl_have
  xor eax, eax
  xor edi, edi
  lea rsi, [rip + __t_buf]
  mov edx, 255
  syscall
  test rax, rax
  jle .Lt_rl_eof
  mov [rip + __t_buf_len], rax
  xor eax, eax
  mov [rip + __t_buf_pos], rax
.Lt_rl_have:
  lea rsi, [rip + __t_buf]
  mov rcx, [rip + __t_buf_pos]
  mov r8, rcx
  mov r9, [rip + __t_buf_len]
.Lt_rl_scan:
  cmp r8, r9
  jge .Lt_rl_no_nl
  cmp byte ptr [rsi + r8], 10
  je .Lt_rl_found
  inc r8
  jmp .Lt_rl_scan
.Lt_rl_found:
  mov byte ptr [rsi + r8], 0
  lea rax, [r8 + 1]
  mov [rip + __t_buf_pos], rax
  lea rax, [rsi + rcx]
  ret
.Lt_rl_no_nl:
  mov [rip + __t_buf_pos], r9
  cmp r9, rcx
  jle .Lt_rl_ret
  cmp byte ptr [rsi + r9 - 1], 13
  jne .Lt_rl_ret
  mov byte ptr [rsi + r9 - 1], 0
.Lt_rl_ret:
  lea rax, [rsi + rcx]
  ret
.Lt_rl_eof:
  lea rax, [rip + __t_empty]
  ret""",
        [],
    ),
    "input": (
        """__t_input:
  call __t_read_line
  mov rsi, rax
  xor ecx, ecx
.Lt_in_len:
  cmp byte ptr [rsi + rcx], 0
  je .Lt_in_have
  inc rcx
  jmp .Lt_in_len
.Lt_in_have:
  push rsi
  push rcx
  lea rdi, [rcx + 8]
  shr rdi, 3
  call __t_alloc
  pop rcx
  pop rsi
  xor edx, edx
.Lt_in_copy:
  cmp rdx, rcx
  jge .Lt_in_done
  mov r8b, [rsi + rdx]
  mov [rax + rdx], r8b
  inc rdx
  jmp .Lt_in_copy
.Lt_in_done:
  mov byte ptr [rax + rcx], 0
  ret""",
        ["read_line", "alloc"],
    ),
    # A binary file cannot be measured with len(): read_file returns a
    # NUL-terminated string, so the first zero byte looks like the end. This
    # asks the file itself, which lets a caller index every byte of a ROM.
    "file_size": (
        """__t_file_size:
  mov eax, 2
  xor esi, esi
  xor edx, edx
  syscall
  test rax, rax
  js .Lt_fs_zero
  mov r8, rax
  mov eax, 8
  mov edi, r8d
  xor esi, esi
  mov edx, 2
  syscall
  mov r9, rax
  mov eax, 3
  mov edi, r8d
  syscall
  test r9, r9
  js .Lt_fs_zero
  mov rax, r9
  ret
.Lt_fs_zero:
  xor eax, eax
  ret""",
        [],
    ),
    # Reads the whole file, not the first chunk of it. lseek gives the exact
    # size for anything seekable, so the arena allocation is exact and one read
    # is normally enough; pipes cannot seek, so they get a 1 MB window and a
    # read-until-EOF loop.
    "read_file": (
        """__t_read_file:
  push rbx
  push r12
  push r13
  push r14
  mov eax, 2
  xor esi, esi
  xor edx, edx
  syscall
  test rax, rax
  js .Lt_rf_fail
  mov rbx, rax
  mov eax, 8
  mov edi, ebx
  xor esi, esi
  mov edx, 2
  syscall
  test rax, rax
  jle .Lt_rf_unknown
  mov r13, rax
  jmp .Lt_rf_rewind
.Lt_rf_unknown:
  mov r13, 1048576
.Lt_rf_rewind:
  mov eax, 8
  mov edi, ebx
  xor esi, esi
  xor edx, edx
  syscall
  lea rdi, [r13 + 8]
  shr rdi, 3
  call __t_alloc
  mov r12, rax
  xor r14, r14
.Lt_rf_loop:
  mov rdx, r13
  sub rdx, r14
  jle .Lt_rf_done
  xor eax, eax
  mov edi, ebx
  lea rsi, [r12 + r14]
  syscall
  test rax, rax
  jle .Lt_rf_done
  add r14, rax
  jmp .Lt_rf_loop
.Lt_rf_done:
  mov byte ptr [r12 + r14], 0
  mov eax, 3
  mov edi, ebx
  syscall
  mov rax, r12
  pop r14
  pop r13
  pop r12
  pop rbx
  ret
.Lt_rf_fail:
  lea rax, [rip + __t_empty]
  pop r14
  pop r13
  pop r12
  pop rbx
  ret""",
        ["alloc"],
    ),
    # Text-file output. The data is a NUL-terminated string, so these helpers
    # intentionally cannot write embedded NUL bytes. They return 1 on success
    # and 0 on failure, and retry short writes.
    "write_file": (
        """__t_write_file:
  push rbx
  push r12
  push r13
  push r14
  mov r12, rdi
  mov r13, rsi
  mov eax, 2
  mov rdi, r12
  mov esi, 577
  mov edx, 420
  syscall
  test rax, rax
  js .Lt_wf_fail
  mov rbx, rax
  mov rdi, r13
  call __t_strlen
  mov r14, rax
  xor r8, r8
.Lt_wf_loop:
  test r14, r14
  je .Lt_wf_close
  mov eax, 1
  mov edi, ebx
  lea rsi, [r13 + r8]
  mov rdx, r14
  syscall
  test rax, rax
  jle .Lt_wf_close_fail
  add r8, rax
  sub r14, rax
  jmp .Lt_wf_loop
.Lt_wf_close:
  mov eax, 3
  mov edi, ebx
  syscall
  mov eax, 1
  jmp .Lt_wf_out
.Lt_wf_close_fail:
  mov eax, 3
  mov edi, ebx
  syscall
.Lt_wf_fail:
  xor eax, eax
.Lt_wf_out:
  pop r14
  pop r13
  pop r12
  pop rbx
  ret""",
        ["strlen"],
    ),
    "append_file": (
        """__t_append_file:
  push rbx
  push r12
  push r13
  push r14
  mov r12, rdi
  mov r13, rsi
  mov eax, 2
  mov rdi, r12
  mov esi, 1089
  mov edx, 420
  syscall
  test rax, rax
  js .Lt_af_fail
  mov rbx, rax
  mov rdi, r13
  call __t_strlen
  mov r14, rax
  xor r8, r8
.Lt_af_loop:
  test r14, r14
  je .Lt_af_close
  mov eax, 1
  mov edi, ebx
  lea rsi, [r13 + r8]
  mov rdx, r14
  syscall
  test rax, rax
  jle .Lt_af_close_fail
  add r8, rax
  sub r14, rax
  jmp .Lt_af_loop
.Lt_af_close:
  mov eax, 3
  mov edi, ebx
  syscall
  mov eax, 1
  jmp .Lt_af_out
.Lt_af_close_fail:
  mov eax, 3
  mov edi, ebx
  syscall
.Lt_af_fail:
  xor eax, eax
.Lt_af_out:
  pop r14
  pop r13
  pop r12
  pop rbx
  ret""",
        ["strlen"],
    ),
    "file_exists": (
        """__t_file_exists:
  mov eax, 21
  xor esi, esi
  syscall
  test rax, rax
  js .Lt_fe_no
  mov eax, 1
  ret
.Lt_fe_no:
  xor eax, eax
  ret""",
        [],
    ),
    # The kernel lays out argc, argv and envp on the initial stack; argv and
    # argc are captured by _start, so envp is argv + 8*argc + 8.  Each entry
    # is NAME=value, and an unset name yields the empty string.
    "env": (
        """__t_env:
  mov r8, rdi
  mov rax, [rip + __t_argc_val]
  mov r9, [rip + __t_argv_val]
  lea rax, [r9 + rax*8 + 8]
.Lt_env_loop:
  mov r9, [rax]
  test r9, r9
  je .Lt_env_none
  xor rcx, rcx
.Lt_env_name:
  mov dl, [r8 + rcx]
  test dl, dl
  je .Lt_env_end
  cmp dl, [r9 + rcx]
  jne .Lt_env_next
  inc rcx
  jmp .Lt_env_name
.Lt_env_end:
  cmp byte ptr [r9 + rcx], 61
  je .Lt_env_hit
.Lt_env_next:
  add rax, 8
  jmp .Lt_env_loop
.Lt_env_hit:
  lea rax, [r9 + rcx + 1]
  ret
.Lt_env_none:
  lea rax, [rip + __t_empty]
  ret""",
        ["args"],
    ),
    # Minimal binary I/O for protocol clients: a Unix socket connect, byte
    # reads/writes that may be partial, poll(2) for event waits, and a zeroed
    # byte buffer that is a string (so it can hold NULs and be indexed).
    "sock_unix": (
        """__t_sock_unix:
  push rbx
  push r12
  sub rsp, 128
  mov r12, rdi
  mov eax, 41
  mov edi, 1
  mov esi, 1
  xor edx, edx
  syscall
  test rax, rax
  js .Lt_sk_fail
  mov rbx, rax
  mov word ptr [rsp], 1
  xor ecx, ecx
.Lt_sk_copy:
  mov al, [r12 + rcx]
  test al, al
  je .Lt_sk_copied
  mov [rsp + 2 + rcx], al
  inc rcx
  cmp rcx, 106
  jb .Lt_sk_copy
.Lt_sk_copied:
  mov rdi, rbx
  mov rsi, rsp
  lea rdx, [rcx + 2]
  mov eax, 42
  syscall
  test rax, rax
  js .Lt_sk_close
  mov rax, rbx
  jmp .Lt_sk_out
.Lt_sk_close:
  mov eax, 3
  mov edi, ebx
  syscall
.Lt_sk_fail:
  mov rax, -1
.Lt_sk_out:
  add rsp, 128
  pop r12
  pop rbx
  ret""",
        ["strlen"],
    ),
    "fd_read": (
        """__t_fd_read:
  push rbx
  push r12
  push r13
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  xor r8, r8
.Lt_fr_loop:
  cmp r8, r13
  jge .Lt_fr_done
  xor eax, eax
  mov edi, ebx
  lea rsi, [r12 + r8]
  mov rdx, r13
  sub rdx, r8
  syscall
  test rax, rax
  jle .Lt_fr_done
  add r8, rax
  jmp .Lt_fr_loop
.Lt_fr_done:
  mov rax, r8
  pop r13
  pop r12
  pop rbx
  ret""",
        [],
    ),
    "fd_write": (
        """__t_fd_write:
  push rbx
  push r12
  push r13
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  xor r8, r8
.Lt_fw_loop:
  cmp r8, r13
  jge .Lt_fw_done
  mov eax, 1
  mov edi, ebx
  lea rsi, [r12 + r8]
  mov rdx, r13
  sub rdx, r8
  syscall
  test rax, rax
  jle .Lt_fw_done
  add r8, rax
  jmp .Lt_fw_loop
.Lt_fw_done:
  mov rax, r8
  pop r13
  pop r12
  pop rbx
  ret""",
        [],
    ),
    "fd_poll": (
        """__t_fd_poll:
  sub rsp, 16
  mov dword ptr [rsp], edi
  mov word ptr [rsp + 4], 1
  mov word ptr [rsp + 6], 0
  mov r8, rsi
  mov rdi, rsp
  mov esi, 1
  mov rdx, r8
  mov eax, 7
  syscall
  movzx eax, word ptr [rsp + 6]
  add rsp, 16
  ret""",
        [],
    ),
    "newbuf": (
        """__t_newbuf:
  lea rdi, [rdi + 8]
  shr rdi, 3
  jmp __t_alloc""",
        ["alloc"],
    ),
    # Shared memory for Wayland: a memfd of a given size, written with pwrite so
    # a frame can be rewritten in place, and a sendmsg that attaches a
    # descriptor to the bytes of one message (SCM_RIGHTS).
    "shm": (
        """__t_shm:
  push rbx
  sub rsp, 16
  mov rbx, rdi
  mov dword ptr [rsp], 0x6e616c74
  mov byte ptr [rsp + 4], 0x67
  mov byte ptr [rsp + 5], 0
  mov rdi, rsp
  mov esi, 1
  mov eax, 319
  syscall
  test rax, rax
  js .Lt_shm_fail
  mov rdi, rax
  mov rsi, rbx
  mov eax, 77
  syscall
  test rax, rax
  js .Lt_shm_close
  mov rax, rdi
  jmp .Lt_shm_out
.Lt_shm_close:
  mov eax, 3
  syscall
.Lt_shm_fail:
  mov rax, -1
.Lt_shm_out:
  add rsp, 16
  pop rbx
  ret""",
        [],
    ),
    "fd_pwrite": (
        """__t_fd_pwrite:
  push rbx
  push r12
  push r13
  push r14
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  xor r8, r8
.Lt_pw_loop:
  cmp r8, r14
  jge .Lt_pw_done
  mov eax, 18
  mov edi, ebx
  lea rsi, [r13 + r8]
  mov rdx, r14
  sub rdx, r8
  lea r10, [r12 + r8]
  syscall
  test rax, rax
  jle .Lt_pw_done
  add r8, rax
  jmp .Lt_pw_loop
.Lt_pw_done:
  mov rax, r8
  pop r14
  pop r13
  pop r12
  pop rbx
  ret""",
        [],
    ),
    "fd_send": (
        """__t_fd_send:
  push rbx
  push r12
  push r13
  push r14
  sub rsp, 112
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  mov qword ptr [rsp], 0
  mov dword ptr [rsp + 8], 0
  lea rax, [rsp + 64]
  mov [rsp + 16], rax
  mov qword ptr [rsp + 24], 1
  lea rax, [rsp + 80]
  mov [rsp + 32], rax
  mov qword ptr [rsp + 40], 24
  mov dword ptr [rsp + 48], 0
  mov [rsp + 64], r12
  mov [rsp + 72], r13
  mov qword ptr [rsp + 80], 20
  mov dword ptr [rsp + 88], 1
  mov dword ptr [rsp + 92], 1
  mov dword ptr [rsp + 96], r14d
  mov rdi, rbx
  mov rsi, rsp
  xor edx, edx
  mov eax, 46
  syscall
  xor r8, r8
  test rax, rax
  jle .Lt_sd_done
  mov r8, rax
.Lt_sd_more:
  cmp r8, r13
  jge .Lt_sd_done
  mov eax, 1
  mov edi, ebx
  lea rsi, [r12 + r8]
  mov rdx, r13
  sub rdx, r8
  syscall
  test rax, rax
  jle .Lt_sd_done
  add r8, rax
  jmp .Lt_sd_more
.Lt_sd_done:
  mov rax, r8
  add rsp, 112
  pop r14
  pop r13
  pop r12
  pop rbx
  ret""",
        [],
    ),
    "exit": (
        """__t_exit:
  mov eax, 60
  syscall""",
        [],
    ),
    "argc": (
        """__t_argc:
  mov rax, [rip + __t_argc_val]
  ret""",
        ["args"],
    ),
    "argv": (
        """__t_argv:
  test rdi, rdi
  js .Lt_av_none
  mov rax, [rip + __t_argc_val]
  cmp rdi, rax
  jae .Lt_av_none
  mov rax, [rip + __t_argv_val]
  mov rax, [rax + rdi*8]
  ret
.Lt_av_none:
  lea rax, [rip + __t_empty]
  ret""",
        ["args"],
    ),
    # Floating point uses the low 64 bits of xmm registers for arithmetic but
    # keeps the ABI and every value slot as an ordinary 64-bit integer. This
    # avoids a separate float calling convention and extra slot layout.
    "fconst": (
        """__t_fconst:
  cvtsi2sd xmm0, rdi
  test rsi, rsi
  je .Lt_fc_done
  mov rax, 0x4024000000000000
  movq xmm1, rax
  js .Lt_fc_neg
.Lt_fc_pos:
  mulsd xmm0, xmm1
  dec rsi
  jne .Lt_fc_pos
  jmp .Lt_fc_done
.Lt_fc_neg:
  divsd xmm0, xmm1
  inc rsi
  jne .Lt_fc_neg
.Lt_fc_done:
  movq rax, xmm0
  ret""",
        [],
    ),
    "fadd": (
        """__t_fadd:
  movq xmm0, rdi
  movq xmm1, rsi
  addsd xmm0, xmm1
  movq rax, xmm0
  ret""",
        [],
    ),
    "fsub": (
        """__t_fsub:
  movq xmm0, rdi
  movq xmm1, rsi
  subsd xmm0, xmm1
  movq rax, xmm0
  ret""",
        [],
    ),
    "fmul": (
        """__t_fmul:
  movq xmm0, rdi
  movq xmm1, rsi
  mulsd xmm0, xmm1
  movq rax, xmm0
  ret""",
        [],
    ),
    "fdiv": (
        """__t_fdiv:
  movq xmm0, rdi
  movq xmm1, rsi
  divsd xmm0, xmm1
  movq rax, xmm0
  ret""",
        [],
    ),
    # -1 less, 0 equal, 1 greater, 2 unordered (NaN).
    "fcmp": (
        """__t_fcmp:
  movq xmm0, rdi
  movq xmm1, rsi
  ucomisd xmm0, xmm1
  jp .Lt_fcmp_nan
  ja .Lt_fcmp_gt
  jb .Lt_fcmp_lt
  xor eax, eax
  ret
.Lt_fcmp_gt:
  mov eax, 1
  ret
.Lt_fcmp_lt:
  mov rax, -1
  ret
.Lt_fcmp_nan:
  mov eax, 2
  ret""",
        [],
    ),
    "itof": (
        """__t_itof:
  cvtsi2sd xmm0, rdi
  movq rax, xmm0
  ret""",
        [],
    ),
    "ftoi": (
        """__t_ftoi:
  movq xmm0, rdi
  cvttsd2si rax, xmm0
  ret""",
        [],
    ),
    "fneg": (
        """__t_fneg:
  mov rax, 0x8000000000000000
  xor rdi, rax
  mov rax, rdi
  ret""",
        [],
    ),
    "fabs": (
        """__t_fabs:
  mov rax, 0x7fffffffffffffff
  and rdi, rax
  mov rax, rdi
  ret""",
        [],
    ),
    "fsqrt": (
        """__t_fsqrt:
  movq xmm0, rdi
  sqrtsd xmm0, xmm0
  movq rax, xmm0
  ret""",
        [],
    ),
    # Fixed six-decimal formatting. The integer part is converted directly, so
    # values up to the signed 64-bit limit print exactly; above that it
    # delegates to __t_ftoa, which switches to exponent form.
    "print_float": (
        """__t_print_float:
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov r12, rdi
  mov rax, r12
  mov rcx, rax
  shr rcx, 52
  and ecx, 0x7ff
  cmp ecx, 0x7ff
  jne .Lt_pf_sign
  mov rdx, r12
  shl rdx, 12
  test rdx, rdx
  jne .Lt_pf_nan
.Lt_pf_sign:
  test r12, r12
  jns .Lt_pf_abs
  mov edi, 45
  call __t_print_char
  mov rax, r12
  mov rcx, 0x7fffffffffffffff
  and rax, rcx
  mov r12, rax
.Lt_pf_abs:
  mov rax, r12
  mov rcx, rax
  shr rcx, 52
  and ecx, 0x7ff
  cmp ecx, 0x7ff
  je .Lt_pf_special
  mov rax, 0x43e0000000000000
  movq xmm1, rax
  movq xmm0, r12
  ucomisd xmm0, xmm1
  jae .Lt_pf_big
  cvttsd2si r14, xmm0
  cvtsi2sd xmm1, r14
  subsd xmm0, xmm1
  mov rax, 0x412e848000000000
  movq xmm1, rax
  mulsd xmm0, xmm1
  cvtsd2si rax, xmm0
  cmp rax, 1000000
  jl .Lt_pf_split_done
  xor eax, eax
  inc r14
.Lt_pf_split_done:
  mov rbx, rax
  mov rdi, r14
  call __t_print_int
  mov edi, 46
  call __t_print_char
  mov r15, 100000
.Lt_pf_frac:
  mov rax, rbx
  xor edx, edx
  div r15
  mov rbx, rdx
  add al, 48
  movzx edi, al
  call __t_print_char
  mov rax, r15
  xor edx, edx
  mov ecx, 10
  div rcx
  mov r15, rax
  test r15, r15
  jne .Lt_pf_frac
  jmp .Lt_pf_done
.Lt_pf_big:
  mov rdi, r12
  call __t_ftoa
  mov rdi, rax
  call __t_print
  jmp .Lt_pf_done
.Lt_pf_special:
  mov rdx, r12
  shl rdx, 12
  test rdx, rdx
  jne .Lt_pf_nan
  mov edi, 105
  call __t_print_char
  mov edi, 110
  call __t_print_char
  mov edi, 102
  call __t_print_char
  jmp .Lt_pf_done
.Lt_pf_nan:
  mov edi, 110
  call __t_print_char
  mov edi, 97
  call __t_print_char
  mov edi, 110
  call __t_print_char
.Lt_pf_done:
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret""",
        ["ftoa", "print", "print_int", "print_char"],
    ),
    # Common Linux features. These are hosted-only: a freestanding image has
    # no kernel to provide clocks, entropy, files or processes. Syscall numbers
    # are x86-64; a future architecture port would select them per target.
    "now": (
        """__t_now:
  sub rsp, 16
  xor edi, edi
  mov rsi, rsp
  mov eax, 228
  syscall
  mov rax, [rsp]
  imul rax, 1000000000
  add rax, [rsp + 8]
  add rsp, 16
  ret""",
        [],
    ),
    "sleep_ns": (
        """__t_sleep_ns:
  test rdi, rdi
  js .Lt_sl_einval
  sub rsp, 16
  mov rax, rdi
  xor rdx, rdx
  mov rcx, 1000000000
  div rcx
  mov [rsp], rax
  mov [rsp + 8], rdx
  mov rdi, rsp
  xor esi, esi
  mov eax, 35
  syscall
  add rsp, 16
  ret
.Lt_sl_einval:
  mov eax, -22
  ret""",
        [],
    ),
    "random_int": (
        """__t_random_int:
  sub rsp, 8
  mov rdi, rsp
  mov esi, 8
  xor edx, edx
  mov eax, 318
  syscall
  mov rax, [rsp]
  add rsp, 8
  ret""",
        [],
    ),
    "getpid": (
        """__t_getpid:
  mov eax, 39
  syscall
  ret""",
        [],
    ),
    "mkdir": (
        """__t_mkdir:
  mov eax, 83
  syscall
  ret""",
        [],
    ),
    "unlink": (
        """__t_unlink:
  mov eax, 87
  syscall
  ret""",
        [],
    ),
    "rename": (
        """__t_rename:
  mov eax, 82
  syscall
  ret""",
        [],
    ),
    # Descriptor-based file access, for programs ported from C. Flags are the
    # Linux values (O_RDONLY=0, O_WRONLY=1, O_RDWR=2, O_CREAT=64, O_TRUNC=512,
    # O_APPEND=1024); mode is 0755 when a create is requested.
    "open_fd": (
        """__t_open_fd:
  mov edx, 493
  mov eax, 2
  syscall
  ret""",
        [],
    ),
    "close_fd": (
        """__t_close_fd:
  mov eax, 3
  syscall
  ret""",
        [],
    ),
    # st_mtim.tv_sec is at offset 88 in x86-64 struct stat; the buffer starts
    # at rsp + 8.
    "file_mtime": (
        """__t_file_mtime:
  sub rsp, 160
  mov [rsp + 144], rdi
  mov rdi, -100
  mov rsi, [rsp + 144]
  lea rdx, [rsp + 8]
  xor r10d, r10d
  mov eax, 262
  syscall
  test rax, rax
  js .Lt_fm_fail
  mov rax, [rsp + 96]
  add rsp, 160
  ret
.Lt_fm_fail:
  mov eax, -1
  add rsp, 160
  ret""",
        [],
    ),
    "getcwd": (
        """__t_getcwd:
  mov edi, 4096
  call __t_newbuf
  mov rdi, rax
  mov esi, 4096
  mov eax, 79
  syscall
  test rax, rax
  js .Lt_gcwd_fail
  mov rax, rdi
  ret
.Lt_gcwd_fail:
  lea rax, [rip + __t_empty]
  ret""",
        ["newbuf"],
    ),
}

# Canonical table keyed by the real assembly symbol.
RUNTIME_SYMBOLS = {
    "__t_" + name: (
        body,
        [dep if dep == "args" else "__t_" + dep for dep in deps],
    )
    for name, (body, deps) in RUNTIME.items()
}

# Entries a freestanding build takes from the kernel runtime
# (Kernel/kruntime.s) instead of emitting them: there is no process to write
# to or exit, and the kernel owns the allocator.
KERNEL_PROVIDED = {
    "__t_print", "__t_print_err", "__t_print_char", "__t_print_int",
    "__t_alloc", "__t_exit", "__t_bounds_fail",
}

# Entries that need the argv capture in _start rather than a function body.
PSEUDO_DEPS = {"args"}

CONCAT_SYMBOL = "__t_concat"
STRLEN_SYMBOL = "__t_strlen"


def resolve_used(used_symbols, freestanding=False):
    """Expand a set of runtime symbol names with their transitive dependencies.

    In freestanding mode the kernel-provided entries and the machine builtin
    stubs (__k_*) are left for the linker to resolve.
    """
    out = []
    seen = set()
    need_args = False

    def visit(name):
        nonlocal need_args
        if name in seen:
            return
        seen.add(name)
        if freestanding and (name in KERNEL_PROVIDED
                             or name.startswith("__k_")):
            return
        if name in PSEUDO_DEPS:
            need_args = True
            return
        entry = RUNTIME_SYMBOLS.get(name)
        if entry is None:
            raise KeyError(f"unknown runtime symbol {name!r}")
        for dep in entry[1]:
            visit(dep)
        out.append(entry[0])

    for name in sorted(used_symbols):
        visit(name)
    return out, need_args


BSS = """.bss
.align 16
__t_arena:
  .zero %d
__t_arena_pos:
  .zero 8
__t_buf:
  .zero 256
__t_buf_len:
  .zero 8
__t_buf_pos:
  .zero 8
__t_argc_val:
  .zero 8
__t_argv_val:
  .zero 8
""" % ARENA_SIZE

DATA_TOKENS = """.data
__t_empty:
  .byte 0
__t_oom_msg:
  .ascii "%s"
""" % OOM_MSG.replace("\n", "\\n")
