# tcomp.tl - the tlang compiler, written in tlang.
#
# Single pass: lex the source into token arrays, then walk the tokens emitting
# x86-64 assembly on stdout.  The compiler and language version together.
#
#   tcomp FILE.tl > FILE.s
#   tcomp --version
#   as --64 -mx86-used-note=no -o FILE.o FILE.s
#   ld -s -z noseparate-code --build-id=none -o FILE FILE.o

import "Runtime/version_gen.tl"

# ---------------------------------------------------------------- token kinds
let TK_EOF = 0
let TK_INT = 1
let TK_STR = 2
let TK_IDENT = 3
let TK_KW = 4
let TK_FLOAT = 5
let TK_LPAREN = 10
let TK_RPAREN = 11
let TK_LBRACE = 12
let TK_RBRACE = 13
let TK_LBRACKET = 14
let TK_RBRACKET = 15
let TK_COMMA = 16
let TK_DOT = 17
let TK_COLON = 18
let TK_ASSIGN = 19
let TK_EQ = 20
let TK_NE = 21
let TK_LT = 22
let TK_LE = 23
let TK_GT = 24
let TK_GE = 25
let TK_ANDAND = 26
let TK_OROR = 27
let TK_NOT = 28
let TK_SEMI = 29
let TK_PLUS = 30
let TK_MINUS = 31
let TK_STAR = 32
let TK_SLASH = 33
let TK_PERCENT = 34
let TK_ARROW = 35
let TK_PLUSEQ = 36
let TK_MINUSEQ = 37
let TK_STAREQ = 38
let TK_SLASHEQ = 39
let TK_PERCENTEQ = 40
let TK_DOTS = 41
let TK_AMP = 42
let TK_PIPE = 43
let TK_CARET = 44
let TK_SHL = 45
let TK_SHR = 46
let TK_TILDE = 47
let TK_AMPEQ = 48
let TK_PIPEEQ = 49
let TK_CARETEQ = 50
let TK_SHLEQ = 51
let TK_SHREQ = 52
let TK_INC = 53
let TK_DEC = 54
let TK_USHR = 55
let TK_USHREQ = 56

# ------------------------------------------------------------- keyword ids
let KW_FN = 1
let KW_LET = 2
let KW_IF = 3
let KW_ELSE = 4
let KW_WHILE = 5
let KW_RETURN = 6
let KW_BREAK = 7
let KW_CONTINUE = 8
let KW_TRUE = 9
let KW_FALSE = 10
let KW_STRUCT = 11
let KW_FOR = 12
let KW_IN = 13
let KW_SWITCH = 14
let KW_CASE = 15
let KW_DO = 16
let KW_LOOP = 17
let KW_CONST = 18

# ---------------------------------------------------------------- compiler state
let SRC = ""
let SRC_PATH = ""
let POS = 0
let LINE = 1
let TOK_POS = 0

let CAP = 60000
let NT = 0
let TI = 0
let TK = alloc(60000)
let TN = alloc(60000)
let TV = alloc(60000, str)
let TL = alloc(60000)
let TP = alloc(60000)

# symbol table (locals and globals share it; functions truncate back to BASE)
let NSYM = 0
let BASE = 0
let Y_NAME = alloc(20000, str)
let Y_SLOT = alloc(20000)
let Y_TYPE = alloc(20000, str)
let MARKS = alloc(2000)
let NMARK = 0
let GSLOT = 0
let GTYPE = ""

# Virtual line -> source file and real line, filled while imports are expanded.
let MAP_PATH = alloc(60000, str)
let MAP_LINE = alloc(60000)
let NMAP = 0

# struct table
let NSTRUCT = 0
let S_NAME = alloc(1000, str)
let S_FSTART = alloc(1000)
let S_FCOUNT = alloc(1000)
let NFIELD = 0
let F_NAME = alloc(8000, str)
let F_TYPE = alloc(8000, str)

# function table (return types of already-parsed functions)
let NFN = 0
let FN_NAME = alloc(4000, str)
let FN_RET = alloc(4000, str)
let FN_PBASE = alloc(4000)
let FN_NPARAM = alloc(4000)
let FN_PTYPE = alloc(24000, str)
let FN_POS = alloc(4000)
let FN_LINE = alloc(4000)
let NPARAM = 0

# Call sites, checked once every definition has been parsed.
let NCALLED = 0
let CALLED_NAME = alloc(20000, str)
let CALLED_POS = alloc(20000)
let CALLED_LINE = alloc(20000)

# code generation state
let SLOT = 0
let TS = 256
let LBL = 0
let CURFN = ""
let CUR_RET = ""
let CUR_INFER = ""
let NGLOB = 0
let NLOOP = 0
let LBREAK = alloc(500, str)
let LCONT = alloc(500, str)

# string literal pool (text already escaped for .ascii)
let NSTR = 0
let P_TEXT = alloc(20000, str)

# runtime usage flags
let U_PRINT = 0
let U_PRINT_ERR = 0
let U_PRINT_INT = 0
let U_PRINT_CHAR = 0
let U_ALLOC = 0
let U_APPEND = 0
let U_ITOA = 0
let U_FTOA = 0
let U_CONCAT = 0
let U_SLICE = 0
let U_STREQ = 0
let U_STRCMP = 0
let U_INT = 0
let U_INPUT = 0
let U_READFILE = 0
let U_FILESIZE = 0
let U_SOCK = 0
let U_FDREAD = 0
let U_FDWRITE = 0
let U_FDPOLL = 0
let U_FLOAT = 0
let U_PRINTFLOAT = 0

# decimal float literal scratch: mantissa and net power of ten
let FLT_M = 0
let FLT_E = 0
let U_NEWBUF = 0
let U_EXIT = 0
let U_LEN = 0
let U_ARGC = 0
let U_ARGV = 0
let U_ARENA_MARK = 0
let U_ARENA_RELEASE = 0
let U_WRITEFILE = 0
let U_SHM = 0
let U_FDPWRITE = 0
let U_FDSEND = 0
let U_APPENDFILE = 0
let U_FILEEXISTS = 0
let U_ENV = 0
let U_STROFFSET = 0
let U_STRDIFF = 0
let U_CLZ = 0
let U_RBIT = 0
let U_BSWAP16 = 0
let U_BSWAP32 = 0
let U_BSWAP64 = 0
let U_SEXT8 = 0
let U_SEXT16 = 0
let U_SEXT32 = 0
let U_UDIV = 0
let U_UMOD = 0
let U_ROL8 = 0
let U_ROR8 = 0
let U_LD8 = 0
let U_LD16 = 0
let U_LD32 = 0
let U_LD64 = 0
let U_ST8 = 0
let U_ST16 = 0
let U_ST32 = 0
let U_ST64 = 0
let U_MEMCPY = 0
let U_MEMSET = 0
let U_BOUNDS = 0
let NO_BOUNDS = 0
let NTAB = 0
let NTARGET = 0
let TAB_LABEL = alloc(32, str)
let TAB_BASE = alloc(32, int)
let TAB_COUNT = alloc(32, int)
let TAB_TARGET = alloc(4096, str)
# Freestanding mode: _start calls ENTRY_NAME and halts instead of exiting, the
# kernel runtime supplies print/alloc/exit, and kernel builtins are allowed.
let FREE_MODE = 0
let ENTRY_NAME = "main"

# Top-level names are collected before parsing, so a function may name a struct
# or a global declared later in the file.  The language does not require
# declaration order at top level, and stage 0 accepts both.
let PRE_NSTRUCT = 0
let PRE_SNAME = alloc(1000, str)
let PRE_SAT = alloc(1000)
let PRE_NGLOB = 0
let PRE_GNAME = alloc(4000, str)
let G_DEFINED = alloc(4000)

# Consts are literals with a name; every use emits the literal, so they need
# no storage.  The prescan collects them, which is what lets a function use a
# const declared further down the file.
let CON_N = 0
let CON_NAME = alloc(1000, str)
let CON_KIND = alloc(1000)      # 0 int, 1 string
let CON_IMM = alloc(1000)
let CON_LABEL = alloc(1000, str)
let CON_POS = alloc(1000)
let CON_LINE = alloc(1000)

# ---------------------------------------------------------------- output helpers
# The emitter writes one line at a time, but a comparison that feeds a branch is
# only visible as a sequence, so the last few lines wait in PB. Ten is exactly
# the window the peephole below needs.
let PB = alloc(16, str)
let NPB = 0

fn has_pre(s: str, pre: str) -> int {
  if len(s) < len(pre) {
    return 0
  }
  if str_eq(slice(s, 0, len(pre)), pre) == 1 {
    return 1
  }
  return 0
}

fn pb_out(s: str) {
  print(s)
  print("\n")
}

fn pb_shift(n: int) {
  let i = n
  while i < NPB {
    PB[i - n] = PB[i]
    i = i + 1
  }
  NPB = NPB - n
}

# `cmp a, b; setX al; movzx rax, al; test rax, rax; je L` asks one question in
# five instructions; the cmp already left the flags the branch needs. The setcc
# tail only exists so a comparison can also be a value, so when a branch reads it
# straight away the tail is dead. The jump is the setcc condition, inverted for
# `je` and unchanged for `jne`.
fn pb_drop(at: int) {
  let i = at
  while i < NPB - 1 {
    PB[i] = PB[i + 1]
    i = i + 1
  }
  NPB = NPB - 1
}

fn is_num(s: str) -> int {
  if len(s) == 0 {
    return 0
  }
  let i = 0
  if s[0] == 45 {
    if len(s) == 1 {
      return 0
    }
    i = 1
  }
  while i < len(s) {
    if s[i] < 48 || s[i] > 57 {
      return 0
    }
    i = i + 1
  }
  return 1
}

fn num_val(s: str) -> int {
  let i = 0
  let neg = 0
  if s[0] == 45 {
    neg = 1
    i = 1
  }
  let v = 0
  while i < len(s) {
    v = v * 10 + (s[i] - 48)
    i = i + 1
  }
  if neg == 1 {
    return 0 - v
  }
  return v
}

# cmp/add/sub/and/or/xor take a sign-extended 32-bit immediate, so a small
# constant can be the operand instead of a register holding it.
fn imm32(s: str) -> int {
  if is_num(s) == 0 || len(s) > 11 {
    return 0
  }
  let v = num_val(s)
  if v < 0 - 2147483647 - 1 {
    return 0
  }
  if v > 2147483647 {
    return 0
  }
  return 1
}

# Operands that stay valid when the load is retargeted from rax to rcx, and
# that do not depend on rsp, which the push/pop moved.
fn src_ok(s: str) -> int {
  if is_num(s) == 1 {
    return 1
  }
  if has_pre(s, "[rbp") == 1 || has_pre(s, "[rip") == 1 || has_pre(s, "[rax") == 1 {
    return 1
  }
  return 0
}

# rax is dead from line i when the lines up to the first one that is not a pop
# either write rax or are the call that returns into it.
fn kills_rax(s: str) -> int {
  if has_pre(s, "  call ") == 1 {
    return 1
  }
  if has_pre(s, "  mov rax, ") == 1 {
    return 1
  }
  if has_pre(s, "  lea rax, ") == 1 {
    return 1
  }
  if has_pre(s, "  movzx rax, ") == 1 {
    return 1
  }
  if has_pre(s, "  xor eax") == 1 {
    return 1
  }
  if has_pre(s, "  mov eax") == 1 {
    return 1
  }
  return 0
}

fn rax_dead(i: int) -> int {
  let k = i
  while k < NPB {
    if has_pre(PB[k], "  pop rax") == 1 {
      return 1
    }
    if has_pre(PB[k], "  pop ") == 1 {
      k = k + 1
    } else {
      return kills_rax(PB[k])
    }
  }
  return 0
}

# `mov/lea rax, SRC` followed by `push rax`: one argument, pushed for later.
# SRC must name no register an evaluation could change -- an immediate, or a
# slot addressed off rbp or rip -- so it can be re-read at the call site.
fn arg_pair(i: int) -> str {
  if i + 1 >= NPB {
    return ""
  }
  let op = ""
  if has_pre(PB[i], "  mov rax, ") == 1 {
    op = "mov"
  } else if has_pre(PB[i], "  lea rax, ") == 1 {
    op = "lea"
  } else {
    return ""
  }
  if str_eq(PB[i + 1], "  push rax") == 0 {
    return ""
  }
  let src = slice(PB[i], 11, len(PB[i]) - 11)
  if is_num(src) == 0 {
    if has_pre(src, "[rbp") == 0 {
      if has_pre(src, "[rip") == 0 {
        return ""
      }
    }
  }
  return op
}

# A call whose arguments are all plain loads does not need the stack at all.
# They go in left to right and come out right to left into the parameter
# registers, so `mov rax, A / push rax / mov rax, B / push rax / pop rsi /
# pop rdi / call f` is `mov rdi, A / mov rsi, B / call f`. Each value is
# re-materialised at the call site from a fixed base, and the pattern requires
# nothing to run between the pushes, so no load can be moved past a write.
# The pops must be in the parameter order, which is also what makes the
# registers distinct.
fn rule_args() -> int {
  let k = 0
  if str_eq(arg_pair(0), "") == 0 {
    k = 1
    if str_eq(arg_pair(2), "") == 0 {
      k = 2
      if str_eq(arg_pair(4), "") == 0 {
        k = 3
      }
    }
  }
  if k == 0 {
    return 0
  }
  if NPB < 3 * k + 1 {
    return 0
  }
  if k == 1 {
    if str_eq(PB[2], "  pop rdi") == 0 {
      return 0
    }
  }
  if k == 2 {
    if str_eq(PB[4], "  pop rsi") == 0 || str_eq(PB[5], "  pop rdi") == 0 {
      return 0
    }
  }
  if k == 3 {
    if str_eq(PB[6], "  pop rdx") == 0 || str_eq(PB[7], "  pop rsi") == 0 || str_eq(PB[8], "  pop rdi") == 0 {
      return 0
    }
  }
  if has_pre(PB[3 * k], "  call ") == 0 {
    return 0
  }
  let call_line = PB[3 * k]
  let j = 0
  while j < k {
    let src = slice(PB[2 * j], 11, len(PB[2 * j]) - 11)
    let pr = slice(PB[3 * k - 1 - j], 6, len(PB[3 * k - 1 - j]) - 6)
    PB[j] = "  " + arg_pair(2 * j) + " " + pr + ", " + src
    j = j + 1
  }
  PB[k] = call_line
  let t = 3 * k + 1
  let d = k + 1
  while t < NPB {
    PB[d] = PB[t]
    d = d + 1
    t = t + 1
  }
  NPB = d
  return 1
}


# `mov/lea rax, SRC / mov R, rax` with rax dead afterwards is `mov/lea R, SRC`:
# the copy is the only use of the loaded value, and it re-materialises the same
# operand one line later, when no write to the base can have happened yet.
fn rule_copy() -> int {
  if has_pre(PB[1], "  mov ") == 0 {
    return 0
  }
  if has_pre(PB[1], "  mov rax, ") == 1 || has_pre(PB[1], "  mov [") == 1 {
    return 0
  }
  if str_eq(slice(PB[1], len(PB[1]) - 5, 5), ", rax") == 0 {
    return 0
  }
  let r = slice(PB[1], 6, len(PB[1]) - 11)
  if reg_ok(r) == 0 {
    return 0
  }
  let op = ""
  if has_pre(PB[0], "  mov rax, ") == 1 {
    op = "mov"
  } else if has_pre(PB[0], "  lea rax, ") == 1 {
    op = "lea"
  } else {
    return 0
  }
  if rax_dead(2) == 0 {
    return 0
  }
  let src = slice(PB[0], 11, len(PB[0]) - 11)
  PB[0] = "  " + op + " " + r + ", " + src
  pb_drop(1)
  return 1
}

# `push rax / mov rax, SRC / mov rcx, rax / pop rax` is exactly `mov rcx, SRC`:
# rax is saved, clobbered and restored, so the only live effect is rcx.
fn rule_push_mov() -> int {
  if str_eq(PB[1], "  push rax") == 0 {
    return 0
  }
  if has_pre(PB[2], "  mov rax, ") == 0 {
    return 0
  }
  if str_eq(PB[3], "  mov rcx, rax") == 0 {
    return 0
  }
  if str_eq(PB[4], "  pop rax") == 0 {
    return 0
  }
  let src = slice(PB[2], 11, len(PB[2]) - 11)
  if src_ok(src) == 0 {
    return 0
  }
  PB[1] = "  mov rcx, " + src
  pb_drop(2)
  pb_drop(2)
  pb_drop(2)
  return 1
}

fn reg_ok(s: str) -> int {
  if str_eq(s, "rdi") == 1 || str_eq(s, "rsi") == 1 {
    return 1
  }
  if str_eq(s, "rdx") == 1 || str_eq(s, "rcx") == 1 {
    return 1
  }
  if str_eq(s, "rbx") == 1 || str_eq(s, "r8") == 1 || str_eq(s, "r9") == 1 {
    return 1
  }
  if str_eq(s, "r10") == 1 || str_eq(s, "r11") == 1 || str_eq(s, "r12") == 1 {
    return 1
  }
  if str_eq(s, "r13") == 1 || str_eq(s, "r14") == 1 || str_eq(s, "r15") == 1 {
    return 1
  }
  return 0
}

# A one-argument call is pushed and popped straight back out, and `push rax /
# pop R` is exactly `mov R, rax`: the store and the load cancel, neither touches
# the flags, and nothing runs between them that could observe rsp.
fn rule_push_pop() -> int {
  if str_eq(PB[0], "  push rax") == 0 {
    return 0
  }
  if has_pre(PB[1], "  pop ") == 0 {
    return 0
  }
  let r = slice(PB[1], 6, len(PB[1]) - 6)
  if str_eq(r, "rax") == 1 {
    pb_shift(2)
    return 1
  }
  if reg_ok(r) == 0 {
    return 0
  }
  PB[0] = "  mov " + r + ", rax"
  pb_drop(1)
  return 1
}

# The six operations that take a 32-bit immediate or a memory operand all print
# as `op rax, rcx` just before they are rewritten.
fn bin_op(s: str) -> str {
  if str_eq(s, "  cmp rax, rcx") == 1 {
    return "cmp"
  }
  if str_eq(s, "  add rax, rcx") == 1 {
    return "add"
  }
  if str_eq(s, "  sub rax, rcx") == 1 {
    return "sub"
  }
  if str_eq(s, "  and rax, rcx") == 1 {
    return "and"
  }
  if str_eq(s, "  or rax, rcx") == 1 {
    return "or"
  }
  if str_eq(s, "  xor rax, rcx") == 1 {
    return "xor"
  }
  return ""
}

# `mov rcx, K / op rax, rcx` is `op rax, K`. Weaving the constant in also leaves
# the compare as one instruction, which is what the branch rule then folds.
fn rule_imm_op() -> int {
  if has_pre(PB[0], "  mov rcx, ") == 0 {
    return 0
  }
  let k = slice(PB[0], 11, len(PB[0]) - 11)
  if imm32(k) == 0 {
    return 0
  }
  let op = bin_op(PB[1])
  if str_eq(op, "") == 1 {
    return 0
  }
  PB[0] = "  " + op + " rax, " + k
  pb_drop(1)
  return 1
}

