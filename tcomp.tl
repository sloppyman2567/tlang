# tcomp.tl - the tlang compiler, written in tlang.
#
# Single pass: lex the source into token arrays, then walk the tokens emitting
# x86-64 assembly on stdout.  The compiler and language version together.
#
#   tcomp FILE.tl > FILE.s
#   tcomp --version
#   as --64 -mx86-used-note=no -o FILE.o FILE.s
#   ld -s -z noseparate-code --build-id=none -o FILE FILE.o

let TLANG_VERSION = "1.0.0"

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
let NPARAM = 0

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
let U_STROFFSET = 0
let U_STRDIFF = 0

# ---------------------------------------------------------------- output helpers
# The emitter writes one line at a time, but a comparison that feeds a branch is
# only visible as a sequence, so the last few lines wait in PB. Five is exactly
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

fn peep() {
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

fn lx_string() {
  TOK_POS = POS
  let start = POS
  POS = POS + 1
  while POS < len(SRC) {
    let c = SRC[POS]
    if c == 92 {
      POS = POS + 2
    } else {
      if c == 34 {
        break
      }
      POS = POS + 1
    }
  }
  let txt = slice(SRC, start + 1, POS - start - 1)
  POS = POS + 1
  push_tok(TK_STR, 0, txt, LINE)
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
  return c
}

fn lx_char() {
  TOK_POS = POS
  POS = POS + 1
  let v = 0
  if SRC[POS] == 92 {
    v = esc_val(SRC[POS + 1])
    POS = POS + 2
  } else {
    v = SRC[POS]
    POS = POS + 1
  }
  if SRC[POS] == 39 {
    POS = POS + 1
  }
  push_tok(TK_INT, v, "", LINE)
}

fn kw_of(w: str) -> int {
  if str_eq(w, "fn") == 1 {
    return KW_FN
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
    err_at("unexpected character", POS, LINE)
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

fn expect(k: int) {
  if TK[TI] != k {
    err("syntax error")
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

fn bump(name: str, up: int) {
  if lookup(name) == 0 {
    err("unknown variable " + name)
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
      if x == 101 {
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
  if k == TK_SHL || k == TK_SHR {
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
    GTYPE = lt
    return
  }
  if op == TK_PLUS && (lt == "" || lt == "int") && is_ptr_type(GTYPE) == 1 {
    let rt = GTYPE
    el(rcx)
    el("  pop rax")
    el("  shl rax, 3")
    el("  add rax, rcx")
    GTYPE = rt
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
  } else {
    err("unknown operator")
  }
  GTYPE = "int"
}

fn emit_float_bin(op: int, lt: str) {
  if lt == "str" || GTYPE == "str" {
    err("cannot mix a float and a string")
  }
  if op == TK_PERCENT || op == TK_AMP || op == TK_PIPE || op == TK_CARET || op == TK_SHL || op == TK_SHR {
    err("cannot use a bitwise operator on floats")
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
    el("  neg rax")
    GTYPE = "int"
    return
  }
  if cur_is(TK_NOT) == 1 {
    adv()
    parse_unary()
    if GTYPE == "float" {
      err("cannot use ! on a float")
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
      err("cannot use ~ on a float")
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
        el("  movzx rax, byte ptr [rax + rcx]")
        GTYPE = "int"
      } else if has_arr_prefix(bt) == 1 {
        el("  mov rax, [rax + rcx*8]")
        GTYPE = elem_of(bt)
      } else {
        el("  mov rax, [rax + rcx*8]")
        GTYPE = "int"
      }
      expect(TK_RBRACKET)
    } else if cur_is(TK_DOT) == 1 {
      adv()
      let fname = TV[TI]
      adv()
      let sidx = struct_find(GTYPE)
      if sidx < 0 {
        err("field access on a value with no struct type")
      }
      let fi = field_index(sidx, fname)
      if fi < 0 {
        err("struct has no field " + fname)
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
    adv()
    if cur_is(TK_LPAREN) == 1 {
      parse_call(name)
      return
    }
    if lookup(name) == 0 {
      err("unknown variable " + name)
    }
    ld(GSLOT)
    return
  }
  err("expected an expression")
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

fn parse_call(name: str) {
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
  adv()
  let n = 0
  while cur_is(TK_RPAREN) == 0 {
    expr()
    if fi >= 0 && n < FN_NPARAM[fi] {
      let want = FN_PTYPE[FN_PBASE[fi] + n]
      if types_ok(want, GTYPE) == 0 {
        err("argument " + (n + 1) + " of " + name + " should be " + type_word(want) + ", got " + type_word(GTYPE))
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
    err(name + " takes " + FN_NPARAM[fi] + " argument(s), got " + n)
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
    err("wrong number of struct fields")
  }
  el("  mov rax, " + loc(t))
  GTYPE = name
}

fn one_arg() {
  adv()
  expr()
  expect(TK_RPAREN)
}

fn parse_builtin(name: str, kind: int) {
  if kind == 1 {
    one_arg()
    if GTYPE != "" && GTYPE != "int" && GTYPE != "str" {
      err("print() needs a string or an integer")
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
    one_arg()
    if GTYPE != "" && GTYPE != "int" && GTYPE != "str" {
      err("print_err() needs a string or an integer")
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
    one_arg()
    if GTYPE != "" && GTYPE != "int" {
      err("print_int() needs an integer")
    }
    el("  mov rdi, rax")
    el("  call __t_print_int")
    U_PRINT_INT = 1
    GTYPE = "int"
    return
  }
  if kind == 4 {
    one_arg()
    if GTYPE != "" && GTYPE != "int" {
      err("print_char() needs an integer")
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
    one_arg()
    if GTYPE == "float" {
      el("  mov rdi, rax")
      el("  call __t_ftoi")
      U_FLOAT = 1
      GTYPE = "int"
      return
    }
    if GTYPE != "" && GTYPE != "str" {
      err("int() needs a string or a float")
    }
    el("  mov rdi, rax")
    el("  call __t_int")
    U_INT = 1
    GTYPE = "int"
    return
  }
  if kind == 7 {
    one_arg()
    if GTYPE == "float" {
      el("  mov rdi, rax")
      el("  call __t_ftoa")
      U_FTOA = 1
      GTYPE = "str"
      return
    }
    if GTYPE != "" && GTYPE != "int" {
      err("str() needs an integer or a float")
    }
    el("  mov rdi, rax")
    el("  call __t_itoa")
    U_ITOA = 1
    GTYPE = "str"
    return
  }
  if kind == 8 {
    one_arg()
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
      err("slice() needs a string")
    }
    st(t0)
    expect(TK_COMMA)
    let t1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" {
      err("slice() offsets must be integers")
    }
    st(t1)
    expect(TK_COMMA)
    let t2 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" {
      err("slice() offsets must be integers")
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
      err("str_eq() needs two strings")
    }
    st(t0)
    expect(TK_COMMA)
    let t1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" {
      err("str_eq() needs two strings")
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
      err("alloc() needs an integer count")
    }
    st(t)
    if cur_is(TK_COMMA) == 1 {
      adv()
      let tname = TV[TI]
      adv()
      if str_eq(tname, "int") == 0 && str_eq(tname, "str") == 0 && str_eq(tname, "float") == 0 && struct_find(tname) < 0 {
        err("unknown array element type " + tname)
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
    GTYPE = "ptr"
    return
  }
  if kind == 12 {
    one_arg()
    if GTYPE != "" && GTYPE != "str" {
      err("read_file() needs a string path")
    }
    el("  mov rdi, rax")
    el("  call __t_read_file")
    U_READFILE = 1
    GTYPE = "str"
    return
  }
  if kind == 13 {
    one_arg()
    if GTYPE != "" && GTYPE != "int" {
      err("argv() needs an integer index")
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
    one_arg()
    if GTYPE != "" && GTYPE != "str" {
      err("file_size() needs a string path")
    }
    el("  mov rdi, rax")
    el("  call __t_file_size")
    U_FILESIZE = 1
    GTYPE = "int"
    return
  }
  if kind == 18 {
    one_arg()
    if GTYPE != "" && GTYPE != "str" {
      err("sock() needs a string path")
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
    if GTYPE != "" && GTYPE != "int" { err("fd_read() needs an integer descriptor") }
    st(a0)
    expect(TK_COMMA)
    let a1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" { err("fd_read() needs a string buffer") }
    st(a1)
    expect(TK_COMMA)
    let a2 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" { err("fd_read() needs an integer length") }
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
    if GTYPE != "" && GTYPE != "int" { err("fd_write() needs an integer descriptor") }
    st(b0)
    expect(TK_COMMA)
    let b1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" { err("fd_write() needs a string buffer") }
    st(b1)
    expect(TK_COMMA)
    let b2 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" { err("fd_write() needs an integer length") }
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
    if GTYPE != "" && GTYPE != "int" { err("fd_poll() needs an integer descriptor") }
    st(p0)
    expect(TK_COMMA)
    let p1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" { err("fd_poll() needs an integer timeout") }
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
      err("str_offset() needs a string")
    }
    st(s0)
    expect(TK_COMMA)
    let s1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" {
      err("str_offset() needs an integer offset")
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
      err("str_diff() needs two strings")
    }
    st(d0)
    expect(TK_COMMA)
    let d1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" {
      err("str_diff() needs two strings")
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
    one_arg()
    if GTYPE != "" && GTYPE != "int" { err("newbuf() needs an integer size") }
    el("  mov rdi, rax")
    el("  call __t_newbuf")
    U_NEWBUF = 1
    U_ALLOC = 1
    GTYPE = "str"
    return
  }
  if kind == 32 {
    one_arg()
    if GTYPE != "" && GTYPE != "int" { err("shm() needs an integer size") }
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
    if GTYPE != "" && GTYPE != "int" { err("fd_pwrite() needs an integer descriptor") }
    st(q0)
    expect(TK_COMMA)
    let q1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" { err("fd_pwrite() needs an integer offset") }
    st(q1)
    expect(TK_COMMA)
    let q2 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" { err("fd_pwrite() needs a string buffer") }
    st(q2)
    expect(TK_COMMA)
    let q3 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" { err("fd_pwrite() needs an integer length") }
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
    if GTYPE != "" && GTYPE != "int" { err("fd_send() needs an integer descriptor") }
    st(v0)
    expect(TK_COMMA)
    let v1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" { err("fd_send() needs a string buffer") }
    st(v1)
    expect(TK_COMMA)
    let v2 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" { err("fd_send() needs an integer length") }
    st(v2)
    expect(TK_COMMA)
    let v3 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "int" { err("fd_send() needs an integer descriptor to pass") }
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
    one_arg()
    if GTYPE != "" && GTYPE != "int" {
      err("arena_release() needs an integer mark")
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
      err("write_file() needs a string path")
    }
    st(f0)
    expect(TK_COMMA)
    let f1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" {
      err("write_file() needs string data")
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
      err("append_file() needs a string path")
    }
    st(g0)
    expect(TK_COMMA)
    let g1 = tmp()
    expr()
    if GTYPE != "" && GTYPE != "str" {
      err("append_file() needs string data")
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
    one_arg()
    if GTYPE != "" && GTYPE != "str" {
      err("file_exists() needs a string path")
    }
    el("  mov rdi, rax")
    el("  call __t_file_exists")
    U_FILEEXISTS = 1
    GTYPE = "int"
    return
  }
  if kind == 28 {
    one_arg()
    if GTYPE == "int" {
      el("  mov rdi, rax")
      el("  call __t_itof")
      U_FLOAT = 1
    } else if GTYPE != "" && GTYPE != "float" {
      err("float() needs an integer or a float")
    }
    GTYPE = "float"
    return
  }
  if kind == 29 {
    one_arg()
    if GTYPE != "" && GTYPE != "float" {
      err("print_float() needs a float")
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
    one_arg()
    if GTYPE != "" && GTYPE != "float" {
      err("sqrt() needs a float")
    }
    el("  mov rdi, rax")
    el("  call __t_fsqrt")
    U_FLOAT = 1
    GTYPE = "float"
    return
  }
  if kind == 31 {
    one_arg()
    if GTYPE != "" && GTYPE != "float" {
      err("fabs() needs a float")
    }
    el("  mov rdi, rax")
    el("  call __t_fabs")
    U_FLOAT = 1
    GTYPE = "float"
    return
  }
  one_arg()
  if GTYPE != "" && GTYPE != "int" {
    err("exit() needs an integer status")
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
  if ty != "" && str_eq(ty, "int") == 0 && str_eq(ty, "str") == 0 {
    err("switch needs an int or a string")
  }
  let s = tmp()
  st(s)
  skip_semis()
  expect(TK_LBRACE)
  let end = newl()
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
      let next = newl()
      while 1 {
        if str_eq(ty, "str") == 1 {
          if cur_is(TK_STR) == 0 {
            err("case value for a string switch must be a string")
          }
          let lb = intern(TV[TI])
          adv()
          el("  lea rsi, [rip + " + lb + "]")
          el("  mov rdi, " + loc(s))
          el("  call __t_str_eq")
          U_STREQ = 1
          el("  test rax, rax")
          el("  jne " + body)
        } else {
          let neg = 0
          if cur_is(TK_MINUS) == 1 {
            neg = 1
            adv()
          }
          if cur_is(TK_INT) == 0 {
            err("case value for an integer switch must be a number")
          }
          let v = TN[TI]
          if neg == 1 {
            v = 0 - v
          }
          adv()
          el("  mov rax, " + v)
          el("  mov rcx, " + loc(s))
          el("  cmp rcx, rax")
          el("  je " + body)
        }
        if cur_is(TK_COMMA) == 1 {
          adv()
        } else {
          break
        }
      }
      skip_semis()
      el("  jmp " + next)
      el(body + ":")
      push_loop(end, "")
      parse_block()
      NLOOP = NLOOP - 1
      el("  jmp " + end)
      el(next + ":")
      continue
    }
    if cur_kw(KW_ELSE) == 1 {
      adv()
      skip_semis()
      parse_block()
      continue
    }
    err("expected 'case' or 'else' in a switch")
  }
  expect(TK_RBRACE)
  el(end + ":")
}

fn parse_stmt() {
  rt()
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
      err("break outside a loop")
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
      err("continue outside a loop")
    }
    el("  jmp " + target)
    return
  }
  if is_assignment() == 1 {
    parse_assign()
    return
  }
  expr()
}

fn parse_let() {
  adv()
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
    err("unknown variable " + name)
  }
  let s = GSLOT
  let t = GTYPE
  if is_compound(TK[TI]) == 1 {
    let op = TK[TI]
    adv()
    expr()
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
      set_type(name, t)
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
  if cur_is(TK_LBRACKET) == 1 {
    adv()
    el("  mov rax, " + loc(s))
    el("  push rax")
    expr()
    el("  push rax")
    expect(TK_RBRACKET)
    expect(TK_ASSIGN)
    expr()
    el("  mov rdx, rax")
    el("  pop rcx")
    el("  pop rax")
    if t == "str" {
      el("  mov byte ptr [rax + rcx], dl")
    } else {
      el("  mov [rax + rcx*8], rdx")
    }
    return
  }
  if cur_is(TK_DOT) == 1 {
    adv()
    let fname = TV[TI]
    adv()
    let sidx = struct_find(t)
    if sidx < 0 {
      err("field assignment on a value with no struct type")
    }
    let fi = field_index(sidx, fname)
    if fi < 0 {
      err("struct has no field " + fname)
    }
    expect(TK_ASSIGN)
    el("  mov rax, " + loc(s))
    el("  push rax")
    expr()
    el("  mov rdx, rax")
    el("  pop rax")
    el("  mov [rax + " + (8 * fi) + "], rdx")
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
    err("expected 'while' after the do block")
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
  let name = TV[TI]
  adv()
  if cur_kw(KW_IN) == 0 {
    err("expected 'in' after the loop variable")
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
      err("function " + CURFN + " returns " + type_word(CUR_RET) + ", got " + type_word(GTYPE))
    }
    if str_eq(CUR_RET, "") == 1 && str_eq(CUR_INFER, "") == 1 {
      if str_eq(GTYPE, "") == 0 {
        CUR_INFER = GTYPE
      }
    }
  }
  el("  jmp .Lret_" + CURFN)
}

# ---------------------------------------------------------------- declarations
fn parse_struct() {
  adv()
  let name = TV[TI]
  adv()
  expect(TK_LBRACE)
  if NSTRUCT >= 1000 {
    err("too many structs")
  }
  let sidx = NSTRUCT
  NSTRUCT = NSTRUCT + 1
  S_NAME[sidx] = name
  S_FSTART[sidx] = NFIELD
  while cur_is(TK_RBRACE) == 0 && cur_is(TK_EOF) == 0 {
    if cur_is(TK_SEMI) == 1 {
      adv()
    } else if cur_is(TK_COMMA) == 1 {
      adv()
    } else {
      let fname = TV[TI]
      adv()
      let ftype = ""
      if cur_is(TK_COLON) == 1 {
        adv()
        ftype = TV[TI]
        adv()
        if cur_is(TK_LBRACKET) == 1 {
          adv()
          expect(TK_RBRACKET)
          ftype = ftype + "[]"
        }
      }
      if NFIELD >= 8000 {
        err("too many struct fields")
      }
      F_NAME[NFIELD] = fname
      F_TYPE[NFIELD] = norm_type(ftype)
      NFIELD = NFIELD + 1
    }
  }
  expect(TK_RBRACE)
  S_FCOUNT[sidx] = NFIELD - S_FSTART[sidx]
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
  let name = TV[TI]
  adv()
  expect(TK_LPAREN)
  if NFN >= 4000 {
    err("too many functions")
  }
  let fidx = NFN
  FN_NAME[fidx] = name
  FN_PBASE[fidx] = NPARAM
  BASE = NSYM
  el(".Lfn_" + name + ":")
  el("  push rbp")
  el("  mov rbp, rsp")
  el("  sub rsp, 4096")
  fn_enter(name, 0)
  let np = 0
  while cur_is(TK_RPAREN) == 0 {
    let pname = TV[TI]
    adv()
    let ptype = ""
    if cur_is(TK_COLON) == 1 {
      adv()
      ptype = TV[TI]
      adv()
      if cur_is(TK_LBRACKET) == 1 {
        adv()
        expect(TK_RBRACKET)
        ptype = ptype + "[]"
      }
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
    ret = TV[TI]
    adv()
    if cur_is(TK_LBRACKET) == 1 {
      adv()
      expect(TK_RBRACKET)
      ret = ret + "[]"
    }
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
  let name = TV[TI]
  adv()
  expect(TK_ASSIGN)
  let g = NGLOB
  NGLOB = NGLOB + 1
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
    } else {
      err("expected fn, struct or let")
    }
  }
}

# ---------------------------------------------------------------- emission
fn emit_header() {
  el(".intel_syntax noprefix")
  el(".text")
  el(".globl _start")
  el("_start:")
  el("  mov rax, [rsp]")
  el("  mov [rip + __t_argc_val], rax")
  el("  lea rax, [rsp + 8]")
  el("  mov [rip + __t_argv_val], rax")
  el("  call .Lfn___init")
  el("  call .Lfn_main")
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
  el("__t_oom_msg:")
  el("  .ascii \"tlang: out of memory\"")
  el("  .byte 10")
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
}

fn emit_bss() {
  el(".bss")
  el(".align 16")
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
  el(".section .note.GNU-stack,\"\",@progbits")
}

# ---------------------------------------------------------------- runtime
fn need_strlen() -> int {
  if U_PRINT == 1 || U_PRINT_ERR == 1 || U_CONCAT == 1 || U_LEN == 1 {
    return 1
  }
  if U_WRITEFILE == 1 || U_APPENDFILE == 1 {
    return 1
  }
  return 0
}

fn need_alloc() -> int {
  if U_ALLOC == 1 || U_APPEND == 1 || U_ITOA == 1 || U_FTOA == 1 || U_CONCAT == 1 || U_SLICE == 1 || U_READFILE == 1 {
    return 1
  }
  if U_INPUT == 1 {
    return 1
  }
  return 0
}

fn emit_runtime() {
  if need_strlen() == 1 {
    rt_emit_strlen()
  }
  if U_PRINT == 1 {
    rt_emit_print()
  }
  if U_PRINT_ERR == 1 {
    rt_emit_print_err()
  }
  if U_PRINT_INT == 1 {
    rt_emit_print_int()
  }
  if U_PRINT_CHAR == 1 {
    rt_emit_print_char()
  }
  if need_alloc() == 1 {
    rt_emit_alloc()
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
  if U_EXIT == 1 {
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
}


# ---------------------------------------------------------------- modules
let IMP_SEEN = alloc(1000, str)
let NIMP = 0
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
    print_err("tcomp: import cycle or duplicate: " + path + "\n")
    exit(1)
  }
  if NIMP >= 1000 {
    print_err("tcomp: too many imports\n")
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
  if argc() < 2 {
    print_err("usage: tcomp <file.tl>\n")
    exit(1)
  }
  let path = argv(1)
  SRC_PATH = path
  SRC = load_source(path)
  if len(SRC) == 0 {
    print_err("tcomp: cannot read " + path + "\n")
    exit(1)
  }
  lex_all()
  emit_header()
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
