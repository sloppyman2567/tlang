"""Typed operands and assembly text emission.

Nothing outside this module and `isa` knows how x86 operands are spelled.
"""


class Reg:
    __slots__ = ("name",)

    def __init__(self, name):
        self.name = name

    def __str__(self):
        return self.name

    def __repr__(self):
        return str(self)


class Imm:
    __slots__ = ("v",)

    def __init__(self, v):
        self.v = v

    def __str__(self):
        return str(self.v)


class Mem:
    """A memory operand: [base], [base+disp] or [base + index*scale]."""

    __slots__ = ("base", "disp", "index", "scale", "size")

    def __init__(self, base, disp=0, index=None, scale=8, size=None):
        self.base = base
        self.disp = disp
        self.index = index
        self.scale = scale
        self.size = size

    def as_byte(self):
        return Mem(self.base, self.disp, self.index, self.scale, "byte")

    def __str__(self):
        if self.index is not None:
            core = f"[{self.base} + {self.index}*{self.scale}]"
        elif self.disp:
            core = f"[{self.base}{self.disp:+d}]"
        else:
            core = f"[{self.base}]"
        return f"{self.size} ptr {core}" if self.size else core


class RipMem:
    """RIP-relative memory: [rip + symbol]."""

    __slots__ = ("symbol",)

    def __init__(self, symbol):
        self.symbol = symbol

    def __str__(self):
        return f"[rip + {self.symbol}]"


RAX = Reg("rax")
RBX = Reg("rbx")
RCX = Reg("rcx")
RDX = Reg("rdx")
RSI = Reg("rsi")
RDI = Reg("rdi")
RBP = Reg("rbp")
RSP = Reg("rsp")
R8 = Reg("r8")
R9 = Reg("r9")
R10 = Reg("r10")
R11 = Reg("r11")

AL = Reg("al")
DL = Reg("dl")
AX_LO = Reg("eax")

ARGS = (RDI, RSI, RDX, RCX, R8, R9)


def label(name):
    return f"{name}:"


def mov(d, s):
    return f"  mov {d}, {s}"


def movzx(d, s):
    return f"  movzx {d}, {s}"


def lea(d, s):
    return f"  lea {d}, {s}"


def add(d, s):
    return f"  add {d}, {s}"


def sub(d, s):
    return f"  sub {d}, {s}"


def imul(d, s):
    return f"  imul {d}, {s}"


def and_(d, s):
    return f"  and {d}, {s}"


def or_(d, s):
    return f"  or {d}, {s}"


def shl(d, n):
    return f"  shl {d}, {n}"


def sar(d, n):
    return f"  sar {d}, {n}"


def cmp_(d, s):
    return f"  cmp {d}, {s}"


def test(d, s):
    return f"  test {d}, {s}"


def xor_(d, s):
    return f"  xor {d}, {s}"


def neg(d):
    return f"  neg {d}"


def setcc(cc, reg=AL):
    return f"  set{cc} {reg}"


def jmp(name):
    return f"  jmp {name}"


def je(name):
    return f"  je {name}"


def jne(name):
    return f"  jne {name}"


def jae(name):
    return f"  jae {name}"


def jle(name):
    return f"  jle {name}"


def jl(name):
    return f"  jl {name}"


def jge(name):
    return f"  jge {name}"


def jcc(cc, name):
    return f"  j{cc} {name}"


def call(name):
    return f"  call {name}"


def ret():
    return "  ret"


def push(r):
    return f"  push {r}"


def pop(r):
    return f"  pop {r}"


def leave():
    return "  leave"


def cqo():
    return "  cqo"


def idiv(r):
    return f"  idiv {r}"


def syscall():
    return "  syscall"


def define_label(name):
    return f"{name}:"


SETCC = {"eq": "e", "ne": "ne", "lt": "l", "le": "le", "gt": "g", "ge": "ge"}