# `mov rcx, [MEM] / op rax, rcx` is `op rax, [MEM]`: x86 allows one memory
# operand and rax is the register side here. Only rbp- and rip-relative
# operands are taken, so nothing ends up addressing rsp.
fn rule_mem_op() -> int {
  if has_pre(PB[0], "  mov rcx, [") == 0 {
    return 0
  }
  let mem = slice(PB[0], 11, len(PB[0]) - 11)
  if has_pre(mem, "[rbp") == 0 {
    if has_pre(mem, "[rip") == 0 {
      return 0
    }
  }
  let op = bin_op(PB[1])
  if str_eq(op, "") == 1 {
    return 0
  }
  PB[0] = "  " + op + " rax, " + mem
  pb_drop(1)
  return 1
}

fn rule_cmp_jcc() -> int {
  if has_pre(PB[0], "  cmp ") == 0 {
    return 0
  }
  if str_eq(PB[2], "  movzx rax, al") == 0 {
    return 0
  }
  if str_eq(PB[3], "  test rax, rax") == 0 {
    return 0
  }
  let jt = ""
  let jf = ""
  if str_eq(PB[1], "  sete al") == 1 {
    jt = "je"
    jf = "jne"
  } else if str_eq(PB[1], "  setne al") == 1 {
    jt = "jne"
    jf = "je"
  } else if str_eq(PB[1], "  setl al") == 1 {
    jt = "jl"
    jf = "jge"
  } else if str_eq(PB[1], "  setle al") == 1 {
    jt = "jle"
    jf = "jg"
  } else if str_eq(PB[1], "  setg al") == 1 {
    jt = "jg"
    jf = "jle"
  } else if str_eq(PB[1], "  setge al") == 1 {
    jt = "jge"
    jf = "jl"
  } else {
    return 0
  }
  let last = PB[4]
  if has_pre(last, "  je ") == 1 {
    pb_out(PB[0])
    pb_out("  " + jf + " " + slice(last, 5, len(last) - 5))
    pb_shift(5)
    return 1
  }
  if has_pre(last, "  jne ") == 1 {
    pb_out(PB[0])
    pb_out("  " + jt + " " + slice(last, 6, len(last) - 6))
    pb_shift(5)
    return 1
  }
  return 0
}

# A constant load is seven bytes (`48 c7 c0 imm32`); the 32-bit form is five and
# zero-extends, so rax still holds K for any K in [0, 2^32). Zero is two bytes as
# `xor eax, eax`: that sets flags where `mov` does not, but every branch in this
# output consumes flags that were set immediately before it, so nothing observes
# them.
fn norm(s: str) -> str {
  if has_pre(s, "  mov rax, ") == 0 {
    return s
  }
  let v = slice(s, 11, len(s) - 11)
  if is_num(v) == 0 {
    return s
  }
  let n = num_val(v)
  if n == 0 {
    return "  xor eax, eax"
  }
  if n < 0 || n > 4294967295 {
    return s
  }
  return "  mov eax, " + n
}

# An unconditional jump makes the next line unreachable.  This is emitted by
# `if` whose then-branch already returns: the branch's `jmp .Lret` is followed
# by the jump past the else arm.
fn rule_dead_jmp() -> int {
  if has_pre(PB[0], "  jmp ") == 0 {
    return 0
  }
  if has_pre(PB[1], "  jmp ") == 0 {
    return 0
  }
  pb_drop(1)
  return 1
}

fn peep() {
  if rule_dead_jmp() == 1 {
    return
  }
  if rule_args() == 1 {
    return
  }
  if rule_copy() == 1 {
    return
  }
  if rule_push_pop() == 1 {
    return
  }
  if rule_push_mov() == 1 {
    return
  }
  if rule_mem_op() == 1 {
    return
  }
  if rule_imm_op() == 1 {
    return
  }
  if rule_cmp_jcc() == 1 {
    return
  }
  pb_out(norm(PB[0]))
  pb_shift(1)
}

fn e(s: str) {
  while NPB > 0 {
    pb_out(norm(PB[0]))
    pb_shift(1)
  }
  print(s)
}

fn el(s: str) {
  PB[NPB] = s
  NPB = NPB + 1
  if NPB >= 10 {
    peep()
  }
}

fn rr(s: int) -> str {
  return "[rbp-" + (8 * (s + 1)) + "]"
}

fn gslot(g: int) -> str {
  return "[rip + G" + g + "]"
}

fn loc(s: int) -> str {
  if s < 0 {
    return gslot(0 - s - 1)
  }
  return rr(s)
}

fn st(s: int) {
  el("  mov " + loc(s) + ", rax")
}

fn ld(s: int) {
  el("  mov rax, " + loc(s))
}

fn tmp() -> int {
  if TS >= 512 {
    print_err("tcomp: function needs too many temporaries\n")
    exit(1)
  }
  TS = TS + 1
  return TS - 1
}

fn rt() {
  TS = 256
}

fn newl() -> str {
  LBL = LBL + 1
  return "L" + LBL
}

fn slot() -> int {
  if SLOT >= 256 {
    print_err("tcomp: function needs too many locals\n")
    exit(1)
  }
  SLOT = SLOT + 1
  return SLOT - 1
}

fn col_at(p: int) -> int {
  let i = p
  let n = 0
  while i > 0 && SRC[i - 1] != 10 {
    i = i - 1
    n = n + 1
  }
  return n + 1
}

# Errors use the same `file:line:col: error: message` form as the bootstrap
# compiler. Columns are computed from the token's source offset on demand.
fn err_at(msg: str, p: int, ln: int) {
  let path = SRC_PATH
  let line = ln
  if ln > 0 && ln <= NMAP {
    path = MAP_PATH[ln]
    line = MAP_LINE[ln]
  }
  print_err(path + ":" + str(line) + ":" + str(col_at(p)) + ": error: " + msg + "\n")
  exit(1)
}

fn err(msg: str) {
  if TI >= NT {
    err_at(msg, len(SRC), LINE)
  } else {
    err_at(msg, TP[TI], TL[TI])
  }
}

# Loop entries are saved in fixed arrays, so nesting depth has a limit.
fn push_loop(end: str, cont: str) {
  if NLOOP >= 500 {
    err("loops nested too deeply")
  }
  LBREAK[NLOOP] = end
  LCONT[NLOOP] = cont
  NLOOP = NLOOP + 1
}

# ---------------------------------------------------------------- char classes
fn is_digit(c: int) -> int {
  if c >= 48 && c <= 57 {
    return 1
  }
  return 0
}

fn is_alpha(c: int) -> int {
  if c >= 65 && c <= 90 {
    return 1
  }
  if c >= 97 && c <= 122 {
    return 1
  }
  if c == 95 {
    return 1
  }
  return 0
}

fn is_alnum(c: int) -> int {
  if is_alpha(c) == 1 {
    return 1
  }
  return is_digit(c)
}

fn is_hex(c: int) -> int {
  if is_digit(c) == 1 {
    return 1
  }
  if c >= 97 && c <= 102 {
    return 1
  }
  if c >= 65 && c <= 70 {
    return 1
  }
  return 0
}

fn hexval(c: int) -> int {
  if c >= 48 && c <= 57 {
    return c - 48
  }
  if c >= 97 && c <= 102 {
    return c - 87
  }
  return c - 55
}

# Parse a decimal float literal into FLT_M * 10**FLT_E. Parsing at compile
# time keeps both compilers independent of a host language's float parser.
fn float_parts(t: str) {
  let i = 0
  let n = len(t)
  let m = 0
  let frac = 0
  let dot = 0
  while i < n {
    let c = t[i]
    if c == 46 {
      dot = 1
    } else if c == 101 || c == 69 {
      i = i + 1
      let esign = 1
      if i < n && (t[i] == 43 || t[i] == 45) {
        if t[i] == 45 {
          esign = 0 - 1
        }
        i = i + 1
      }
      let e = 0
      while i < n {
        if is_digit(t[i]) == 1 {
          e = e * 10 + (t[i] - 48)
        }
        i = i + 1
      }
      FLT_M = m
      FLT_E = esign * e - frac
      return
    } else if is_digit(c) == 1 {
      m = m * 10 + (c - 48)
      if dot == 1 {
        frac = frac + 1
      }
    }
    i = i + 1
  }
  FLT_M = m
  FLT_E = 0 - frac
}

# ---------------------------------------------------------------- lexer
fn push_tok(k: int, num: int, txt: str, ln: int) {
  if NT >= CAP {
    err_at("too many tokens", POS, LINE)
  }
  TK[NT] = k
  TN[NT] = num
  TV[NT] = txt
  TL[NT] = ln
  TP[NT] = TOK_POS
  NT = NT + 1
}

fn last_term() -> int {
  if NT == 0 {
    return 0
  }
  let k = TK[NT - 1]
  if k == TK_INT || k == TK_FLOAT {
    return 1
  }
  if k == TK_STR {
    return 1
  }
  if k == TK_IDENT {
    return 1
  }
  if k == TK_RPAREN {
    return 1
  }
  if k == TK_RBRACKET {
    return 1
  }
  if k == TK_RBRACE {
    return 1
  }
  if k == TK_INC || k == TK_DEC {
    return 1
  }
  if k == TK_KW {
    let w = TN[NT - 1]
    if w == KW_RETURN || w == KW_BREAK || w == KW_CONTINUE {
      return 1
    }
    if w == KW_TRUE || w == KW_FALSE {
      return 1
    }
  }
  return 0
}

fn lx_newline() {
  TOK_POS = POS
  if last_term() == 1 {
    push_tok(TK_SEMI, 0, "", LINE)
  }
  POS = POS + 1
  LINE = LINE + 1
}

fn lx_comment() {
  while POS < len(SRC) {
    if SRC[POS] == 10 {
      return
    }
    POS = POS + 1
  }
}

fn lx_number() {
  TOK_POS = POS
  let start = POS
  let base = 10
  if SRC[POS] == 48 && POS + 1 < len(SRC) {
    let d = SRC[POS + 1]
    if d == 120 || d == 88 {
      base = 16
      POS = POS + 2
    } else if d == 98 || d == 66 {
      base = 2
      POS = POS + 2
    }
  }
  let val = 0
  if base != 10 {
    while POS < len(SRC) {
      let c = SRC[POS]
      if c == 95 {
        POS = POS + 1
      } else if base == 16 {
        if is_hex(c) == 0 {
          break
        }
        val = val * 16 + hexval(c)
        POS = POS + 1
      } else {
        if c != 48 && c != 49 {
          break
        }
        val = val * 2 + (c - 48)
        POS = POS + 1
      }
    }
    push_tok(TK_INT, val, "", LINE)
    return
  }
  while POS < len(SRC) {
    let c = SRC[POS]
    if c == 95 {
      POS = POS + 1
    } else if is_digit(c) == 1 {
      val = val * 10 + (c - 48)
      POS = POS + 1
    } else {
      break
    }
  }
  let isf = 0
  if POS < len(SRC) && SRC[POS] == 46 && POS + 1 < len(SRC) && is_digit(SRC[POS + 1]) == 1 {
    isf = 1
    POS = POS + 1
    while POS < len(SRC) {
      let c = SRC[POS]
      if c == 95 {
        POS = POS + 1
      } else if is_digit(c) == 1 {
        POS = POS + 1
      } else {
        break
      }
    }
  }
  if POS < len(SRC) && (SRC[POS] == 101 || SRC[POS] == 69) {
    let k = 1
    if POS + k < len(SRC) && (SRC[POS + k] == 43 || SRC[POS + k] == 45) {
      k = k + 1
    }
    if POS + k < len(SRC) && is_digit(SRC[POS + k]) == 1 {
      isf = 1
      POS = POS + 1
      if SRC[POS] == 43 || SRC[POS] == 45 {
        POS = POS + 1
      }
      while POS < len(SRC) && is_digit(SRC[POS]) == 1 {
        POS = POS + 1
      }
    }
  }
  if isf == 0 {
    push_tok(TK_INT, val, "", LINE)
    return
  }
  let txt = slice(SRC, start, POS - start)
  float_parts(txt)
  push_tok(TK_FLOAT, FLT_M, str(FLT_E), LINE)
}

# One whole UTF-8 character starting at p, so a diagnostic can quote a
# non-ASCII byte without cutting it in half.
fn utf8_at(p: int) -> str {
  let c = SRC[p]
  let n = 1
  if c >= 240 {
    n = 4
  } else if c >= 224 {
    n = 3
  } else if c >= 192 {
    n = 2
  }
  if p + n > len(SRC) {
    n = 1
  }
  return slice(SRC, p, n)
}

fn esc_known(c: int) -> int {
  if c == 110 || c == 116 || c == 114 || c == 92 || c == 34 || c == 39 || c == 48 || c == 101 {
    return 1
  }
  return 0
}

fn hexv(c: int) -> int {
  if c >= 48 && c <= 57 {
    return c - 48
  }
  if c >= 97 && c <= 102 {
    return c - 87
  }
  if c >= 65 && c <= 70 {
    return c - 55
  }
  return -1
}

# The byte spelled by the two hex digits at `at`, or -1.  \xNN is the one
# escape whose length is not fixed at two characters, so the lexer and the
# assembler escaping both come through here.
fn esc_byte(s: str, at: int) -> int {
  if at + 1 >= len(s) {
    return -1
  }
  let hi = hexv(s[at])
  let lo = hexv(s[at + 1])
  if hi < 0 || lo < 0 {
    return -1
  }
  return hi * 16 + lo
}

fn oct3(v: int) -> str {
  return str(v / 64) + str((v / 8) % 8) + str(v % 8)
}

fn lx_string() {
  TOK_POS = POS
  let start = POS
  let sline = LINE
  POS = POS + 1
  while POS < len(SRC) {
    let c = SRC[POS]
    if c == 92 {
      if POS + 1 >= len(SRC) {
        err_at("unterminated string literal", start, sline)
      }
      if SRC[POS + 1] == 120 {
        if esc_byte(SRC, POS + 2) < 0 {
          err_at("\\x needs two hex digits", POS + 2, sline)
        }
        POS = POS + 4
      } else {
        if esc_known(SRC[POS + 1]) == 0 {
          err_at("unknown escape '\\" + slice(SRC, POS + 1, 1) + "'", POS + 2, sline)
        }
        POS = POS + 2
      }
    } else if c == 34 {
      break
    } else if c == 10 {
      err_at("unterminated string literal", POS, sline)
    } else {
      POS = POS + 1
    }
  }
  if POS >= len(SRC) {
    err_at("unterminated string literal", POS, sline)
  }
  let txt = slice(SRC, start + 1, POS - start - 1)
  POS = POS + 1
  push_tok(TK_STR, 0, txt, sline)
}

fn esc_val(c: int) -> int {
  if c == 110 {
    return 10
  }
  if c == 116 {
    return 9
  }
  if c == 114 {
    return 13
  }
  if c == 92 {
    return 92
  }
  if c == 34 {
    return 34
  }
  if c == 39 {
    return 39
  }
  if c == 48 {
    return 0
  }
  if c == 101 {
    return 27
  }
  return c
}

fn lx_char() {
  TOK_POS = POS
  let start = POS
  let sline = LINE
  POS = POS + 1
  if POS >= len(SRC) {
    err_at("unterminated character literal", start, sline)
  }
  let v = 0
  if SRC[POS] == 92 {
    if POS + 1 >= len(SRC) {
      err_at("unterminated character literal", start, sline)
    }
    if SRC[POS + 1] == 120 {
      v = esc_byte(SRC, POS + 2)
      if v < 0 {
        err_at("\\x needs two hex digits", POS + 2, sline)
      }
      POS = POS + 4
    } else {
      if esc_known(SRC[POS + 1]) == 0 {
        err_at("unknown escape '\\" + slice(SRC, POS + 1, 1) + "'", POS + 2, sline)
      }
      v = esc_val(SRC[POS + 1])
      POS = POS + 2
    }
  } else {
    if SRC[POS] == 10 {
      err_at("unterminated character literal", start, sline)
    }
    v = SRC[POS]
    POS = POS + 1
  }
  if POS >= len(SRC) || SRC[POS] != 39 {
    err_at("character literal must hold exactly one character", POS, sline)
  }
  POS = POS + 1
  push_tok(TK_INT, v, "", sline)
}

fn kw_of(w: str) -> int {
  if str_eq(w, "fn") == 1 {
    return KW_FN
  }
  if str_eq(w, "const") == 1 {
    return KW_CONST
  }
  if str_eq(w, "let") == 1 {
    return KW_LET
  }
  if str_eq(w, "if") == 1 {
    return KW_IF
  }
  if str_eq(w, "else") == 1 {
    return KW_ELSE
  }
  if str_eq(w, "while") == 1 {
    return KW_WHILE
  }
  if str_eq(w, "return") == 1 {
    return KW_RETURN
  }
  if str_eq(w, "break") == 1 {
    return KW_BREAK
  }
  if str_eq(w, "continue") == 1 {
    return KW_CONTINUE
  }
  if str_eq(w, "true") == 1 {
    return KW_TRUE
  }
  if str_eq(w, "false") == 1 {
    return KW_FALSE
  }
  if str_eq(w, "struct") == 1 {
    return KW_STRUCT
  }
  if str_eq(w, "for") == 1 {
    return KW_FOR
  }
  if str_eq(w, "in") == 1 {
    return KW_IN
  }
  if str_eq(w, "switch") == 1 {
    return KW_SWITCH
  }
  if str_eq(w, "case") == 1 {
    return KW_CASE
  }
  if str_eq(w, "do") == 1 {
    return KW_DO
  }
  if str_eq(w, "loop") == 1 {
    return KW_LOOP
  }
  return 0
}

fn lx_word() {
  TOK_POS = POS
  let start = POS
  while POS < len(SRC) {
    if is_alnum(SRC[POS]) == 0 {
      break
    }
    POS = POS + 1
  }
  let w = slice(SRC, start, POS - start)
  let k = kw_of(w)
  if k == 0 {
    push_tok(TK_IDENT, 0, w, LINE)
  } else {
    push_tok(TK_KW, k, w, LINE)
  }
}

fn lx_punct() {
  TOK_POS = POS
  let c = SRC[POS]
  let d = 0
  if POS + 1 < len(SRC) {
    d = SRC[POS + 1]
  }
  let e = 0
  if POS + 2 < len(SRC) {
    e = SRC[POS + 2]
  }
  if c == 43 && d == 43 {
    push_tok(TK_INC, 0, "", LINE)
    POS = POS + 2
    return
  }
  if c == 45 && d == 45 {
    push_tok(TK_DEC, 0, "", LINE)
    POS = POS + 2
    return
  }
  if c == 60 && d == 60 && e == 61 {
    push_tok(TK_SHLEQ, 0, "", LINE)
    POS = POS + 3
    return
  }
  if c == 62 && d == 62 && e == 61 {
    push_tok(TK_SHREQ, 0, "", LINE)
    POS = POS + 3
    return
  }
  if c == 62 && d == 62 && e == 62 && POS + 3 < len(SRC) && SRC[POS + 3] == 61 {
    push_tok(TK_USHREQ, 0, "", LINE)
    POS = POS + 4
    return
  }
  if c == 62 && d == 62 && e == 62 {
    push_tok(TK_USHR, 0, "", LINE)
    POS = POS + 3
    return
  }
  if c == 61 && d == 61 {
    push_tok(TK_EQ, 0, "", LINE)
    POS = POS + 2
    return
  }
  if c == 33 && d == 61 {
    push_tok(TK_NE, 0, "", LINE)
    POS = POS + 2
    return
  }
  if c == 60 && d == 61 {
    push_tok(TK_LE, 0, "", LINE)
    POS = POS + 2
    return
  }
  if c == 62 && d == 61 {
    push_tok(TK_GE, 0, "", LINE)
    POS = POS + 2
    return
  }
  if c == 38 && d == 38 {
    push_tok(TK_ANDAND, 0, "", LINE)
    POS = POS + 2
    return
  }
  if c == 124 && d == 124 {
    push_tok(TK_OROR, 0, "", LINE)
    POS = POS + 2
    return
  }
  if c == 45 && d == 62 {
    push_tok(TK_ARROW, 0, "", LINE)
    POS = POS + 2
    return
  }
  if c == 43 && d == 61 {
    push_tok(TK_PLUSEQ, 0, "", LINE)
    POS = POS + 2
    return
  }
  if c == 45 && d == 61 {
    push_tok(TK_MINUSEQ, 0, "", LINE)
    POS = POS + 2
    return
  }
  if c == 42 && d == 61 {
    push_tok(TK_STAREQ, 0, "", LINE)
    POS = POS + 2
    return
  }
  if c == 47 && d == 61 {
    push_tok(TK_SLASHEQ, 0, "", LINE)
    POS = POS + 2
    return
  }
  if c == 37 && d == 61 {
    push_tok(TK_PERCENTEQ, 0, "", LINE)
    POS = POS + 2
    return
  }
  if c == 46 && d == 46 {
    push_tok(TK_DOTS, 0, "", LINE)
    POS = POS + 2
    return
  }
  if c == 38 && d == 61 {
    push_tok(TK_AMPEQ, 0, "", LINE)
    POS = POS + 2
    return
  }
  if c == 124 && d == 61 {
    push_tok(TK_PIPEEQ, 0, "", LINE)
    POS = POS + 2
    return
  }
  if c == 94 && d == 61 {
    push_tok(TK_CARETEQ, 0, "", LINE)
    POS = POS + 2
    return
  }
  if c == 60 && d == 60 {
    push_tok(TK_SHL, 0, "", LINE)
    POS = POS + 2
    return
  }
  if c == 62 && d == 62 {
    push_tok(TK_SHR, 0, "", LINE)
    POS = POS + 2
    return
  }
  let k = 0
  if c == 40 {
    k = TK_LPAREN
  } else if c == 41 {
    k = TK_RPAREN
  } else if c == 123 {
    k = TK_LBRACE
  } else if c == 125 {
    k = TK_RBRACE
  } else if c == 91 {
    k = TK_LBRACKET
  } else if c == 93 {
    k = TK_RBRACKET
  } else if c == 44 {
    k = TK_COMMA
  } else if c == 46 {
    k = TK_DOT
  } else if c == 58 {
    k = TK_COLON
  } else if c == 61 {
    k = TK_ASSIGN
  } else if c == 60 {
    k = TK_LT
  } else if c == 62 {
    k = TK_GT
  } else if c == 33 {
    k = TK_NOT
  } else if c == 59 {
    k = TK_SEMI
  } else if c == 43 {
    k = TK_PLUS
  } else if c == 45 {
    k = TK_MINUS
  } else if c == 42 {
    k = TK_STAR
  } else if c == 47 {
    k = TK_SLASH
  } else if c == 37 {
    k = TK_PERCENT
  } else if c == 38 {
    k = TK_AMP
  } else if c == 124 {
    k = TK_PIPE
  } else if c == 94 {
    k = TK_CARET
  } else if c == 126 {
    k = TK_TILDE
  }
  if k == 0 {
    err_at("unexpected character '" + utf8_at(POS) + "'", POS, LINE)
  }
  push_tok(k, 0, "", LINE)
  POS = POS + 1
}

fn lx_block_comment() {
  let start = POS
  let sline = LINE
  TOK_POS = POS
  POS = POS + 2
  while POS < len(SRC) {
    if SRC[POS] == 42 && POS + 1 < len(SRC) && SRC[POS + 1] == 47 {
      POS = POS + 2
      return
    }
    if SRC[POS] == 10 {
      if last_term() == 1 {
        push_tok(TK_SEMI, 0, "", LINE)
      }
      LINE = LINE + 1
    }
    POS = POS + 1
  }
  err_at("unterminated block comment", start, sline)
}

fn lex_all() {
  POS = 0
  LINE = 1
  NT = 0
  while POS < len(SRC) {
    let c = SRC[POS]
    if c == 32 || c == 9 || c == 13 {
      POS = POS + 1
    } else if c == 10 {
      lx_newline()
    } else if c == 35 {
      lx_comment()
    } else if c == 47 && POS + 1 < len(SRC) && SRC[POS + 1] == 47 {
      lx_comment()
    } else if c == 47 && POS + 1 < len(SRC) && SRC[POS + 1] == 42 {
      lx_block_comment()
    } else if is_digit(c) == 1 {
      lx_number()
    } else if c == 34 {
      lx_string()
    } else if c == 39 {
      lx_char()
    } else if is_alpha(c) == 1 {
      lx_word()
    } else {
      lx_punct()
    }
  }
  TOK_POS = POS
  if last_term() == 1 {
    push_tok(TK_SEMI, 0, "", LINE)
  }
  push_tok(TK_EOF, 0, "", LINE)
}

# ---------------------------------------------------------------- symbol table
fn declare(name: str, s: int, t: str) {
  if NSYM >= 20000 {
    err("too many variables")
  }
  Y_NAME[NSYM] = name
  Y_SLOT[NSYM] = s
  Y_TYPE[NSYM] = t
  NSYM = NSYM + 1
}

fn lookup(name: str) -> int {
  let i = NSYM - 1
  while i >= 0 {
    if str_eq(Y_NAME[i], name) == 1 {
      GSLOT = Y_SLOT[i]
      GTYPE = Y_TYPE[i]
      return 1
    }
    i = i - 1
  }
  return 0
}

fn set_type(name: str, t: str) {
  let i = NSYM - 1
  while i >= 0 {
    if str_eq(Y_NAME[i], name) == 1 {
      Y_TYPE[i] = t
      return
    }
    i = i - 1
  }
}

fn sym_type(name: str) -> str {
  let i = NSYM - 1
  while i >= 0 {
    if str_eq(Y_NAME[i], name) == 1 {
      return Y_TYPE[i]
    }
    i = i - 1
  }
  return ""
}

# ---------------------------------------------------------------- struct table
fn struct_find(name: str) -> int {
  let i = 0
  while i < NSTRUCT {
    if str_eq(S_NAME[i], name) == 1 {
      return i
    }
    i = i + 1
  }
  return -1
}

fn field_index(s: int, f: str) -> int {
  let i = 0
  while i < S_FCOUNT[s] {
    if str_eq(F_NAME[S_FSTART[s] + i], f) == 1 {
      return i
    }
    i = i + 1
  }
  return -1
}

fn has_arr_prefix(t: str) -> int {
  if len(t) < 6 {
    return 0
  }
  return str_eq(slice(t, 0, 6), "arr_of")
}

fn elem_of(t: str) -> str {
  return slice(t, 7, len(t) - 7)
}

fn is_ptr_type(t: str) -> int {
  if str_eq(t, "ptr") == 1 || str_eq(t, "arr") == 1 || has_arr_prefix(t) == 1 {
    return 1
  }
  if t != "" && struct_find(t) >= 0 {
    return 1
  }
  return 0
}

# `int[]` in an annotation means "array of int" internally (arr_of:int).
fn norm_type(t: str) -> str {
  if len(t) > 2 {
    if str_eq(slice(t, len(t) - 2, 2), "[]") == 1 {
      return "arr_of:" + slice(t, 0, len(t) - 2)
    }
  }
  return t
}

# ---------------------------------------------------------------- fn table
fn fn_find(name: str) -> int {
  let i = 0
  while i < NFN {
    if str_eq(FN_NAME[i], name) == 1 {
      return i
    }
    i = i + 1
  }
  return -1
}

fn note_call(name: str, p: int, ln: int) {
  if NCALLED >= 20000 {
    err_at("too many function calls", p, ln)
  }
  CALLED_NAME[NCALLED] = name
  CALLED_POS[NCALLED] = p
  CALLED_LINE[NCALLED] = ln
  NCALLED = NCALLED + 1
}

fn fn_ret(name: str) -> str {
  let i = fn_find(name)
  if i < 0 {
    return ""
  }
  return FN_RET[i]
}

# ---------------------------------------------------------------- parser helpers
fn cur_is(k: int) -> int {
  if TK[TI] == k {
    return 1
  }
  return 0
}

fn cur_kw(w: int) -> int {
  if TK[TI] == TK_KW && TN[TI] == w {
    return 1
  }
  return 0
}

fn adv() {
  TI = TI + 1
}

fn kw_text(w: int) -> str {
  if w == KW_FN {
    return "fn"
  }
  if w == KW_LET {
    return "let"
  }
  if w == KW_IF {
    return "if"
  }
  if w == KW_ELSE {
    return "else"
  }
  if w == KW_WHILE {
    return "while"
  }
  if w == KW_RETURN {
    return "return"
  }
  if w == KW_BREAK {
    return "break"
  }
  if w == KW_CONTINUE {
    return "continue"
  }
  if w == KW_TRUE {
    return "true"
  }
  if w == KW_FALSE {
    return "false"
  }
  if w == KW_STRUCT {
    return "struct"
  }
  if w == KW_FOR {
    return "for"
  }
  if w == KW_IN {
    return "in"
  }
  if w == KW_SWITCH {
    return "switch"
  }
  if w == KW_CASE {
    return "case"
  }
  if w == KW_DO {
    return "do"
  }
  if w == KW_LOOP {
    return "loop"
  }
  return "const"
}

fn tok_sym(k: int) -> str {
  if k == TK_LPAREN {
    return "("
  }
  if k == TK_RPAREN {
    return ")"
  }
  if k == TK_LBRACE {
    return "{"
  }
  if k == TK_RBRACE {
    return "}"
  }
  if k == TK_LBRACKET {
    return "["
  }
  if k == TK_RBRACKET {
    return "]"
  }
  if k == TK_COMMA {
    return ","
  }
  if k == TK_DOT {
    return "."
  }
  if k == TK_COLON {
    return ":"
  }
  if k == TK_ASSIGN {
    return "="
  }
  if k == TK_EQ {
    return "=="
  }
  if k == TK_NE {
    return "!="
  }
  if k == TK_LT {
    return "<"
  }
  if k == TK_LE {
    return "<="
  }
  if k == TK_GT {
    return ">"
  }
  if k == TK_GE {
    return ">="
  }
  if k == TK_ANDAND {
    return "&&"
  }
  if k == TK_OROR {
    return "||"
  }
  if k == TK_NOT {
    return "!"
  }
  if k == TK_SEMI {
    return ";"
  }
  if k == TK_PLUS {
    return "+"
  }
  if k == TK_MINUS {
    return "-"
  }
  if k == TK_STAR {
    return "*"
  }
  if k == TK_SLASH {
    return "/"
  }
  if k == TK_PERCENT {
    return "%"
  }
  if k == TK_ARROW {
    return "->"
  }
  if k == TK_PLUSEQ {
    return "+="
  }
  if k == TK_MINUSEQ {
    return "-="
  }
  if k == TK_STAREQ {
    return "*="
  }
  if k == TK_SLASHEQ {
    return "/="
  }
  if k == TK_PERCENTEQ {
    return "%="
  }
  if k == TK_DOTS {
    return ".."
  }
  if k == TK_AMP {
    return "&"
  }
  if k == TK_PIPE {
    return "|"
  }
  if k == TK_CARET {
    return "^"
  }
  if k == TK_SHL {
    return "<<"
  }
  if k == TK_SHR {
    return ">>"
  }
  if k == TK_TILDE {
    return "~"
  }
  if k == TK_AMPEQ {
    return "&="
  }
  if k == TK_PIPEEQ {
    return "|="
  }
  if k == TK_CARETEQ {
    return "^="
  }
  if k == TK_SHLEQ {
    return "<<="
  }
  if k == TK_SHREQ {
    return ">>="
  }
  if k == TK_USHR {
    return ">>>"
  }
  if k == TK_USHREQ {
    return ">>>="
  }
  if k == TK_INC {
    return "++"
  }
  return "--"
}

# The token at i as the other compiler's parser describes it, so both report
# `expected WHAT, found WHAT` for the same mistake.
fn describe(i: int) -> str {
  if i >= NT {
    return "end of file"
  }
  let k = TK[i]
  if k == TK_EOF {
    return "end of file"
  }
  if k == TK_KW {
    return "'" + kw_text(TN[i]) + "'"
  }
  if k == TK_IDENT {
    return "identifier '" + TV[i] + "'"
  }
  if k == TK_INT {
    return "number " + TN[i]
  }
  if k == TK_FLOAT {
    return "floating-point literal"
  }
  if k == TK_STR {
    return "string literal"
  }
  return "'" + tok_sym(k) + "'"
}

fn expect(k: int) {
  if TK[TI] != k {
    err("expected '" + tok_sym(k) + "', found " + describe(TI))
  }
  TI = TI + 1
}

fn skip_semis() {
  while TK[TI] == TK_SEMI {
    TI = TI + 1
  }
}

fn type_word(t: str) -> str {
  if t == "" {
    return "unknown"
  }
  if has_arr_prefix(t) == 1 {
    return elem_of(t) + "[]"
  }
  if str_eq(t, "ptr") == 1 || str_eq(t, "arr") == 1 {
    return "array"
  }
  return t
}

# The compatibility rule and the assembly runtime are generated from one
# definition each; these imports are placed after the helpers they use.
import "Runtime/runtime_gen.tl"
import "Runtime/kinds_gen.tl"
import "Runtime/builtins_gen.tl"
import "Runtime/builtins_dispatch_gen.tl"

fn bump(name: str, up: int) {
  if lookup(name) == 0 {
    if const_find(name) >= 0 {
      err("cannot assign to const '" + name + "'")
    }
    err("unknown variable '" + name + "'")
  }
  if GTYPE == "str" {
    err("cannot increment a string")
  }
  if is_ptr_type(GTYPE) == 1 {
    if up == 1 {
      el("  add qword ptr " + loc(GSLOT) + ", 8")
    } else {
      el("  sub qword ptr " + loc(GSLOT) + ", 8")
    }
    return
  }
  if GTYPE == "float" {
    el("  mov rdi, " + loc(GSLOT))
    el("  mov rsi, 4607182418800017408")
    if up == 1 {
      el("  call __t_fadd")
    } else {
      el("  call __t_fsub")
    }
    U_FLOAT = 1
    st(GSLOT)
    return
  }
  if up == 1 {
    el("  add qword ptr " + loc(GSLOT) + ", 1")
  } else {
    el("  sub qword ptr " + loc(GSLOT) + ", 1")
  }
}

fn is_compound(k: int) -> int {
  if k >= TK_PLUSEQ && k <= TK_PERCENTEQ {
    return 1
  }
  if k >= TK_AMPEQ && k <= TK_SHREQ {
    return 1
  }
  if k == TK_USHREQ {
    return 1
  }
  return 0
}

fn is_assignment() -> int {
  let i = TI
  let depth = 0
  while i < NT {
    let k = TK[i]
    if k == TK_EOF {
      return 0
    }
    if k == TK_LPAREN || k == TK_LBRACKET {
      depth = depth + 1
    } else if k == TK_RPAREN || k == TK_RBRACKET {
      depth = depth - 1
    } else if k == TK_ASSIGN && depth == 0 {
      return 1
    } else if is_compound(k) == 1 && depth == 0 {
      return 1
    } else if k == TK_SEMI && depth <= 0 {
      return 0
    }
    i = i + 1
  }
  return 0
}

# ---------------------------------------------------------------- string pool
fn asm_esc(raw: str) -> str {
  let out = ""
  let i = 0
  let n = len(raw)
  while i < n {
    let c = raw[i]
    if c == 92 {
      i = i + 1
      let x = raw[i]
      if x == 120 {
        out = out + "\\" + oct3(esc_byte(raw, i + 1))
        i = i + 2
      } else if x == 101 {
        out = out + "\\033"
      } else if x == 110 {
        out = out + "\\n"
      } else if x == 116 {
        out = out + "\\t"
      } else if x == 114 {
        out = out + "\\r"
      } else if x == 92 {
        out = out + "\\\\"
      } else if x == 34 {
        out = out + "\\\""
      } else if x == 48 {
        out = out + "\\000"
      } else {
        out = out + slice(raw, i, 1)
      }
    } else {
      out = out + slice(raw, i, 1)
    }
    i = i + 1
  }
  return out
}

fn intern(raw: str) -> str {
  let txt = asm_esc(raw)
  let i = 1
  while i <= NSTR {
    if str_eq(P_TEXT[i], txt) == 1 {
      return "S" + i
    }
    i = i + 1
  }
  if NSTR >= 19999 {
    err("too many string literals")
  }
  NSTR = NSTR + 1
  P_TEXT[NSTR] = txt
  return "S" + NSTR
}

# ---------------------------------------------------------------- expressions
# Same precedence as C: || && | ^ & == != < <= > >= << >> + - * / %
fn bin_level(k: int) -> int {
  if k == TK_OROR {
    return 1
  }
  if k == TK_ANDAND {
    return 2
  }
  if k == TK_PIPE {
    return 3
  }
  if k == TK_CARET {
    return 4
  }
  if k == TK_AMP {
    return 5
  }
  if k == TK_EQ || k == TK_NE {
    return 6
  }
  if k == TK_LT || k == TK_LE || k == TK_GT || k == TK_GE {
    return 7
  }
  if k == TK_SHL || k == TK_SHR || k == TK_USHR {
    return 8
  }
  if k == TK_PLUS || k == TK_MINUS {
    return 9
  }
  if k == TK_STAR || k == TK_SLASH || k == TK_PERCENT {
    return 10
  }
  return 0
}

fn expr() {
  parse_bin(1)
}

fn parse_bin(level: int) {
  if level > 10 {
    parse_unary()
    return
  }
  parse_bin(level + 1)
  let lt = GTYPE
  while bin_level(TK[TI]) == level {
    let op = TK[TI]
    if op == TK_ANDAND || op == TK_OROR {
      let l = newl()
      el("  test rax, rax")
      if op == TK_ANDAND {
        el("  je " + l + "f")
      } else {
        el("  jne " + l + "f")
      }
      adv()
      parse_bin(level + 1)
      el("  test rax, rax")
      if op == TK_ANDAND {
        el("  je " + l + "f")
        el("  mov rax, 1")
      } else {
        el("  jne " + l + "f")
        el("  mov rax, 0")
      }
      el("  jmp " + l + "e")
      el(l + "f:")
      if op == TK_ANDAND {
        el("  mov rax, 0")
      } else {
        el("  mov rax, 1")
      }
      el(l + "e:")
      GTYPE = "int"
    } else {
      adv()
      el("  push rax")
      parse_bin(level + 1)
      emit_bin(op, lt)
      lt = GTYPE
    }
  }
}

fn emit_bin(op: int, lt: str) {
  let rcx = "  mov rcx, rax"
  if op == TK_PLUS && (lt == "str" || GTYPE == "str") {
    if lt == "float" || GTYPE == "float" {
      err("cannot concatenate a float to a string")
    }
    el(rcx)
    el("  pop rax")
    if lt == "int" {
      el("  push rcx")
      el("  mov rdi, rax")
      el("  call __t_itoa")
      el("  pop rcx")
      U_ITOA = 1
    }
    if GTYPE == "int" {
      el("  push rax")
      el("  mov rdi, rcx")
      el("  call __t_itoa")
      el("  mov rcx, rax")
      el("  pop rax")
      U_ITOA = 1
    }
    el("  mov rdi, rax")
    el("  mov rsi, rcx")
    el("  call __t_concat")
    U_CONCAT = 1
    GTYPE = "str"
    return
  }
  if (op == TK_EQ || op == TK_NE) && lt == "str" && GTYPE == "str" {
    el("  mov rsi, rax")
    el("  pop rdi")
    el("  call __t_str_eq")
    if op == TK_NE {
      el("  test rax, rax")
      el("  sete al")
      el("  movzx rax, al")
    }
    U_STREQ = 1
    GTYPE = "int"
    return
  }
  if (op == TK_LT || op == TK_LE || op == TK_GT || op == TK_GE) && lt == "str" && GTYPE == "str" {
    el("  mov rsi, rax")
    el("  pop rdi")
    el("  call __t_str_cmp")
    el("  cmp rax, 0")
    if op == TK_LT {
      el("  setl al")
    } else if op == TK_LE {
      el("  setle al")
    } else if op == TK_GT {
      el("  setg al")
    } else {
      el("  setge al")
    }
    el("  movzx rax, al")
    U_STRCMP = 1
    GTYPE = "int"
    return
  }
  if lt == "float" || GTYPE == "float" {
    emit_float_bin(op, lt)
    return
  }
  if (op == TK_PLUS || op == TK_MINUS) && is_ptr_type(lt) == 1 && (GTYPE == "" || GTYPE == "int") {
    el(rcx)
    el("  pop rax")
    el("  shl rcx, 3")
    if op == TK_PLUS {
      el("  add rax, rcx")
    } else {
      el("  sub rax, rcx")
    }
    GTYPE = "ptr"
    return
  }
  if op == TK_PLUS && (lt == "" || lt == "int") && is_ptr_type(GTYPE) == 1 {
    let rt = GTYPE
    el(rcx)
    el("  pop rax")
    el("  shl rax, 3")
    el("  add rax, rcx")
    GTYPE = "ptr"
    return
  }
  if op == TK_MINUS && is_ptr_type(lt) == 1 && is_ptr_type(GTYPE) == 1 {
    el(rcx)
    el("  pop rax")
    el("  sub rax, rcx")
    el("  sar rax, 3")
    GTYPE = "int"
    return
  }
  # Shifts and bitwise operators have no string meaning; a pointer operand is
  # always a mistake, so report it instead of silently masking the address.
  if (op == TK_PERCENT || op == TK_AMP || op == TK_PIPE || op == TK_CARET || op == TK_SHL || op == TK_SHR || op == TK_USHR) && (lt == "str" || GTYPE == "str") {
    err("cannot use '" + bin_op_text(op) + "' on strings")
  }
  el(rcx)
  el("  pop rax")
  if op == TK_PLUS {
    el("  add rax, rcx")
  } else if op == TK_MINUS {
    el("  sub rax, rcx")
  } else if op == TK_STAR {
    el("  imul rax, rcx")
  } else if op == TK_SLASH {
    el("  cqo")
    el("  idiv rcx")
  } else if op == TK_PERCENT {
    el("  cqo")
    el("  idiv rcx")
    el("  mov rax, rdx")
  } else if op == TK_EQ {
    el("  cmp rax, rcx")
    el("  sete al")
    el("  movzx rax, al")
  } else if op == TK_NE {
    el("  cmp rax, rcx")
    el("  setne al")
    el("  movzx rax, al")
  } else if op == TK_LT {
    el("  cmp rax, rcx")
    el("  setl al")
    el("  movzx rax, al")
  } else if op == TK_LE {
    el("  cmp rax, rcx")
    el("  setle al")
    el("  movzx rax, al")
  } else if op == TK_GT {
    el("  cmp rax, rcx")
    el("  setg al")
    el("  movzx rax, al")
  } else if op == TK_GE {
    el("  cmp rax, rcx")
    el("  setge al")
    el("  movzx rax, al")
  } else if op == TK_AMP {
    el("  and rax, rcx")
  } else if op == TK_PIPE {
    el("  or rax, rcx")
  } else if op == TK_CARET {
    el("  xor rax, rcx")
  } else if op == TK_SHL {
    el("  shl rax, cl")
  } else if op == TK_SHR {
    el("  sar rax, cl")
  } else if op == TK_USHR {
    el("  shr rax, cl")
  } else {
    err("unknown operator")
  }
  GTYPE = "int"
}

fn emit_float_bin(op: int, lt: str) {
  if lt == "str" || GTYPE == "str" {
    err("cannot convert str to a float")
  }
  if op == TK_PERCENT || op == TK_AMP || op == TK_PIPE || op == TK_CARET || op == TK_SHL || op == TK_SHR || op == TK_USHR {
    err("cannot use '" + bin_op_text(op) + "' on floats")
  }
  if lt == "int" {
    el("  mov rcx, rax")
    el("  pop rax")
    el("  mov rdi, rax")
    el("  call __t_itof")
    el("  mov rdi, rax")
    el("  mov rsi, rcx")
  } else {
    if GTYPE == "int" {
      el("  mov rdi, rax")
      el("  call __t_itof")
    }
    el("  mov rcx, rax")
    el("  pop rax")
    el("  mov rdi, rax")
    el("  mov rsi, rcx")
  }
  U_FLOAT = 1
  if op == TK_PLUS {
    el("  movq xmm0, rdi")
    el("  movq xmm1, rsi")
    el("  addsd xmm0, xmm1")
    el("  movq rax, xmm0")
    GTYPE = "float"
    return
  }
  if op == TK_MINUS {
    el("  movq xmm0, rdi")
    el("  movq xmm1, rsi")
    el("  subsd xmm0, xmm1")
    el("  movq rax, xmm0")
    GTYPE = "float"
    return
  }
  if op == TK_STAR {
    el("  movq xmm0, rdi")
    el("  movq xmm1, rsi")
    el("  mulsd xmm0, xmm1")
    el("  movq rax, xmm0")
    GTYPE = "float"
    return
  }
  if op == TK_SLASH {
    el("  movq xmm0, rdi")
    el("  movq xmm1, rsi")
    el("  divsd xmm0, xmm1")
    el("  movq rax, xmm0")
    GTYPE = "float"
    return
  }
  if op == TK_EQ {
    el("  call __t_fcmp")
    el("  cmp rax, 0")
    el("  sete al")
    el("  movzx rax, al")
    GTYPE = "int"
    return
  }
  if op == TK_NE {
    el("  call __t_fcmp")
    el("  cmp rax, 0")
    el("  setne al")
    el("  movzx rax, al")
    GTYPE = "int"
    return
  }
  if op == TK_LT {
    el("  call __t_fcmp")
    el("  cmp rax, -1")
    el("  sete al")
    el("  movzx rax, al")
    GTYPE = "int"
    return
  }
  if op == TK_LE {
    el("  call __t_fcmp")
    el("  cmp rax, 0")
    el("  setle al")
    el("  movzx rax, al")
    GTYPE = "int"
    return
  }
  if op == TK_GT {
    el("  call __t_fcmp")
    el("  cmp rax, 1")
    el("  sete al")
    el("  movzx rax, al")
    GTYPE = "int"
    return
  }
  if op == TK_GE {
    el("  call __t_fcmp")
    el("  cmp rax, 2")
    el("  sete cl")
    el("  movzx rcx, cl")
    el("  cmp rax, 0")
    el("  setge al")
    el("  movzx rax, al")
    el("  xor rax, rcx")
    GTYPE = "int"
    return
  }
  err("unknown float operator")
}

fn emit_index_check_array() {
  if NO_BOUNDS == 1 {
    return
  }
  let bad = newl()
  let good = newl()
  el("  test rcx, rcx")
  el("  js " + bad)
  el("  mov r8, [rax - 8]")
  el("  cmp rcx, r8")
  el("  jb " + good)
  el(bad + ":")
  el("  call __t_bounds_fail")
  U_BOUNDS = 1
  el(good + ":")
}

# Strings have no length header, so only the lower bound is checked: an
# upper-bound check would need a strlen on every byte access, and writing at
# strlen(s) is how NUL-terminated buffers grow.
fn emit_index_check_string() {
  if NO_BOUNDS == 1 {
    return
  }
  let good = newl()
  el("  test rcx, rcx")
  el("  jns " + good)
  el("  call __t_bounds_fail")
  U_BOUNDS = 1
  el(good + ":")
}

fn parse_unary() {
  if cur_is(TK_MINUS) == 1 {
    adv()
    parse_unary()
    if GTYPE == "float" {
      el("  mov rdi, rax")
      el("  call __t_fneg")
      U_FLOAT = 1
      return
    }
    if GTYPE == "str" {
      err("cannot use unary '-' on a string")
    }
    el("  neg rax")
    GTYPE = "int"
    return
  }
  if cur_is(TK_NOT) == 1 {
    adv()
    parse_unary()
    if GTYPE == "float" {
      err("cannot use unary '!' on a float")
    }
    el("  test rax, rax")
    el("  sete al")
    el("  movzx rax, al")
    GTYPE = "int"
    return
  }
  if cur_is(TK_TILDE) == 1 {
    adv()
    parse_unary()
    if GTYPE == "float" {
      err("cannot use unary '~' on a float")
    }
    if GTYPE == "str" {
      err("cannot use unary '~' on a string")
    }
    el("  not rax")
    GTYPE = "int"
    return
  }
  parse_postfix()
}

fn parse_postfix() {
  parse_primary()
  while 1 {
    if cur_is(TK_LBRACKET) == 1 {
      adv()
      let bt = GTYPE
      el("  push rax")
      expr()
      el("  mov rcx, rax")
      el("  pop rax")
      if bt == "str" {
        emit_index_check_string()
        el("  movzx rax, byte ptr [rax + rcx]")
        GTYPE = "int"
      } else {
        if bt == "arr" || has_arr_prefix(bt) == 1 {
          emit_index_check_array()
        }
        el("  mov rax, [rax + rcx*8]")
        if has_arr_prefix(bt) == 1 {
          GTYPE = elem_of(bt)
        } else {
          GTYPE = "int"
        }
      }
      expect(TK_RBRACKET)
    } else if cur_is(TK_DOT) == 1 {
      adv()
      let fname = TV[TI]
      adv()
      let sidx = struct_find(GTYPE)
      if sidx < 0 {
        err("cannot read field '" + fname + "' of " + type_article(GTYPE))
      }
      let fi = field_index(sidx, fname)
      if fi < 0 {
        err("struct '" + GTYPE + "' has no field '" + fname + "'")
      }
      el("  mov rax, [rax + " + (8 * fi) + "]")
      GTYPE = F_TYPE[S_FSTART[sidx] + fi]
    } else {
      return
    }
  }
}

fn parse_primary() {
  if cur_is(TK_INT) == 1 {
    el("  mov rax, " + TN[TI])
    adv()
    GTYPE = "int"
    return
  }
  if cur_is(TK_FLOAT) == 1 {
    let m = TN[TI]
    let e = int(TV[TI])
    adv()
    el("  mov rdi, " + m)
    el("  mov rsi, " + e)
    el("  call __t_fconst")
    U_FLOAT = 1
    GTYPE = "float"
    return
  }
  if cur_is(TK_STR) == 1 {
    let lb = intern(TV[TI])
    el("  lea rax, [rip + " + lb + "]")
    adv()
    GTYPE = "str"
    return
  }
  if cur_is(TK_LPAREN) == 1 {
    adv()
    expr()
    expect(TK_RPAREN)
    return
  }
  if cur_is(TK_LBRACKET) == 1 {
    parse_array()
    return
  }
  if cur_kw(KW_TRUE) == 1 {
    el("  mov rax, 1")
    adv()
    GTYPE = "int"
    return
  }
  if cur_kw(KW_FALSE) == 1 {
    el("  mov rax, 0")
    adv()
    GTYPE = "int"
    return
  }
  if cur_is(TK_IDENT) == 1 {
    let name = TV[TI]
    let namepos = TP[TI]
    let nameline = TL[TI]
    adv()
    if cur_is(TK_LPAREN) == 1 {
      parse_call(name, namepos, nameline)
      return
    }
    if lookup(name) == 1 {
      ld(GSLOT)
      return
    }
    let ci = const_find(name)
    if ci >= 0 {
      if CON_KIND[ci] == 0 {
        el("  mov rax, " + str(CON_IMM[ci]))
        GTYPE = "int"
      } else {
        el("  lea rax, [rip + " + CON_LABEL[ci] + "]")
        GTYPE = "str"
      }
      return
    }
    err("unknown variable '" + name + "'")
    return
  }
  err("expected an expression, found " + describe(TI))
}

fn array_count() -> int {
  let i = TI + 1
  let depth = 0
  let n = 0
  if TK[i] == TK_RBRACKET {
    return 0
  }
  n = 1
  while i < NT {
    let k = TK[i]
    if k == TK_EOF {
      return n
    }
    if k == TK_LPAREN || k == TK_LBRACKET || k == TK_LBRACE {
      depth = depth + 1
    } else if k == TK_RPAREN || k == TK_RBRACE {
      depth = depth - 1
    } else if k == TK_RBRACKET {
      if depth == 0 {
        return n
      }
      depth = depth - 1
    } else if k == TK_COMMA && depth == 0 {
      n = n + 1
    }
    i = i + 1
  }
  return n
}

fn parse_array() {
  let n = array_count()
  adv()
  let t = tmp()
  el("  mov rdi, " + n)
  el("  call __t_alloc")
  el("  mov " + loc(t) + ", rax")
  U_ALLOC = 1
  let i = 0
  let elem = ""
  while cur_is(TK_RBRACKET) == 0 {
    if i > 0 {
      expect(TK_COMMA)
    }
    expr()
    if i == 0 {
      elem = GTYPE
    } else if str_eq(elem, GTYPE) == 0 {
      elem = ""
    }
    el("  mov rdx, rax")
    el("  mov rax, " + loc(t))
    el("  mov [rax + " + (8 * i) + "], rdx")
    i = i + 1
  }
  expect(TK_RBRACKET)
  el("  mov rax, " + loc(t))
  # A literal with one element kind is typed, so for-each and append know
  # what its slots hold; a mixed literal stays untyped.
  GTYPE = "arr"
  if i > 0 {
    if str_eq(elem, "int") == 1 || str_eq(elem, "str") == 1 || str_eq(elem, "float") == 1 || struct_find(elem) >= 0 {
      GTYPE = "arr_of:" + elem
    }
  }
}

fn call_reg(i: int) -> str {
  if i == 0 {
    return "rdi"
  }
  if i == 1 {
    return "rsi"
  }
  if i == 2 {
    return "rdx"
  }
  if i == 3 {
    return "rcx"
  }
  if i == 4 {
    return "r8"
  }
  return "r9"
}

fn parse_call(name: str, namepos: int, nameline: int) {
  if struct_find(name) >= 0 {
    parse_construct(name)
    return
  }
  let b = builtin_kind(name)
  if b != 0 {
    parse_builtin(name, b)
    return
  }
  let fi = fn_find(name)
  note_call(name, namepos, nameline)
  adv()
  let n = 0
  while cur_is(TK_RPAREN) == 0 {
    expr()
    if fi >= 0 && n < FN_NPARAM[fi] {
      let want = FN_PTYPE[FN_PBASE[fi] + n]
      if types_ok(want, GTYPE) == 0 {
        err("function '" + name + "' argument " + (n + 1) + " should be " + type_word(want) + ", got " + type_word(GTYPE))
      }
    }
    el("  push rax")
    n = n + 1
    if cur_is(TK_COMMA) == 1 {
      adv()
    } else {
      break
    }
  }
  expect(TK_RPAREN)
  if n > 6 {
    err("too many arguments")
  }
  if fi >= 0 && n != FN_NPARAM[fi] {
    err("function '" + name + "' takes " + FN_NPARAM[fi] + " argument(s), got " + n)
  }
  let i = n - 1
  while i >= 0 {
    el("  pop " + call_reg(i))
    i = i - 1
  }
  el("  call .Lfn_" + name)
  GTYPE = fn_ret(name)
}

fn parse_construct(name: str) {
  adv()
  let sidx = struct_find(name)
  let count = S_FCOUNT[sidx]
  let t = tmp()
  el("  mov rdi, " + count)
  el("  call __t_alloc")
  el("  mov " + loc(t) + ", rax")
  U_ALLOC = 1
  let i = 0
  while cur_is(TK_RPAREN) == 0 {
    if i > 0 {
      expect(TK_COMMA)
    }
    expr()
    el("  mov rdx, rax")
    el("  mov rax, " + loc(t))
    el("  mov [rax + " + (8 * i) + "], rdx")
    i = i + 1
  }
  expect(TK_RPAREN)
  if i != count {
    err("struct '" + name + "' has " + count + " field(s), got " + i)
  }
  el("  mov rax, " + loc(t))
  GTYPE = name
}

# Count the arguments of a call whose opening parenthesis was just consumed.
# This scans tokens without parsing them, so it emits no code.  It is used by
# the generated builtin dispatch to report the same "got N" arity diagnostic as
# stage 0, including the number the caller actually wrote.
fn call_arg_count() -> int {
  if cur_is(TK_RPAREN) == 1 { return 0 }
  let depth = 0
  let n = 1
  let i = TI
  while TK[i] != TK_EOF {
    let t = TK[i]
    if t == TK_LPAREN || t == TK_LBRACKET || t == TK_LBRACE {
      depth = depth + 1
    } else {
      if t == TK_RPAREN {
        if depth == 0 { return n }
        depth = depth - 1
      } else {
        if t == TK_RBRACKET || t == TK_RBRACE {
          depth = depth - 1
        } else {
          if t == TK_COMMA && depth == 0 { n = n + 1 }
        }
      }
    }
    i = i + 1
  }
  return n
}

fn one_arg(name: str) {
  adv()
  if cur_is(TK_RPAREN) == 1 {
    err(name + "() takes 1 argument(s), got 0")
  }
  expr()
  if cur_is(TK_COMMA) == 1 {
    adv()
    if cur_is(TK_RPAREN) == 1 {
      expr()
    }
    let extra = 1
    while cur_is(TK_RPAREN) == 0 {
      expr()
      extra = extra + 1
      if cur_is(TK_COMMA) == 1 {
        adv()
        if cur_is(TK_RPAREN) == 1 {
          expr()
        }
      } else {
        break
      }
    }
    expect(TK_RPAREN)
    err(name + "() takes 1 argument(s), got " + extra)
  }
  expect(TK_RPAREN)
}

# Two integer arguments, the shape shared by the unsigned arithmetic and
# rotate builtins.  Both values are parked in frame slots before the ABI
# registers are loaded, so evaluating the second cannot clobber the first.
fn two_int_args(name: str) {
  adv()
  let t0 = tmp()
  expr()
  if GTYPE != "" && GTYPE != "int" {
    err(arg_msg(name, 1, "int"))
  }
  st(t0)
  expect(TK_COMMA)
  let t1 = tmp()
  expr()
  if GTYPE != "" && GTYPE != "int" {
    err(arg_msg(name, 2, "int"))
  }
  st(t1)
  expect(TK_RPAREN)
  el("  mov rdi, " + loc(t0))
  el("  mov rsi, " + loc(t1))
}

# Two/three typed arguments for the memory builtins.  Values are parked in
# frame slots before the ABI registers are loaded so later expressions cannot
# clobber earlier ones.
fn parse_args2(name: str, k0: str, k1: str) {
  adv()
  let t0 = tmp()
  expr()
  if GTYPE != "" && GTYPE != k0 {
    err(arg_msg(name, 1, k0))
  }
  st(t0)
  expect(TK_COMMA)
  let t1 = tmp()
  expr()
  if GTYPE != "" && GTYPE != k1 {
    err(arg_msg(name, 2, k1))
  }
  st(t1)
  expect(TK_RPAREN)
  el("  mov rdi, " + loc(t0))
  el("  mov rsi, " + loc(t1))
}

fn parse_args3(name: str, k0: str, k1: str, k2: str) {
  adv()
  let t0 = tmp()
  expr()
  if GTYPE != "" && GTYPE != k0 {
    err(arg_msg(name, 1, k0))
  }
  st(t0)
  expect(TK_COMMA)
  let t1 = tmp()
  expr()
  if GTYPE != "" && GTYPE != k1 {
    err(arg_msg(name, 2, k1))
  }
  st(t1)
  expect(TK_COMMA)
  let t2 = tmp()
  expr()
  if GTYPE != "" && GTYPE != k2 {
    err(arg_msg(name, 3, k2))
  }
  st(t2)
  expect(TK_RPAREN)
  el("  mov rdi, " + loc(t0))
  el("  mov rsi, " + loc(t1))
  el("  mov rdx, " + loc(t2))
}

# Machine builtins take up to six arguments, like a tlang call, and return an
# integer.  Their arity and argument kinds come from the generated table, so a
# new builtin needs no change here; the stub __k_<name> lives in the kernel
# runtime.
fn parse_machine(name: str, arity: int) {
  adv()
  let slots = alloc(6, str)
  let i = 0
  while i < arity {
    if i > 0 {
      expect(TK_COMMA)
    }
    let t = tmp()
    expr()
    let want = builtin_arg(name, i)
    if types_ok(want, GTYPE) == 0 {
      err(name + "() argument " + (i + 1) + " should be " + want +
          ", got " + type_word(GTYPE))
    }
    st(t)
    slots[i] = loc(t)
    i = i + 1
  }
  expect(TK_RPAREN)
  if arity >= 1 { el("  mov rdi, " + slots[0]) }
  if arity >= 2 { el("  mov rsi, " + slots[1]) }
  if arity >= 3 { el("  mov rdx, " + slots[2]) }
  if arity >= 4 { el("  mov rcx, " + slots[3]) }
  if arity >= 5 { el("  mov r8, " + slots[4]) }
  if arity >= 6 { el("  mov r9, " + slots[5]) }
  el("  call __k_" + name)
  GTYPE = "int"
}

fn arg_msg(name: str, n: int, want: str) -> str {
  return name + "() argument " + n + " should be " + want + ", got " + type_word(GTYPE)
}

fn parse_builtin(name: str, kind: int) {
  if builtin_kernel(name) == 1 {
    if FREE_MODE == 0 {
      err(name + "() is a kernel builtin; build with --freestanding")
    }
    parse_machine(name, builtin_arity(name))
    return
  }
  if builtin_hosted(name) == 1 && FREE_MODE == 1 {
    err(name + "() needs a hosted Linux program, so it is not available with --freestanding")
  }
  if kind == 1 {
    one_arg(name)
    if GTYPE != "" && GTYPE != "int" && GTYPE != "str" {
      err(arg_msg("print", 1, "str or int"))
    }
    if GTYPE == "int" {
      el("  mov rdi, rax")
      el("  call __t_itoa")
      U_ITOA = 1
      GTYPE = "str"
    }
    el("  mov rdi, rax")
    el("  call __t_print")
    U_PRINT = 1
    GTYPE = "int"
    return
  }
  if kind == 2 {
    one_arg(name)
    if GTYPE != "" && GTYPE != "int" && GTYPE != "str" {
      err(arg_msg("print_err", 1, "str or int"))
    }
    if GTYPE == "int" {
      el("  mov rdi, rax")
      el("  call __t_itoa")
      U_ITOA = 1
      GTYPE = "str"
    }
    el("  mov rdi, rax")
    el("  call __t_print_err")
    U_PRINT_ERR = 1
    GTYPE = "int"
    return
  }
  if kind == 3 {
    one_arg(name)
    if GTYPE != "" && GTYPE != "int" {
      err(arg_msg("print_int", 1, "int"))
    }
    el("  mov rdi, rax")
    el("  call __t_print_int")
    U_PRINT_INT = 1
    GTYPE = "int"
    return
  }
  if kind == 4 {
    one_arg(name)
    if GTYPE != "" && GTYPE != "int" {
      err(arg_msg("print_char", 1, "int"))
    }
    el("  mov rdi, rax")
    el("  call __t_print_char")
    U_PRINT_CHAR = 1
    GTYPE = "int"
    return
  }
  if kind == 5 {
    adv()
    expect(TK_RPAREN)
    el("  call __t_input")
    U_INPUT = 1
    GTYPE = "str"
    return
  }
  if kind == 6 {
    one_arg(name)
    if GTYPE == "float" {
      el("  mov rdi, rax")
      el("  call __t_ftoi")
      U_FLOAT = 1
      GTYPE = "int"
      return
    }
    if GTYPE != "" && GTYPE != "str" {
      err(arg_msg("int", 1, "str or float"))
    }
    el("  mov rdi, rax")
    el("  call __t_int")
    U_INT = 1
    GTYPE = "int"
    return
  }
  if kind == 7 {
    one_arg(name)
    if GTYPE == "float" {
      el("  mov rdi, rax")
      el("  call __t_ftoa")
      U_FTOA = 1
      GTYPE = "str"
      return
    }
    if GTYPE != "" && GTYPE != "int" {
      err(arg_msg("str", 1, "int or float"))
    }
    el("  mov rdi, rax")
    el("  call __t_itoa")
    U_ITOA = 1
    GTYPE = "str"
    return
  }
  if kind == 8 {
    adv()
    if cur_is(TK_RPAREN) == 1 {
      err("len() takes exactly one argument")
    }
    expr()
    if cur_is(TK_COMMA) == 1 {
      adv()
      if cur_is(TK_RPAREN) == 1 {
        expr()
      }
      err("len() takes exactly one argument")
    }
    expect(TK_RPAREN)
    if GTYPE == "str" {
      el("  mov rdi, rax")
      el("  call __t_strlen")
      U_LEN = 1
      GTYPE = "int"
      return
    }
    if GTYPE == "arr" || GTYPE == "ptr" || has_arr_prefix(GTYPE) == 1 {
      el("  mov rax, [rax - 8]")
      GTYPE = "int"
      return
    }
    err("len() needs a string or an array")
  }
  if kind == 9 {
    adv()
    let t0 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" {
      err(arg_msg("slice", 1, "str"))
    }
    st(t0)
    expect(TK_COMMA)
    let t1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" {
      err(arg_msg("slice", 2, "int"))
    }
    st(t1)
    expect(TK_COMMA)
    let t2 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" {
      err(arg_msg("slice", 3, "int"))
    }
    st(t2)
    expect(TK_RPAREN)
    el("  mov rdi, " + loc(t0))
    el("  mov rsi, " + loc(t1))
    el("  mov rdx, " + loc(t2))
    el("  call __t_slice")
    U_SLICE = 1
    GTYPE = "str"
    return
  }
  if kind == 10 {
    adv()
    let t0 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" {
      err(arg_msg("str_eq", 1, "str"))
    }
    st(t0)
    expect(TK_COMMA)
    let t1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" {
      err(arg_msg("str_eq", 2, "str"))
    }
    st(t1)
    expect(TK_RPAREN)
    el("  mov rdi, " + loc(t0))
    el("  mov rsi, " + loc(t1))
    el("  call __t_str_eq")
    U_STREQ = 1
    GTYPE = "int"
    return
  }
  if kind == 11 {
    adv()
    let t = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" {
      err(arg_msg("alloc", 1, "int"))
    }
    st(t)
    if cur_is(TK_COMMA) == 1 {
      adv()
      if cur_is(TK_IDENT) == 0 {
        err("alloc() takes 1 argument(s), got 2")
      }
      let tname = TV[TI]
      adv()
      if str_eq(tname, "int") == 0 && str_eq(tname, "str") == 0 && str_eq(tname, "float") == 0 && struct_find(tname) < 0 {
        err("unknown type '" + tname + "'")
      }
      expect(TK_RPAREN)
      el("  mov rdi, " + loc(t))
      el("  call __t_alloc")
      U_ALLOC = 1
      if str_eq(tname, "str") == 1 {
        GTYPE = "arr_of:str"
      } else {
        GTYPE = "arr_of:" + tname
      }
      return
    }
    expect(TK_RPAREN)
    el("  mov rdi, " + loc(t))
    el("  call __t_alloc")
    U_ALLOC = 1
    GTYPE = "arr"
    return
  }
  if kind == 12 {
    one_arg(name)
    if GTYPE != "" && GTYPE != "str" {
      err(arg_msg("read_file", 1, "str"))
    }
    el("  mov rdi, rax")
    el("  call __t_read_file")
    U_READFILE = 1
    GTYPE = "str"
    return
  }
  if kind == 13 {
    one_arg(name)
    if GTYPE != "" && GTYPE != "int" {
      err(arg_msg("argv", 1, "int"))
    }
    el("  mov rdi, rax")
    el("  call __t_argv")
    U_ARGV = 1
    GTYPE = "str"
    return
  }
  if kind == 14 {
    adv()
    expect(TK_RPAREN)
    el("  call __t_argc")
    U_ARGC = 1
    GTYPE = "int"
    return
  }
  if kind == 16 {
    adv()
    let t0 = tmp()
    expr()
    st(t0)
    let ty = GTYPE
    if ty != "ptr" && ty != "arr" && has_arr_prefix(ty) == 0 {
      err("append() needs an array")
    }
    expect(TK_COMMA)
    let t1 = tmp()
    expr()
    if has_arr_prefix(ty) == 1 {
      let elem = elem_of(ty)
      if types_ok(elem, GTYPE) == 0 {
        err("cannot append " + type_word(GTYPE) + " to " + type_word(ty))
      }
    }
    st(t1)
    expect(TK_RPAREN)
    el("  mov rdi, " + loc(t0))
    el("  mov rsi, " + loc(t1))
    el("  call __t_append")
    U_APPEND = 1
    GTYPE = ty
    return
  }
  if kind == 17 {
    one_arg(name)
    if GTYPE != "" && GTYPE != "str" {
      err(arg_msg("file_size", 1, "str"))
    }
    el("  mov rdi, rax")
    el("  call __t_file_size")
    U_FILESIZE = 1
    GTYPE = "int"
    return
  }
  if kind == 18 {
    one_arg(name)
    if GTYPE != "" && GTYPE != "str" {
      err(arg_msg("sock", 1, "str"))
    }
    el("  mov rdi, rax")
    el("  call __t_sock_unix")
    U_SOCK = 1
    GTYPE = "int"
    return
  }
  if kind == 19 {
    adv()
    let a0 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" { err(arg_msg("fd_read", 1, "int")) }
    st(a0)
    expect(TK_COMMA)
    let a1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" { err(arg_msg("fd_read", 2, "str")) }
    st(a1)
    expect(TK_COMMA)
    let a2 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" { err(arg_msg("fd_read", 3, "int")) }
    st(a2)
    expect(TK_RPAREN)
    el("  mov rdi, " + loc(a0))
    el("  mov rsi, " + loc(a1))
    el("  mov rdx, " + loc(a2))
    el("  call __t_fd_read")
    U_FDREAD = 1
    GTYPE = "int"
    return
  }
  if kind == 20 {
    adv()
    let b0 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" { err(arg_msg("fd_write", 1, "int")) }
    st(b0)
    expect(TK_COMMA)
    let b1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" { err(arg_msg("fd_write", 2, "str")) }
    st(b1)
    expect(TK_COMMA)
    let b2 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" { err(arg_msg("fd_write", 3, "int")) }
    st(b2)
    expect(TK_RPAREN)
    el("  mov rdi, " + loc(b0))
    el("  mov rsi, " + loc(b1))
    el("  mov rdx, " + loc(b2))
    el("  call __t_fd_write")
    U_FDWRITE = 1
    GTYPE = "int"
    return
  }
  if kind == 21 {
    adv()
    let p0 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" { err(arg_msg("fd_poll", 1, "int")) }
    st(p0)
    expect(TK_COMMA)
    let p1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" { err(arg_msg("fd_poll", 2, "int")) }
    st(p1)
    expect(TK_RPAREN)
    el("  mov rdi, " + loc(p0))
    el("  mov rsi, " + loc(p1))
    el("  call __t_fd_poll")
    U_FDPOLL = 1
    GTYPE = "int"
    return
  }
  if kind == 35 {
    adv()
    let s0 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" {
      err(arg_msg("str_offset", 1, "str"))
    }
    st(s0)
    expect(TK_COMMA)
    let s1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" {
      err(arg_msg("str_offset", 2, "int"))
    }
    st(s1)
    expect(TK_RPAREN)
    el("  mov rdi, " + loc(s0))
    el("  mov rsi, " + loc(s1))
    el("  call __t_str_offset")
    U_STROFFSET = 1
    GTYPE = "str"
    return
  }
  if kind == 36 {
    adv()
    let d0 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" {
      err(arg_msg("str_diff", 1, "str"))
    }
    st(d0)
    expect(TK_COMMA)
    let d1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" {
      err(arg_msg("str_diff", 2, "str"))
    }
    st(d1)
    expect(TK_RPAREN)
    el("  mov rdi, " + loc(d0))
    el("  mov rsi, " + loc(d1))
    el("  call __t_str_diff")
    U_STRDIFF = 1
    GTYPE = "int"
    return
  }
  if kind == 22 {
    one_arg(name)
    if GTYPE != "" && GTYPE != "int" { err(arg_msg("newbuf", 1, "int")) }
    el("  mov rdi, rax")
    el("  call __t_newbuf")
    U_NEWBUF = 1
    U_ALLOC = 1
    GTYPE = "str"
    return
  }
  if kind == 32 {
    one_arg(name)
    if GTYPE != "" && GTYPE != "int" { err(arg_msg("shm", 1, "int")) }
    el("  mov rdi, rax")
    el("  call __t_shm")
    U_SHM = 1
    GTYPE = "int"
    return
  }
  if kind == 33 {
    adv()
    let q0 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" { err(arg_msg("fd_pwrite", 1, "int")) }
    st(q0)
    expect(TK_COMMA)
    let q1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" { err(arg_msg("fd_pwrite", 2, "int")) }
    st(q1)
    expect(TK_COMMA)
    let q2 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" { err(arg_msg("fd_pwrite", 3, "str")) }
    st(q2)
    expect(TK_COMMA)
    let q3 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" { err(arg_msg("fd_pwrite", 4, "int")) }
    st(q3)
    expect(TK_RPAREN)
    el("  mov rdi, " + loc(q0))
    el("  mov rsi, " + loc(q1))
    el("  mov rdx, " + loc(q2))
    el("  mov rcx, " + loc(q3))
    el("  call __t_fd_pwrite")
    U_FDPWRITE = 1
    GTYPE = "int"
    return
  }
  if kind == 34 {
    adv()
    let v0 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" { err(arg_msg("fd_send", 1, "int")) }
    st(v0)
    expect(TK_COMMA)
    let v1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" { err(arg_msg("fd_send", 2, "str")) }
    st(v1)
    expect(TK_COMMA)
    let v2 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" { err(arg_msg("fd_send", 3, "int")) }
    st(v2)
    expect(TK_COMMA)
    let v3 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" { err(arg_msg("fd_send", 4, "int")) }
    st(v3)
    expect(TK_RPAREN)
    el("  mov rdi, " + loc(v0))
    el("  mov rsi, " + loc(v1))
    el("  mov rdx, " + loc(v2))
    el("  mov rcx, " + loc(v3))
    el("  call __t_fd_send")
    U_FDSEND = 1
    GTYPE = "int"
    return
  }
  if kind == 23 {
    adv()
    expect(TK_RPAREN)
    el("  call __t_arena_mark")
    U_ARENA_MARK = 1
    GTYPE = "int"
    return
  }
  if kind == 24 {
    one_arg(name)
    if GTYPE != "" && GTYPE != "int" {
      err(arg_msg("arena_release", 1, "int"))
    }
    el("  mov rdi, rax")
    el("  call __t_arena_release")
    U_ARENA_RELEASE = 1
    GTYPE = "int"
    return
  }
  if kind == 25 {
    adv()
    let f0 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" {
      err(arg_msg("write_file", 1, "str"))
    }
    st(f0)
    expect(TK_COMMA)
    let f1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" {
      err(arg_msg("write_file", 2, "str"))
    }
    st(f1)
    expect(TK_RPAREN)
    el("  mov rdi, " + loc(f0))
    el("  mov rsi, " + loc(f1))
    el("  call __t_write_file")
    U_WRITEFILE = 1
    GTYPE = "int"
    return
  }
  if kind == 26 {
    adv()
    let g0 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" {
      err(arg_msg("append_file", 1, "str"))
    }
    st(g0)
    expect(TK_COMMA)
    let g1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" {
      err(arg_msg("append_file", 2, "str"))
    }
    st(g1)
    expect(TK_RPAREN)
    el("  mov rdi, " + loc(g0))
    el("  mov rsi, " + loc(g1))
    el("  call __t_append_file")
    U_APPENDFILE = 1
    GTYPE = "int"
    return
  }
  if kind == 27 {
    one_arg(name)
    if GTYPE != "" && GTYPE != "str" {
      err(arg_msg("file_exists", 1, "str"))
    }
    el("  mov rdi, rax")
    el("  call __t_file_exists")
    U_FILEEXISTS = 1
    GTYPE = "int"
    return
  }
  if kind == 72 {
    one_arg(name)
    if GTYPE != "" && GTYPE != "str" {
      err(arg_msg("env", 1, "str"))
    }
    el("  mov rdi, rax")
    el("  call __t_env")
    U_ENV = 1
    GTYPE = "str"
    return
  }
  if kind >= 73 && kind <= 80 {
    let nm = ""
    if kind == 73 { nm = "clz" }
    if kind == 74 { nm = "rbit" }
    if kind == 75 { nm = "bswap16" }
    if kind == 76 { nm = "bswap32" }
    if kind == 77 { nm = "bswap64" }
    if kind == 78 { nm = "sext8" }
    if kind == 79 { nm = "sext16" }
    if kind == 80 { nm = "sext32" }
    one_arg(nm)
    if GTYPE != "" && GTYPE != "int" {
      err(arg_msg(nm, 1, "int"))
    }
    el("  mov rdi, rax")
    el("  call __t_" + nm)
    if kind == 73 { U_CLZ = 1 }
    if kind == 74 { U_RBIT = 1 }
    if kind == 75 { U_BSWAP16 = 1 }
    if kind == 76 { U_BSWAP32 = 1 }
    if kind == 77 { U_BSWAP64 = 1 }
    if kind == 78 { U_SEXT8 = 1 }
    if kind == 79 { U_SEXT16 = 1 }
    if kind == 80 { U_SEXT32 = 1 }
    GTYPE = "int"
    return
  }
  if kind >= 81 && kind <= 84 {
    let nm2 = ""
    if kind == 81 { nm2 = "udiv" }
    if kind == 82 { nm2 = "umod" }
    if kind == 83 { nm2 = "rol8" }
    if kind == 84 { nm2 = "ror8" }
    two_int_args(nm2)
    el("  call __t_" + nm2)
    if kind == 81 { U_UDIV = 1 }
    if kind == 82 { U_UMOD = 1 }
    if kind == 83 { U_ROL8 = 1 }
    if kind == 84 { U_ROR8 = 1 }
    GTYPE = "int"
    return
  }
  if kind >= 85 && kind <= 88 {
    let ln = ""
    if kind == 85 { ln = "ld8" }
    if kind == 86 { ln = "ld16" }
    if kind == 87 { ln = "ld32" }
    if kind == 88 { ln = "ld64" }
    parse_args2(ln, "str", "int")
    el("  call __t_" + ln)
    if kind == 85 { U_LD8 = 1 }
    if kind == 86 { U_LD16 = 1 }
    if kind == 87 { U_LD32 = 1 }
    if kind == 88 { U_LD64 = 1 }
    GTYPE = "int"
    return
  }
  if kind >= 89 && kind <= 92 {
    let sn = ""
    if kind == 89 { sn = "st8" }
    if kind == 90 { sn = "st16" }
    if kind == 91 { sn = "st32" }
    if kind == 92 { sn = "st64" }
    parse_args3(sn, "str", "int", "int")
    el("  call __t_" + sn)
    if kind == 89 { U_ST8 = 1 }
    if kind == 90 { U_ST16 = 1 }
    if kind == 91 { U_ST32 = 1 }
    if kind == 92 { U_ST64 = 1 }
    GTYPE = "int"
    return
  }
  if kind == 93 {
    parse_args3("memcpy", "str", "str", "int")
    el("  call __t_memcpy")
    U_MEMCPY = 1
    GTYPE = "int"
    return
  }
  if kind == 94 {
    parse_args3("memset", "str", "int", "int")
    el("  call __t_memset")
    U_MEMSET = 1
    GTYPE = "int"
    return
  }
  if kind == 28 {
    one_arg(name)
    if GTYPE == "int" {
      el("  mov rdi, rax")
      el("  call __t_itof")
      U_FLOAT = 1
    } else if GTYPE != "" && GTYPE != "float" {
      err(arg_msg("float", 1, "int or float"))
    }
    GTYPE = "float"
    return
  }
  if kind == 29 {
    one_arg(name)
    if GTYPE != "" && GTYPE != "float" {
      err(arg_msg("print_float", 1, "float"))
    }
    el("  mov rdi, rax")
    el("  call __t_print_float")
    U_FLOAT = 1
    U_PRINTFLOAT = 1
    U_FTOA = 1
    U_PRINT = 1
    U_PRINT_INT = 1
    U_PRINT_CHAR = 1
    GTYPE = "int"
    return
  }
  if kind == 30 {
    one_arg(name)
    if GTYPE != "" && GTYPE != "float" {
      err(arg_msg("sqrt", 1, "float"))
    }
    el("  mov rdi, rax")
    el("  call __t_fsqrt")
    U_FLOAT = 1
    GTYPE = "float"
    return
  }
  if kind == 31 {
    one_arg(name)
    if GTYPE != "" && GTYPE != "float" {
      err(arg_msg("fabs", 1, "float"))
    }
    el("  mov rdi, rax")
    el("  call __t_fabs")
    U_FLOAT = 1
    GTYPE = "float"
    return
  }
  if parse_generated_builtin(name, kind) == 1 { return }
  one_arg(name)
  if GTYPE != "" && GTYPE != "int" {
    err(arg_msg("exit", 1, "int"))
  }
  el("  mov rdi, rax")
  el("  call __t_exit")
  U_EXIT = 1
  GTYPE = "int"
}

# ---------------------------------------------------------------- statements
fn parse_block() {
  expect(TK_LBRACE)
  if NMARK >= 2000 {
    err("blocks nested too deeply")
  }
  MARKS[NMARK] = NSYM
  NMARK = NMARK + 1
  while cur_is(TK_RBRACE) == 0 && cur_is(TK_EOF) == 0 {
    if cur_is(TK_SEMI) == 1 {
      adv()
    } else {
      parse_stmt()
    }
  }
  expect(TK_RBRACE)
  NMARK = NMARK - 1
  NSYM = MARKS[NMARK]
}

fn parse_switch() {
  adv()
  expr()
  let ty = GTYPE
  if str_eq(ty, "float") == 1 {
    err("switch does not support float values")
  }
  if ty != "" && str_eq(ty, "int") == 0 && str_eq(ty, "str") == 0 {
    err("switch needs integer or string case values")
  }
  # Case bodies can reuse temporaries, so the selector lives in a dedicated
  # global slot until the deferred dispatch reads it back.
  el("  mov [rip + __t_switch_val], rax")
  skip_semis()
  if cur_is(TK_LBRACE) == 0 {
    err("expected '{' after the switch value, found " + describe(TI))
  }
  adv()

  # Bodies are emitted first; a jump over them reaches the dispatch built at
  # the end, once every case value and its body label are known.
  let end = newl()
  let disp = newl()
  el("  jmp " + disp)
  let cv = alloc(512, int)
  let cl = alloc(512, str)
  let cb = alloc(512, str)
  let nd = 0
  let deflab = ""
  let has_def = 0
  while cur_is(TK_RBRACE) == 0 && cur_is(TK_EOF) == 0 {
    skip_semis()
    if cur_is(TK_RBRACE) == 1 {
      break
    }
    if cur_kw(KW_CASE) == 1 {
      adv()
      if ty == "" {
        if cur_is(TK_STR) == 1 {
          ty = "str"
        } else {
          ty = "int"
        }
      }
      let body = newl()
      while 1 {
        if nd >= 512 {
          err("too many switch cases")
        }
        if str_eq(ty, "str") == 1 {
          if cur_is(TK_STR) == 0 {
            if cur_is(TK_INT) == 1 || cur_is(TK_MINUS) == 1 {
              err("switch on str cannot match int case values")
            }
            err("expected a number or string literal after 'case', found " + describe(TI))
          }
          cl[nd] = intern(TV[TI])
          cv[nd] = 0
          adv()
        } else {
          let neg = 0
          if cur_is(TK_MINUS) == 1 {
            neg = 1
            adv()
          }
          if cur_is(TK_INT) == 0 {
            if cur_is(TK_STR) == 1 {
              err("switch on int cannot match str case values")
            }
            err("expected a number or string literal after 'case', found " + describe(TI))
          }
          let v = TN[TI]
          if neg == 1 {
            v = 0 - v
          }
          adv()
          cv[nd] = v
          cl[nd] = ""
        }
        cb[nd] = body
        nd = nd + 1
        if cur_is(TK_COMMA) == 1 {
          adv()
        } else {
          break
        }
      }
      skip_semis()
      el(body + ":")
      push_loop(end, "")
      parse_block()
      NLOOP = NLOOP - 1
      el("  jmp " + end)
      continue
    }
    if cur_kw(KW_ELSE) == 1 {
      adv()
      skip_semis()
      deflab = newl()
      has_def = 1
      el(deflab + ":")
      push_loop(end, "")
      parse_block()
      NLOOP = NLOOP - 1
      el("  jmp " + end)
      continue
    }
    err("expected 'case' or 'else' in a switch")
  }
  expect(TK_RBRACE)

  let fallback = end
  if has_def == 1 {
    fallback = deflab
  }
  el(disp + ":")

  # A dense integer switch becomes one range check and an indirect jump.
  let used = 0
  if str_eq(ty, "int") == 1 && nd >= 4 {
    let lo = cv[0]
    let hi = cv[0]
    let i = 0
    while i < nd {
      if cv[i] < lo { lo = cv[i] }
      if cv[i] > hi { hi = cv[i] }
      i = i + 1
    }
    i = 0
    while i < nd {
      let dup = 0
      let j = 0
      while j < i {
        if cv[j] == cv[i] { dup = 1 }
        j = j + 1
      }
      if dup == 0 { used = used + 1 }
      i = i + 1
    }
    let span = hi - lo
    let limit = 4 * used
    if limit > 4096 { limit = 4096 }
    if used >= 4 && span >= 0 && span <= limit {
      let tbl = "T" + NTAB
      TAB_LABEL[NTAB] = tbl
      TAB_BASE[NTAB] = NTARGET
      NTAB = NTAB + 1
      i = 0
      while i <= span {
        let v = lo + i
        let target = fallback
        let k = 0
        while k < nd {
          if cv[k] == v { target = cb[k] }
          k = k + 1
        }
        TAB_TARGET[NTARGET] = target
        NTARGET = NTARGET + 1
        i = i + 1
      }
      TAB_COUNT[NTAB - 1] = span + 1
      el("  mov rax, [rip + __t_switch_val]")
      if lo != 0 {
        el("  sub rax, " + lo)
      }
      el("  cmp rax, " + span)
      el("  ja " + fallback)
      el("  lea rdx, [rip + " + tbl + "]")
      el("  jmp qword ptr [rdx + rax*8]")
      el(end + ":")
      return
    }
  }

  # Sparse or string switches keep the compare chain.
  let i = 0
  while i < nd {
    if str_eq(cl[i], "") == 1 {
      el("  mov rax, " + cv[i])
      el("  mov rcx, [rip + __t_switch_val]")
      el("  cmp rcx, rax")
      el("  je " + cb[i])
    } else {
      el("  lea rsi, [rip + " + cl[i] + "]")
      el("  mov rdi, [rip + __t_switch_val]")
      el("  call __t_str_eq")
      U_STREQ = 1
      el("  test rax, rax")
      el("  jne " + cb[i])
    }
    i = i + 1
  }
  el("  jmp " + fallback)
  el(end + ":")
}

fn parse_stmt() {
  rt()
  if cur_kw(KW_FN) == 1 || cur_kw(KW_STRUCT) == 1 || cur_kw(KW_ELSE) == 1 || cur_kw(KW_CASE) == 1 {
    err("'" + kw_text(TN[TI]) + "' is not allowed here")
  }
  if cur_is(TK_INC) == 1 || cur_is(TK_DEC) == 1 {
    let up = 1
    if cur_is(TK_DEC) == 1 {
      up = 0
    }
    adv()
    if cur_is(TK_IDENT) == 0 {
      err("expected a variable after '++' or '--'")
    }
    let nm = TV[TI]
    adv()
    bump(nm, up)
    return
  }
  if cur_is(TK_IDENT) == 1 && (TK[TI + 1] == TK_INC || TK[TI + 1] == TK_DEC) {
    if TI + 2 >= NT {
      err("'++' and '--' are statements, not expressions")
    }
    let nx = TK[TI + 2]
    if nx != TK_SEMI && nx != TK_RBRACE && nx != TK_EOF {
      err("'++' and '--' are statements, not expressions")
    }
    let nm = TV[TI]
    if TK[TI + 1] == TK_INC {
      bump(nm, 1)
    } else {
      bump(nm, 0)
    }
    TI = TI + 2
    return
  }
  if cur_kw(KW_LET) == 1 {
    parse_let()
    return
  }
  if cur_kw(KW_IF) == 1 {
    parse_if()
    return
  }
  if cur_kw(KW_WHILE) == 1 {
    parse_while()
    return
  }
  if cur_kw(KW_DO) == 1 {
    parse_do()
    return
  }
  if cur_kw(KW_LOOP) == 1 {
    parse_loop()
    return
  }
  if cur_kw(KW_FOR) == 1 {
    parse_for()
    return
  }
  if cur_kw(KW_SWITCH) == 1 {
    parse_switch()
    return
  }
  if cur_kw(KW_RETURN) == 1 {
    parse_return()
    return
  }
  if cur_kw(KW_BREAK) == 1 {
    adv()
    if NLOOP == 0 {
      err("'break' outside of a loop")
    }
    el("  jmp " + LBREAK[NLOOP - 1])
    return
  }
  if cur_kw(KW_CONTINUE) == 1 {
    adv()
    let i = NLOOP - 1
    let target = ""
    while i >= 0 && target == "" {
      if str_eq(LCONT[i], "") == 0 {
        target = LCONT[i]
      }
      i = i - 1
    }
    if target == "" {
      err("'continue' outside of a loop")
    }
    el("  jmp " + target)
    return
  }
  if is_assignment() == 1 {
    parse_assign()
    return
  }
  expr()
  # A compound assignment or increment whose target is not a plain variable
  # parses as an expression first; name the real problem here.
  if is_compound(TK[TI]) == 1 {
    err("'" + assign_op_text(TK[TI]) + "=' needs a plain variable on the left")
  }
  if cur_is(TK_INC) == 1 || cur_is(TK_DEC) == 1 {
    if cur_is(TK_INC) == 1 {
      err("'++' needs a plain variable")
    }
    err("'--' needs a plain variable")
  }
}

fn parse_let() {
  adv()
  if cur_is(TK_IDENT) == 0 {
    err("expected a variable name, found " + describe(TI))
  }
  let name = TV[TI]
  adv()
  expect(TK_ASSIGN)
  let s = slot()
  expr()
  st(s)
  if GTYPE == "" {
    declare(name, s, "")
  } else {
    declare(name, s, GTYPE)
  }
}

fn parse_assign() {
  let name = TV[TI]
  adv()
  if lookup(name) == 0 {
    if const_find(name) >= 0 {
      err("cannot assign to const '" + name + "'")
    }
    err("unknown variable '" + name + "'")
  }
  let s = GSLOT
  let t = GTYPE
  if is_compound(TK[TI]) == 1 {
    let op = TK[TI]
    adv()
    expr()
    if t == "str" {
      # `s += x` concatenates, exactly like `s = s + x`; the other compound
      # operators have no string meaning.
      if op != TK_PLUSEQ {
        err("cannot use '" + assign_op_text(op) + "' on strings")
      }
      if GTYPE == "float" {
        err("cannot concatenate a float to a string")
      }
      el("  mov rcx, rax")
      el("  mov rax, " + loc(s))
      if GTYPE == "int" {
        el("  push rax")
        el("  mov rdi, rcx")
        el("  call __t_itoa")
        el("  mov rcx, rax")
        el("  pop rax")
        U_ITOA = 1
      }
      el("  mov rdi, rax")
      el("  mov rsi, rcx")
      el("  call __t_concat")
      U_CONCAT = 1
      st(s)
      set_type(name, "str")
      return
    }
    if is_ptr_type(t) == 1 {
      if op != TK_PLUSEQ && op != TK_MINUSEQ {
        err("pointer arithmetic needs += or -=")
      }
      if GTYPE != "" && GTYPE != "int" {
        err("pointer arithmetic needs an integer")
      }
      el("  mov rcx, rax")
      el("  mov rax, " + loc(s))
      el("  shl rcx, 3")
      if op == TK_PLUSEQ {
        el("  add rax, rcx")
      } else {
        el("  sub rax, rcx")
      }
      st(s)
      set_type(name, "ptr")
      return
    }
    if t == "float" || GTYPE == "float" {
      if t == "str" || op == TK_PERCENTEQ {
        err("cannot use this operator on a float")
      }
      el("  mov rcx, rax")
      el("  mov rax, " + loc(s))
      if t == "int" {
        el("  mov rdi, rax")
        el("  call __t_itof")
        el("  mov r8, rax")
      } else {
        el("  mov r8, rax")
      }
      if GTYPE == "int" {
        el("  mov rdi, rcx")
        el("  call __t_itof")
        el("  mov rsi, rax")
      } else {
        el("  mov rsi, rcx")
      }
      el("  mov rdi, r8")
      if op == TK_PLUSEQ {
        el("  call __t_fadd")
      } else if op == TK_MINUSEQ {
        el("  call __t_fsub")
      } else if op == TK_STAREQ {
        el("  call __t_fmul")
      } else if op == TK_SLASHEQ {
        el("  call __t_fdiv")
      } else {
        err("unknown float assignment operator")
      }
      U_FLOAT = 1
      st(s)
      set_type(name, "float")
      return
    }
    el("  mov rcx, rax")
    el("  mov rax, " + loc(s))
    if op == TK_PLUSEQ {
      el("  add rax, rcx")
    } else if op == TK_MINUSEQ {
      el("  sub rax, rcx")
    } else if op == TK_STAREQ {
      el("  imul rax, rcx")
    } else if op == TK_AMPEQ {
      el("  and rax, rcx")
    } else if op == TK_PIPEEQ {
      el("  or rax, rcx")
    } else if op == TK_CARETEQ {
      el("  xor rax, rcx")
    } else if op == TK_SHLEQ {
      el("  shl rax, cl")
    } else if op == TK_SHREQ {
      el("  sar rax, cl")
    } else if op == TK_USHREQ {
      el("  shr rax, cl")
    } else {
      el("  cqo")
      el("  idiv rcx")
      if op == TK_PERCENTEQ {
        el("  mov rax, rdx")
      }
    }
    st(s)
    if GTYPE == "" {
      set_type(name, "")
    } else {
      set_type(name, GTYPE)
    }
    return
  }
  if cur_is(TK_ASSIGN) == 1 {
    adv()
    expr()
    st(s)
    if GTYPE == "" {
      set_type(name, "")
    } else {
      set_type(name, GTYPE)
    }
    return
  }
  if cur_is(TK_LBRACKET) == 1 || cur_is(TK_DOT) == 1 {
    # Any chain of index and field steps, so `a[i].f = v` and `o.a.v = v`
    # store where the same chain would read. The address is walked into rax;
    # each step leaves the element's address there and updates its type.
    el("  mov rax, " + loc(s))
    let byte = 0
    while cur_is(TK_LBRACKET) == 1 || cur_is(TK_DOT) == 1 {
      if cur_is(TK_LBRACKET) == 1 {
        adv()
        el("  push rax")
        expr()
        el("  mov rcx, rax")
        el("  pop rax")
        if str_eq(t, "str") == 1 {
          emit_index_check_string()
          el("  add rax, rcx")
          t = "int"
          byte = 1
        } else {
          if str_eq(t, "arr") == 1 || has_arr_prefix(t) == 1 {
            emit_index_check_array()
          }
          el("  lea rax, [rax + rcx*8]")
          byte = 0
          if has_arr_prefix(t) == 1 {
            t = elem_of(t)
          } else {
            t = "int"
          }
        }
        expect(TK_RBRACKET)
      } else {
        adv()
        let fname = TV[TI]
        adv()
        let sidx = struct_find(t)
        if sidx < 0 {
          err("cannot read field '" + fname + "' of " + type_article(t))
        }
        let fi = field_index(sidx, fname)
        if fi < 0 {
          err("struct '" + t + "' has no field '" + fname + "'")
        }
        el("  add rax, " + (8 * fi))
        t = F_TYPE[S_FSTART[sidx] + fi]
        byte = 0
      }
      if cur_is(TK_LBRACKET) == 1 || cur_is(TK_DOT) == 1 {
        # A step that is not the last one holds a pointer to the next object;
        # only the last step's address is stored through.
        el("  mov rax, [rax]")
      }
    }
    if is_compound(TK[TI]) == 1 {
      err("'" + assign_op_text(TK[TI]) + "=' needs a plain variable on the left")
    }
    expect(TK_ASSIGN)
    el("  push rax")
    expr()
    el("  mov rdx, rax")
    el("  pop rax")
    if byte == 1 {
      el("  mov byte ptr [rax], dl")
    } else {
      el("  mov [rax], rdx")
    }
    return
  }
  err("bad assignment")
}

fn parse_if() {
  adv()
  let lelse = newl()
  expr()
  el("  test rax, rax")
  el("  je " + lelse)
  parse_block()
  let lend = newl()
  el("  jmp " + lend)
  el(lelse + ":")
  skip_semis()
  if cur_kw(KW_ELSE) == 1 {
    adv()
    if cur_kw(KW_IF) == 1 {
      parse_if()
    } else {
      parse_block()
    }
  }
  el(lend + ":")
}

fn parse_while() {
  adv()
  let top = newl()
  let end = newl()
  el(top + ":")
  expr()
  el("  test rax, rax")
  el("  je " + end)
  push_loop(end, top)
  parse_block()
  NLOOP = NLOOP - 1
  el("  jmp " + top)
  el(end + ":")
}

# do { } while cond: the body runs once before the condition; continue jumps to
# the condition and break leaves the loop.
fn parse_do() {
  adv()
  let top = newl()
  let cont = newl()
  let end = newl()
  el(top + ":")
  push_loop(end, cont)
  parse_block()
  NLOOP = NLOOP - 1
  skip_semis()
  if cur_kw(KW_WHILE) == 0 {
    err("expected 'while', found " + describe(TI))
  }
  adv()
  el(cont + ":")
  expr()
  el("  test rax, rax")
  el("  jne " + top)
  el(end + ":")
}

# loop { }: unconditional; break leaves and continue starts over.
fn parse_loop() {
  adv()
  let top = newl()
  let end = newl()
  el(top + ":")
  push_loop(end, top)
  parse_block()
  NLOOP = NLOOP - 1
  el("  jmp " + top)
  el(end + ":")
}

# for i in a..b { }: the bound is evaluated once, and `continue` jumps to the
# increment so an early-continuing body still advances the counter.
# for x in value { }: the same shape over a string's bytes or an array's
# elements; the collection and its length are read once.
fn parse_for() {
  adv()
  if cur_is(TK_IDENT) == 0 {
    err("expected a loop variable, found " + describe(TI))
  }
  let name = TV[TI]
  adv()
  if cur_kw(KW_IN) == 0 {
    err("expected 'in', found " + describe(TI))
  }
  adv()
  expr()
  let s = slot()
  el("  mov " + loc(s) + ", rax")
  let ty = GTYPE
  let symbase = NSYM
  if cur_is(TK_DOTS) == 0 {
    let len_s = slot()
    let elem = "int"
    if ty == "str" {
      el("  mov rdi, " + loc(s))
      el("  call __t_strlen")
      U_LEN = 1
      el("  mov " + loc(len_s) + ", rax")
    } else if ty == "ptr" || ty == "arr" || has_arr_prefix(ty) == 1 {
      el("  mov rax, " + loc(s))
      el("  mov rax, [rax - 8]")
      el("  mov " + loc(len_s) + ", rax")
      if has_arr_prefix(ty) == 1 {
        elem = elem_of(ty)
      }
    } else {
      err("for-each needs a string or an array")
    }
    let idx = slot()
    el("  mov qword ptr " + loc(idx) + ", 0")
    let v = slot()
    declare(name, v, elem)
    let top = newl()
    let step = newl()
    let done = newl()
    el(top + ":")
    el("  mov rax, " + loc(idx))
    el("  cmp rax, " + loc(len_s))
    el("  jge " + done)
    el("  mov rcx, " + loc(s))
    if ty == "str" {
      el("  movzx edx, byte ptr [rcx + rax]")
    } else {
      el("  mov rdx, [rcx + rax*8]")
    }
    el("  mov " + loc(v) + ", rdx")
    push_loop(done, step)
    parse_block()
    NLOOP = NLOOP - 1
    el(step + ":")
    el("  add qword ptr " + loc(idx) + ", 1")
    el("  jmp " + top)
    el(done + ":")
    NSYM = symbase
    return
  }
  declare(name, s, "int")
  adv()
  expr()
  let e = slot()
  el("  mov " + loc(e) + ", rax")
  let top = newl()
  let step = newl()
  let done = newl()
  el(top + ":")
  el("  mov rax, " + loc(s))
  el("  mov rcx, " + loc(e))
  el("  cmp rax, rcx")
  el("  jge " + done)
  push_loop(done, step)
  parse_block()
  NLOOP = NLOOP - 1
  el(step + ":")
  el("  mov rax, " + loc(s))
  el("  add rax, 1")
  el("  mov " + loc(s) + ", rax")
  el("  jmp " + top)
  el(done + ":")
  NSYM = symbase
}

fn parse_return() {
  adv()
  if cur_is(TK_SEMI) == 1 || cur_is(TK_RBRACE) == 1 {
    el("  xor eax, eax")
  } else {
    expr()
    if types_ok(CUR_RET, GTYPE) == 0 {
      err("'" + CURFN + "' returns " + type_word(CUR_RET) + ", but this return gives " + type_word(GTYPE))
    }
    if str_eq(CUR_RET, "") == 1 && str_eq(CUR_INFER, "") == 1 {
      if str_eq(GTYPE, "") == 0 {
        CUR_INFER = GTYPE
      }
    }
  }
  el("  jmp .Lret_" + CURFN)
}

# ---------------------------------------------------------------- prescan
# A struct name may be used in an annotation before its declaration; collect
# the top-level names first so the annotations can be checked in one pass.
fn pre_struct_find(name: str) -> int {
  let i = 0
  while i < PRE_NSTRUCT {
    if str_eq(PRE_SNAME[i], name) == 1 {
      return i
    }
    i = i + 1
  }
  return -1
}

fn pre_global_find(name: str) -> int {
  let i = 0
  while i < PRE_NGLOB {
    if str_eq(PRE_GNAME[i], name) == 1 {
      return i
    }
    i = i + 1
  }
  return -1
}

# Report at token i, or at the end of file when i is past the last token.
fn err_tok(msg: str, i: int) {
  if i >= NT {
    err_at(msg, TP[NT - 1], TL[NT - 1])
  }
  err_at(msg, TP[i], TL[i])
}

fn skip_semis_at(i: int) -> int {
  while i < NT && TK[i] == TK_SEMI {
    i = i + 1
  }
  return i
}

fn prescan_struct(s: int) {
  let at = PRE_SAT[s]
  let name = PRE_SNAME[s]
  let spos = TP[at]
  let sline = TL[at]
  if at + 1 >= NT || TK[at + 1] != TK_IDENT {
    err_tok("expected a struct name, found " + describe(at + 1), at + 1)
  }
  if struct_find(name) >= 0 {
    err_at("struct '" + name + "' defined twice", spos, sline)
  }
  if builtin_kind(name) != 0 {
    err_at("struct name '" + name + "' is a builtin", spos, sline)
  }
  if NSTRUCT >= 1000 {
    err_at("too many structs", spos, sline)
  }
  let sidx = NSTRUCT
  NSTRUCT = NSTRUCT + 1
  S_NAME[sidx] = name
  S_FSTART[sidx] = NFIELD
  let i = at + 2
  if i >= NT || TK[i] != TK_LBRACE {
    err_tok("expected '{', found " + describe(i), i)
  }
  i = i + 1
  # Fields are comma-separated, matching stage 0: a newline between two fields
  # is not a separator, so `{ a b }` is an error rather than two fields.
  if i < NT && TK[i] != TK_RBRACE {
    while 1 {
      i = skip_semis_at(i)
      if i >= NT || TK[i] != TK_IDENT {
        err_tok("expected a field name, found " + describe(i), i)
      }
      let fname = TV[i]
      i = i + 1
      let ftype = ""
      if i < NT && TK[i] == TK_COLON {
        i = i + 1
        if i >= NT || TK[i] != TK_IDENT {
          err_tok("expected a type name, found " + describe(i), i)
        }
        ftype = TV[i]
        i = i + 1
        if i < NT && TK[i] == TK_LBRACKET {
          i = i + 1
          if i >= NT || TK[i] != TK_RBRACKET {
            err_tok("expected ']' after an array type, found " + describe(i), i)
          }
          i = i + 1
          ftype = ftype + "[]"
        }
      }
      if type_known(norm_type(ftype)) == 0 {
        err_at("unknown type '" + ftype + "' for field '" + fname + "'", spos, sline)
      }
      if field_dup(sidx, fname) == 1 {
        err_at("struct '" + name + "' has duplicate fields", spos, sline)
      }
      if NFIELD >= 8000 {
        err_at("too many struct fields", spos, sline)
      }
      F_NAME[NFIELD] = fname
      F_TYPE[NFIELD] = norm_type(ftype)
      NFIELD = NFIELD + 1
      i = skip_semis_at(i)
      if i >= NT || TK[i] != TK_COMMA {
        break
      }
      i = i + 1
      i = skip_semis_at(i)
      if i < NT && TK[i] == TK_RBRACE {
        break
      }
    }
  }
  if i >= NT || TK[i] != TK_RBRACE {
    err_tok("expected '}', found " + describe(i), i)
  }
  S_FCOUNT[sidx] = NFIELD - S_FSTART[sidx]
}

fn con_add(name: str, kind: int, imm: int, label: str, pos: int, line: int) {
  # One name per const: a second declaration is a mistake, not a shadow.

  let i = 0
  while i < CON_N {
    if str_eq(CON_NAME[i], name) == 1 {
      err_at("const '" + name + "' defined twice", pos, line)
    }
    i = i + 1
  }
  if CON_N >= 1000 {
    err_at("too many consts", pos, line)
  }
  CON_NAME[CON_N] = name
  CON_KIND[CON_N] = kind
  CON_IMM[CON_N] = imm
  CON_LABEL[CON_N] = label
  CON_POS[CON_N] = pos
  CON_LINE[CON_N] = line
  CON_N = CON_N + 1
}

fn const_find(name: str) -> int {
  let i = 0
  while i < CON_N {
    if str_eq(CON_NAME[i], name) == 1 {
      return i
    }
    i = i + 1
  }
  return 0 - 1
}

fn prescan() {
  PRE_NSTRUCT = 0
  CON_N = 0
  PRE_NGLOB = 0
  let depth = 0
  let i = 0
  while i < NT {
    if TK[i] == TK_LBRACE {
      depth = depth + 1
    } else if TK[i] == TK_RBRACE {
      if depth > 0 {
        depth = depth - 1
      }
    } else if depth == 0 && TK[i] == TK_KW && i + 1 < NT {
      if TN[i] == KW_STRUCT && PRE_NSTRUCT < 1000 {
        PRE_SNAME[PRE_NSTRUCT] = ""
        if i + 1 < NT {
          PRE_SNAME[PRE_NSTRUCT] = TV[i + 1]
        }
        PRE_SAT[PRE_NSTRUCT] = i
        PRE_NSTRUCT = PRE_NSTRUCT + 1
      } else if TN[i] == KW_LET && PRE_NGLOB < 4000 {
        PRE_GNAME[PRE_NGLOB] = ""
        if i + 1 < NT {
          PRE_GNAME[PRE_NGLOB] = TV[i + 1]
        }
        PRE_NGLOB = PRE_NGLOB + 1
      } else if TN[i] == KW_CONST && CON_N < 1000 {
        # A const is a literal, so the prescan can evaluate it without the
        # parser: name, '=', an optional '-', then an int or string token.
        if i + 3 < NT && TK[i + 1] == TK_IDENT && TK[i + 2] == TK_ASSIGN {
          let j = i + 3
          let sign = 1
          if j < NT && TK[j] == TK_MINUS {
            sign = 0 - 1
            j = j + 1
          }
          if j < NT && TK[j] == TK_INT {
            con_add(TV[i + 1], 0, sign * TN[j], "", TP[i], TL[i])
          } else if j < NT && TK[j] == TK_STR && sign == 1 {
            con_add(TV[i + 1], 1, 0, intern(TV[j]), TP[i], TL[i])
          }
        }
      }
    }
    i = i + 1
  }
  let c = 0
  while c < CON_N {
    let g = 0
    while g < PRE_NGLOB {
      if str_eq(PRE_GNAME[g], CON_NAME[c]) == 1 {
        err_at("global '" + CON_NAME[c] + "' defined twice", CON_POS[c], CON_LINE[c])
      }
      g = g + 1
    }
    c = c + 1
  }
  # Every struct name is known now, so a field may name a struct declared
  # later; only then are the fields themselves registered.
  let s = 0
  while s < PRE_NSTRUCT {
    prescan_struct(s)
    s = s + 1
  }
}

# Globals are visible from every function, including one declared above them.
fn predeclare_globals() {
  let i = 0
  while i < PRE_NGLOB {
    declare(PRE_GNAME[i], 0 - i - 1, "")
    i = i + 1
  }
}

# A normalized annotation: "" (unknown), int/str/float, arr_of:T, or a struct.
fn type_known(t: str) -> int {
  if str_eq(t, "") == 1 {
    return 1
  }
  if str_eq(t, "int") == 1 || str_eq(t, "str") == 1 || str_eq(t, "float") == 1 {
    return 1
  }
  if has_arr_prefix(t) == 1 {
    return type_known(elem_of(t))
  }
  if struct_find(t) >= 0 || pre_struct_find(t) >= 0 {
    return 1
  }
  return 0
}

fn field_dup(sidx: int, name: str) -> int {
  let i = S_FSTART[sidx]
  while i < NFIELD {
    if str_eq(F_NAME[i], name) == 1 {
      return 1
    }
    i = i + 1
  }
  return 0
}

# "an integer", "a string", ... for a field access on a non-struct.
fn type_article(t: str) -> str {
  if str_eq(t, "") == 1 {
    return "an unknown value"
  }
  if str_eq(t, "int") == 1 {
    return "an integer"
  }
  if str_eq(t, "str") == 1 {
    return "a string"
  }
  if str_eq(t, "float") == 1 {
    return "a float"
  }
  if str_eq(t, "ptr") == 1 {
    return "a pointer"
  }
  if str_eq(t, "arr") == 1 {
    return "an array"
  }
  return t
}

fn bin_op_text(k: int) -> str {
  if k == TK_PERCENT {
    return "%"
  }
  if k == TK_AMP {
    return "&"
  }
  if k == TK_PIPE {
    return "|"
  }
  if k == TK_CARET {
    return "^"
  }
  if k == TK_SHL {
    return "<<"
  }
  if k == TK_SHR {
    return ">>"
  }
  if k == TK_USHR {
    return ">>>"
  }
  return "?"
}

fn assign_op_text(k: int) -> str {
  if k == TK_PLUSEQ {
    return "+"
  }
  if k == TK_MINUSEQ {
    return "-"
  }
  if k == TK_STAREQ {
    return "*"
  }
  if k == TK_SLASHEQ {
    return "/"
  }
  if k == TK_PERCENTEQ {
    return "%"
  }
  if k == TK_AMPEQ {
    return "&"
  }
  if k == TK_PIPEEQ {
    return "|"
  }
  if k == TK_CARETEQ {
    return "^"
  }
  if k == TK_SHLEQ {
    return "<<"
  }
  if k == TK_USHREQ {
    return ">>>"
  }
  return ">>"
}

# ---------------------------------------------------------------- declarations
# The prescan already registered and checked every top-level struct, because a
# function body may use one before its declaration; skip its tokens here.
fn parse_struct() {
  let depth = 0
  while cur_is(TK_EOF) == 0 {
    if cur_is(TK_LBRACE) == 1 {
      depth = depth + 1
    } else if cur_is(TK_RBRACE) == 1 {
      depth = depth - 1
    }
    adv()
    if depth == 0 && TK[TI - 1] == TK_RBRACE {
      return
    }
  }
}

fn fn_enter(name: str, np: int) {
  CURFN = name
  CUR_RET = ""
  CUR_INFER = ""
  SLOT = np
  TS = 256
  NLOOP = 0
  NMARK = 0
}

fn parse_fn() {
  adv()
  if cur_is(TK_IDENT) == 0 {
    err("expected a function name, found " + describe(TI))
  }
  let name = TV[TI]
  let spos = TP[TI - 1]
  let sline = TL[TI - 1]
  if fn_find(name) >= 0 {
    err_at("function '" + name + "' defined twice", spos, sline)
  }
  if builtin_kind(name) != 0 {
    err_at("function name '" + name + "' is a builtin", spos, sline)
  }
  adv()
  expect(TK_LPAREN)
  if NFN >= 4000 {
    err("too many functions")
  }
  let fidx = NFN
  FN_NAME[fidx] = name
  FN_POS[fidx] = spos
  FN_LINE[fidx] = sline
  FN_PBASE[fidx] = NPARAM
  BASE = NSYM
  el(".Lfn_" + name + ":")
  el("  push rbp")
  el("  mov rbp, rsp")
  el("  sub rsp, 4096")
  fn_enter(name, 0)
  let np = 0
  while cur_is(TK_RPAREN) == 0 {
    if cur_is(TK_IDENT) == 0 {
      err("expected a parameter name, found " + describe(TI))
    }
    let pname = TV[TI]
    adv()
    let ptype = ""
    if cur_is(TK_COLON) == 1 {
      adv()
      if cur_is(TK_IDENT) == 0 {
        err("expected a type name, found " + describe(TI))
      }
      ptype = TV[TI]
      adv()
      if cur_is(TK_LBRACKET) == 1 {
        adv()
        if cur_is(TK_RBRACKET) == 0 {
          err("expected ']' after an array type, found " + describe(TI))
        }
        adv()
        ptype = ptype + "[]"
      }
    }
    if type_known(norm_type(ptype)) == 0 {
      err_at("unknown type '" + ptype + "'", spos, sline)
    }
    el("  mov " + rr(np) + ", " + call_reg(np))
    declare(pname, np, norm_type(ptype))
    if NPARAM >= 24000 {
      err("too many parameters")
    }
    FN_PTYPE[NPARAM] = norm_type(ptype)
    NPARAM = NPARAM + 1
    np = np + 1
    if cur_is(TK_COMMA) == 1 {
      adv()
    } else {
      break
    }
  }
  expect(TK_RPAREN)
  let ret = ""
  if cur_is(TK_ARROW) == 1 {
    adv()
    if cur_is(TK_IDENT) == 0 {
      err("expected a return type, found " + describe(TI))
    }
    ret = TV[TI]
    adv()
    if cur_is(TK_LBRACKET) == 1 {
      adv()
      if cur_is(TK_RBRACKET) == 0 {
        err("expected ']' after an array type, found " + describe(TI))
      }
      adv()
      ret = ret + "[]"
    }
  }
  if type_known(norm_type(ret)) == 0 {
    err_at("unknown type '" + ret + "'", spos, sline)
  }
  if np > 6 {
    err_at("'" + name + "' has " + np + " parameters; at most 6 are supported", spos, sline)
  }
  SLOT = np
  CUR_RET = norm_type(ret)
  FN_RET[fidx] = CUR_RET
  FN_NPARAM[fidx] = np
  NFN = NFN + 1
  parse_block()
  if str_eq(CUR_RET, "") == 1 {
    FN_RET[fidx] = CUR_INFER
  }
  el("  xor eax, eax")
  el(".Lret_" + name + ":")
  el("  mov rsp, rbp")
  el("  pop rbp")
  el("  ret")
  NSYM = BASE
}

fn parse_global() {
  adv()
  if cur_is(TK_IDENT) == 0 {
    err("expected a variable name, found " + describe(TI))
  }
  let name = TV[TI]
  let spos = TP[TI - 1]
  let sline = TL[TI - 1]
  let g = pre_global_find(name)
  if g < 0 {
    g = NGLOB
  }
  if g < 4000 && G_DEFINED[g] == 1 {
    err_at("global '" + name + "' defined twice", spos, sline)
  }
  if g < 4000 {
    G_DEFINED[g] = 1
  }
  if g >= NGLOB {
    NGLOB = g + 1
  }
  adv()
  expect(TK_ASSIGN)
  el(".Lfn_g" + g + ":")
  el("  push rbp")
  el("  mov rbp, rsp")
  el("  sub rsp, 4096")
  fn_enter("g" + g, 0)
  expr()
  el("  mov " + gslot(g) + ", rax")
  el("  mov rsp, rbp")
  el("  pop rbp")
  el("  ret")
  if GTYPE == "" {
    declare(name, 0 - g - 1, "")
  } else {
    declare(name, 0 - g - 1, GTYPE)
  }
}

# `const NAME = <literal>` was collected by the prescan, so this only walks
# over the declaration (and reports a value that is not a literal).
fn parse_const_decl() {
  let cpos = TP[TI]
  let cline = TL[TI]
  adv()
  if cur_is(TK_IDENT) == 0 {
    err("expected a const name")
  }
  let cname = TV[TI]
  adv()
  if cur_is(TK_ASSIGN) == 0 {
    err("expected '=' after the const name")
  }
  adv()
  let sign = 1
  if cur_is(TK_MINUS) == 1 {
    sign = 0 - 1
    adv()
  }
  if cur_is(TK_INT) == 1 {
    adv()
    return
  }
  if sign == 1 && cur_is(TK_STR) == 1 {
    adv()
    return
  }
  err_at("const '" + cname + "' needs an int or string literal", cpos, cline)
}

fn compile_program() {
  while cur_is(TK_EOF) == 0 {
    if cur_is(TK_SEMI) == 1 {
      adv()
    } else if cur_kw(KW_STRUCT) == 1 {
      parse_struct()
    } else if cur_kw(KW_FN) == 1 {
      parse_fn()
    } else if cur_kw(KW_LET) == 1 {
      parse_global()
    } else if cur_kw(KW_CONST) == 1 {
      parse_const_decl()
    } else {
      err("expected 'fn', 'struct', a global 'let' or a 'const', found " + describe(TI))
    }
  }
  let mi = fn_find(ENTRY_NAME)
  if mi < 0 {
    err_at("program needs a 'fn " + ENTRY_NAME + "()'", 0, 1)
  }
  if FN_NPARAM[mi] != 0 {
    err_at("'" + ENTRY_NAME + "' takes no parameters", FN_POS[mi], FN_LINE[mi])
  }
  let ci = 0
  while ci < NCALLED {
    if fn_find(CALLED_NAME[ci]) < 0 {
      err_at("unknown function '" + CALLED_NAME[ci] + "'", CALLED_POS[ci], CALLED_LINE[ci])
    }
    ci = ci + 1
  }
}

# The header is emitted before the bodies, so the usual use flags are not set
# yet.  An identifier followed by '(' is a call (or a definition of that name),
# which is a safe superset of the programs that need the startup capture.
fn scan_needs_args() {
  let i = 0
  while i + 1 < NT {
    if TK[i] == TK_IDENT && TK[i + 1] == TK_LPAREN {
      if str_eq(TV[i], "argc") == 1 {
        U_ARGC = 1
      }
      # argv() bounds-checks against argc, so it needs the count too.
      if str_eq(TV[i], "argv") == 1 {
        U_ARGV = 1
        U_ARGC = 1
      }
      # env() reads the argc/argv strings from the same startup capture.
      if str_eq(TV[i], "env") == 1 {
        U_ARGC = 1
        U_ARGV = 1
      }
    }
    i = i + 1
  }
}

# ---------------------------------------------------------------- emission
fn emit_header() {
  el(".intel_syntax noprefix")
  el(".text")
  el(".globl _start")
  el("_start:")
  if FREE_MODE == 1 {
    el("  call .Lfn___init")
    el("  call .Lfn_" + ENTRY_NAME)
    el(".Lk_halt:")
    el("  hlt")
    el("  jmp .Lk_halt")
    return
  }
  # Only programs that read argc() or argv() pay for the startup capture.
  if U_ARGC == 1 {
    el("  mov rax, [rsp]")
    el("  mov [rip + __t_argc_val], rax")
  }
  if U_ARGV == 1 {
    el("  lea rax, [rsp + 8]")
    el("  mov [rip + __t_argv_val], rax")
  }
  el("  call .Lfn___init")
  el("  call .Lfn_" + ENTRY_NAME)
  el("  mov edi, eax")
  el("  mov eax, 60")
  el("  syscall")
}

fn emit_init() {
  el(".Lfn___init:")
  el("  push rbp")
  el("  mov rbp, rsp")
  let g = 0
  while g < NGLOB {
    el("  call .Lfn_g" + g)
    g = g + 1
  }
  el("  mov rsp, rbp")
  el("  pop rbp")
  el("  ret")
}

fn emit_data() {
  el(".data")
  el("__t_empty:")
  el("  .byte 0")
  if FREE_MODE == 0 {
    el("__t_oom_msg:")
    el("  .ascii \"tlang: out of memory\"")
    el("  .byte 10")
    if U_ALLOC == 1 {
      el("__t_bad_alloc_msg:")
      el("  .ascii \"tlang: invalid allocation size\"")
      el("  .byte 10")
    }
    if U_BOUNDS == 1 {
      el("__t_oob_msg:")
      el("  .ascii \"tlang: index out of bounds\"")
      el("  .byte 10")
    }
  }
  let i = 1
  while i <= NSTR {
    el("S" + i + ":")
    el("  .ascii \"" + P_TEXT[i] + "\"")
    el("  .byte 0")
    i = i + 1
  }
  let g = 0
  while g < NGLOB {
    el("G" + g + ":")
    el("  .quad 0")
    g = g + 1
  }
  let t = 0
  while t < NTAB {
    el("  .align 8")
    el(TAB_LABEL[t] + ":")
    let idx = TAB_BASE[t]
    let n = TAB_COUNT[t]
    let k = 0
    while k < n {
      el("  .quad " + TAB_TARGET[idx + k])
      k = k + 1
    }
    t = t + 1
  }
}

fn emit_bss() {
  el(".bss")
  el(".align 16")
  el("__t_switch_val:")
  el("  .zero 8")
  # A kernel image has no hosted arena or stdio buffers; the kernel runtime
  # owns its own state.
  if FREE_MODE == 0 {
    el("__t_arena:")
    el("  .zero 67108864")
    el("__t_arena_pos:")
    el("  .zero 8")
    el("__t_buf:")
    el("  .zero 256")
    el("__t_buf_len:")
    el("  .zero 8")
    el("__t_buf_pos:")
    el("  .zero 8")
    el("__t_argc_val:")
    el("  .zero 8")
    el("__t_argv_val:")
    el("  .zero 8")
    # read_dir's four buffered directory cursors.  BSS costs no file bytes, but
    # emitting it only for programs that iterate directories keeps the symbol
    # set of a program that never opens one unchanged.
    if U_GEN_READ_DIR == 1 || U_GEN_CLOSE_DIR == 1 {
      el("__t_rd_fd:")
      el("  .zero 32")
      el("__t_rd_pos:")
      el("  .zero 32")
      el("__t_rd_len:")
      el("  .zero 32")
      el("__t_rd_buf:")
      el("  .zero 16384")
    }
  }
  el(".section .note.GNU-stack,\"\",@progbits")
}

# ---------------------------------------------------------------- runtime
fn need_strlen() -> int {
  # The kernel runtime writes strings with its own loop, so printed text does
  # not pull in strlen there.
  if FREE_MODE == 1 {
    if U_CONCAT == 1 || U_LEN == 1 || U_SLICE == 1 {
      return 1
    }
    return 0
  }
  if U_PRINT == 1 || U_PRINT_ERR == 1 || U_CONCAT == 1 || U_LEN == 1 {
    return 1
  }
  if U_WRITEFILE == 1 || U_APPENDFILE == 1 {
    return 1
  }
  return 0
}

fn need_alloc() -> int {
  # In a kernel the allocator comes from the kernel runtime.
  if FREE_MODE == 1 {
    return 0
  }
  if U_ALLOC == 1 || U_APPEND == 1 || U_ITOA == 1 || U_FTOA == 1 || U_CONCAT == 1 || U_SLICE == 1 || U_READFILE == 1 {
    return 1
  }
  if U_INPUT == 1 {
    return 1
  }
  return 0
}

fn emit_runtime() {
  if U_SLICE == 1 || U_CONCAT == 1 {
    U_BOUNDS = 1
  }
  if need_strlen() == 1 {
    rt_emit_strlen()
  }
  if U_PRINT == 1 && FREE_MODE == 0 {
    rt_emit_print()
  }
  if U_PRINT_ERR == 1 && FREE_MODE == 0 {
    rt_emit_print_err()
  }
  if U_PRINT_INT == 1 && FREE_MODE == 0 {
    rt_emit_print_int()
  }
  if U_PRINT_CHAR == 1 && FREE_MODE == 0 {
    rt_emit_print_char()
  }
  if need_alloc() == 1 {
    U_ALLOC = 1
    rt_emit_alloc()
  }
  if U_BOUNDS == 1 && FREE_MODE == 0 {
    rt_emit_bounds_fail()
  }
  if U_APPEND == 1 {
    rt_emit_append()
  }
  if U_FTOA == 1 {
    rt_emit_ftoa()
  }
  if U_ITOA == 1 {
    rt_emit_itoa()
  }
  if U_CONCAT == 1 {
    rt_emit_concat()
  }
  if U_SLICE == 1 {
    rt_emit_slice()
  }
  if U_STRCMP == 1 {
    rt_emit_str_cmp()
  }
  if U_STROFFSET == 1 {
    rt_emit_str_offset()
  }
  if U_STRDIFF == 1 {
    rt_emit_str_diff()
  }
  if U_CLZ == 1 { rt_emit_clz() }
  if U_RBIT == 1 { rt_emit_rbit() }
  if U_BSWAP16 == 1 { rt_emit_bswap16() }
  if U_BSWAP32 == 1 { rt_emit_bswap32() }
  if U_BSWAP64 == 1 { rt_emit_bswap64() }
  if U_SEXT8 == 1 { rt_emit_sext8() }
  if U_SEXT16 == 1 { rt_emit_sext16() }
  if U_SEXT32 == 1 { rt_emit_sext32() }
  if U_UDIV == 1 { rt_emit_udiv() }
  if U_UMOD == 1 { rt_emit_umod() }
  if U_ROL8 == 1 { rt_emit_rol8() }
  if U_ROR8 == 1 { rt_emit_ror8() }
  if U_LD8 == 1 { rt_emit_ld8() }
  if U_LD16 == 1 { rt_emit_ld16() }
  if U_LD32 == 1 { rt_emit_ld32() }
  if U_LD64 == 1 { rt_emit_ld64() }
  if U_ST8 == 1 { rt_emit_st8() }
  if U_ST16 == 1 { rt_emit_st16() }
  if U_ST32 == 1 { rt_emit_st32() }
  if U_ST64 == 1 { rt_emit_st64() }
  if U_MEMCPY == 1 { rt_emit_memcpy() }
  if U_MEMSET == 1 { rt_emit_memset() }
  if U_STREQ == 1 {
    rt_emit_str_eq()
  }
  if U_INT == 1 {
    rt_emit_int()
  }
  if U_INPUT == 1 {
    rt_emit_read_line()
    rt_emit_input()
  }
  if U_READFILE == 1 {
    rt_emit_read_file()
  }
  if U_FILESIZE == 1 {
    rt_emit_file_size()
  }
  if U_SOCK == 1 {
    rt_emit_sock_unix()
  }
  if U_FDREAD == 1 {
    rt_emit_fd_read()
  }
  if U_FDWRITE == 1 {
    rt_emit_fd_write()
  }
  if U_FDPOLL == 1 {
    rt_emit_fd_poll()
  }
  if U_NEWBUF == 1 {
    rt_emit_newbuf()
  }
  if U_SHM == 1 {
    rt_emit_shm()
  }
  if U_FDPWRITE == 1 {
    rt_emit_fd_pwrite()
  }
  if U_FDSEND == 1 {
    rt_emit_fd_send()
  }
  if U_EXIT == 1 && FREE_MODE == 0 {
    rt_emit_exit()
  }
  if U_ARGC == 1 {
    rt_emit_argc()
  }
  if U_ARGV == 1 {
    rt_emit_argv()
  }
  if U_ARENA_MARK == 1 {
    rt_emit_arena_mark()
  }
  if U_ARENA_RELEASE == 1 {
    rt_emit_arena_release()
  }
  if U_WRITEFILE == 1 {
    rt_emit_write_file()
  }
  if U_APPENDFILE == 1 {
    rt_emit_append_file()
  }
  if U_FILEEXISTS == 1 {
    rt_emit_file_exists()
  }
  if U_ENV == 1 {
    rt_emit_env()
  }
  if U_FLOAT == 1 {
    rt_emit_fconst()
    rt_emit_fadd()
    rt_emit_fsub()
    rt_emit_fmul()
    rt_emit_fdiv()
    rt_emit_fcmp()
    rt_emit_itof()
    rt_emit_ftoi()
    rt_emit_fneg()
    rt_emit_fabs()
    rt_emit_fsqrt()
  }
  if U_PRINTFLOAT == 1 {
    rt_emit_print_float()
  }
  emit_generated_runtime()
}


# ---------------------------------------------------------------- modules
let IMP_SEEN = alloc(1000, str)
let NIMP = 0
# The import that led to the file being loaded, for a diagnostic that names the
# importing file rather than only the missing target.
let IMP_FROM = ""
# Imports are copied into one flat source buffer.  Concatenating line by line
# allocates a fresh string per line, which is quadratic once the compiler's own
# source has an import.
let SRC_CAP = 4194304
let SRC_BUF = ""
let SRC_LEN = 0

fn map_add(p: str, ln: int) {
  if NMAP >= CAP {
    print_err("tcomp: program is too large\n")
    exit(1)
  }
  NMAP = NMAP + 1
  MAP_PATH[NMAP] = p
  MAP_LINE[NMAP] = ln
}

fn map_file(src: str, path: str) {
  let i = 0
  let ln = 1
  while i < len(src) {
    if src[i] == 10 {
      map_add(path, ln)
      ln = ln + 1
    }
    i = i + 1
  }
  if len(src) > 0 && src[len(src) - 1] != 10 {
    map_add(path, ln)
  }
}

fn dir_of(p: str) -> str {
  let i = len(p) - 1
  while i >= 0 {
    if p[i] == 47 {
      return slice(p, 0, i)
    }
    i = i - 1
  }
  return "."
}

fn join_path(base: str, rel: str) -> str {
  if len(rel) > 0 && rel[0] == 47 {
    return rel
  }
  if str_eq(base, ".") == 1 {
    return rel
  }
  return base + "/" + rel
}

fn import_seen(p: str) -> int {
  let i = 0
  while i < NIMP {
    if str_eq(IMP_SEEN[i], p) == 1 {
      return 1
    }
    i = i + 1
  }
  return 0
}

fn import_target(line: str) -> str {
  let i = 0
  while i < len(line) && (line[i] == 32 || line[i] == 9) {
    i = i + 1
  }
  if i + 6 > len(line) {
    return ""
  }
  if str_eq(slice(line, i, 6), "import") != 1 {
    return ""
  }
  i = i + 6
  if i >= len(line) || (line[i] != 32 && line[i] != 9) {
    return ""
  }
  while i < len(line) && (line[i] == 32 || line[i] == 9) {
    i = i + 1
  }
  if i >= len(line) || line[i] != 34 {
    return ""
  }
  i = i + 1
  let j = i
  while j < len(line) && line[j] != 34 {
    j = j + 1
  }
  if j >= len(line) {
    return ""
  }
  return slice(line, i, j - i)
}

fn buf_add(s: str) {
  let i = 0
  while i < len(s) {
    if SRC_LEN >= SRC_CAP {
      print_err("tcomp: source is too large\n")
      exit(1)
    }
    SRC_BUF[SRC_LEN] = s[i]
    SRC_LEN = SRC_LEN + 1
    i = i + 1
  }
}

fn load_into(path: str) {
  if import_seen(path) == 1 {
    print_err(IMP_FROM + ": error: import cycle or duplicate: " + path + "\n")
    exit(1)
  }
  if NIMP >= 1000 {
    print_err("tcomp: too many imports\n")
    exit(1)
  }
  if file_exists(path) != 1 {
    print_err(IMP_FROM + ": error: cannot read " + path + "\n")
    exit(1)
  }
  IMP_SEEN[NIMP] = path
  NIMP = NIMP + 1
  let src = read_file(path)
  let found = 0
  let fi = 0
  let fs = 0
  while fi <= len(src) {
    if fi == len(src) || src[fi] == 10 {
      if import_target(slice(src, fs, fi - fs)) != "" {
        found = 1
      }
      fs = fi + 1
    }
    fi = fi + 1
  }
  if found == 0 {
    map_file(src, path)
    buf_add(src)
    return
  }
  let i = 0
  let start = 0
  let lineno = 1
  while i < len(src) {
    if src[i] == 10 {
      let line = slice(src, start, i - start)
      let target = import_target(line)
      if target != "" {
        IMP_FROM = path
        load_into(join_path(dir_of(path), target))
        if SRC_LEN > 0 && SRC_BUF[SRC_LEN - 1] != 10 {
          buf_add("\n")
        }
      } else {
        buf_add(line)
        map_add(path, lineno)
        buf_add("\n")
      }
      start = i + 1
      lineno = lineno + 1
    }
    i = i + 1
  }
  if start < len(src) {
    let line = slice(src, start, len(src) - start)
    let target = import_target(line)
    if target != "" {
      IMP_FROM = path
      load_into(join_path(dir_of(path), target))
    } else {
      buf_add(line)
      map_add(path, lineno)
    }
  }
}

fn load_source(path: str) -> str {
  SRC_LEN = 0
  SRC_BUF = newbuf(SRC_CAP)
  if file_exists(path) != 1 {
    print_err("tcomp: cannot read " + path + "\n")
    exit(1)
  }
  IMP_FROM = path
  load_into(path)
  return slice(SRC_BUF, 0, SRC_LEN)
}

# ---------------------------------------------------------------- entry point
fn print_version() {
  print("tcomp " + TLANG_VERSION + "\n")
}

fn main() {
  if argc() >= 2 && (argv(1) == "--version" || argv(1) == "version") {
    print_version()
    return
  }
  let path = ""
  let i = 1
  while i < argc() {
    let a = argv(i)
    if a == "--freestanding" {
      FREE_MODE = 1
    } else if a == "--no-bounds" {
      NO_BOUNDS = 1
    } else if a == "--entry" {
      i = i + 1
      if i >= argc() {
        print_err("tcomp: --entry needs a function name\n")
        exit(1)
      }
      ENTRY_NAME = argv(i)
    } else if len(a) > 0 && a[0] == 45 {
      print_err("tcomp: unknown option " + a + "\n")
      exit(1)
    } else {
      if path == "" {
        path = a
      }
    }
    i = i + 1
  }
  if path == "" {
    print_err("usage: tcomp [--freestanding] [--no-bounds] [--entry NAME] <file.tl>\n")
    exit(1)
  }
  SRC_PATH = path
  SRC = load_source(path)
  if len(SRC) == 0 {
    print_err("tcomp: cannot read " + path + "\n")
    exit(1)
  }
  lex_all()
  scan_needs_args()
  prescan()
  emit_header()
  predeclare_globals()
  compile_program()
  emit_init()
  emit_runtime()
  emit_data()
  emit_bss()
  while NPB > 0 {
    pb_out(PB[0])
    pb_shift(1)
  }
}
