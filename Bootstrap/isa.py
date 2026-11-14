"""Instruction selection: each IR op expands through a fixed template.

Nothing here decides *what* to compute; it only knows how to express one IR
instruction with x86-64 operands.
"""

from .emit import (
    AL, ARGS, AX_LO, DL, RAX, RBP, RCX, RDX, RSP,
    Imm, Mem, RipMem, add, and_, call, cmp_, cqo, define_label, idiv, imul, jcc,
    jmp, je, jne, leave, mov, movzx, neg, or_, pop, push, ret, sar, setcc, SETCC,
    shl, sub, syscall, test, xor_,
)
from .ir import TEMP_BASE
from .opt import peephole
from .runtime import BAD_ALLOC_MSG, BSS, OOB_MSG, OOM_MSG, resolve_used


def slot_mem(fn, slot):
    """Map a virtual slot to a frame location (negative slots are globals)."""
    if slot < 0:
        return RipMem(f".Lglob{-slot - 1}")
    if slot >= TEMP_BASE:
        index = fn.nperm + (slot - TEMP_BASE)
    else:
        index = slot
    return Mem(RBP, -8 * (index + 1))


def fits32(value):
    return -(1 << 31) <= value < (1 << 31)


def mem_operand(fn, slot, size="QWORD"):
    """A memory operand with an explicit size, for read-modify-write forms."""
    return f"{size} PTR {slot_mem(fn, slot)}"


def _store(fn, dst):
    return mov(slot_mem(fn, dst), RAX)


ARITH_INS = {"add": add, "sub": sub, "mul": imul,
             "and": and_, "or": or_, "xor": xor_}
FP_BIN = {"add": "addsd", "sub": "subsd", "mul": "mulsd", "div": "divsd"}

# Kinds x86 offers in a read-modify-write form (imul does not, mul is not a
# binary-op name).
RMW = {"add": "add", "sub": "sub", "and": "and", "or": "or", "xor": "xor"}

SHIFT = {"shl": "shl", "shr": "sar"}      # >> is arithmetic: ints are signed


def expand(fn, ins, out):
    op = ins[0]

    if op == "imm":
        _, dst, value = ins
        if value == 0:
            out.append(xor_(AX_LO, AX_LO))
            out.append(_store(fn, dst))
        elif fits32(value):
            # One instruction instead of materialising in rax first.
            out.append(mov(mem_operand(fn, dst), Imm(value)))
        else:
            out.append(mov(RAX, Imm(value)))
            out.append(_store(fn, dst))

    elif op == "lea":
        _, dst, name = ins
        out.append(f"  lea rax, [rip + {name}]")
        out.append(_store(fn, dst))

    elif op == "mov":
        _, dst, src = ins
        if dst != src:
            out.append(mov(RAX, slot_mem(fn, src)))
            out.append(mov(slot_mem(fn, dst), RAX))

    elif op == "fbin":
        _, kind, dst, a, b = ins
        out.append(f"  movq xmm0, {mem_operand(fn, a)}")
        out.append(f"  movq xmm1, {mem_operand(fn, b)}")
        out.append(f"  {FP_BIN[kind]} xmm0, xmm1")
        out.append(f"  movq {mem_operand(fn, dst)}, xmm0")

    elif op == "ffma":
        _, dst, a, b, c = ins
        out.append(f"  movq xmm0, {mem_operand(fn, a)}")
        out.append(f"  movq xmm1, {mem_operand(fn, b)}")
        out.append("  mulsd xmm0, xmm1")
        out.append(f"  movq xmm1, {mem_operand(fn, c)}")
        out.append("  addsd xmm0, xmm1")
        out.append(f"  movq {mem_operand(fn, dst)}, xmm0")

    elif op == "bin":
        _, kind, dst, a, b = ins
        if kind in ("div", "mod"):
            out.append(mov(RAX, slot_mem(fn, a)))
            out.append(cqo())
            out.append(mov(RCX, slot_mem(fn, b)))
            out.append(idiv(RCX))
            if kind == "mod":
                out.append(mov(RAX, RDX))
            out.append(_store(fn, dst))
        elif kind in SHIFT:
            # A variable shift count has to arrive in cl.
            out.append(mov(RAX, slot_mem(fn, a)))
            out.append(mov(RCX, slot_mem(fn, b)))
            out.append(f"  {SHIFT[kind]} rax, cl")
            out.append(_store(fn, dst))
        elif dst == a and kind in RMW:
            # x86 has no memory-destination form except the accumulator one, so
            # the result has to come back through a register; writing straight
            # into the destination saves the third instruction.
            out.append(mov(RAX, slot_mem(fn, b)))
            out.append(f"  {RMW[kind]} {mem_operand(fn, dst)}, rax")
        else:
            out.append(mov(RAX, slot_mem(fn, a)))
            out.append(ARITH_INS[kind](RAX, slot_mem(fn, b)))
            out.append(_store(fn, dst))

    elif op == "bink":
        _, kind, dst, a, k = ins
        if kind in ("div", "mod"):
            out.append(mov(RAX, slot_mem(fn, a)))
            out.append(cqo())
            out.append(mov(RCX, Imm(k)))
            out.append(idiv(RCX))
            if kind == "mod":
                out.append(mov(RAX, RDX))
            out.append(_store(fn, dst))
        elif kind in SHIFT:
            amount = k & 63
            if dst == a:
                out.append(f"  {SHIFT[kind]} {mem_operand(fn, dst)}, {amount}")
            else:
                out.append(mov(RAX, slot_mem(fn, a)))
                out.append(f"  {SHIFT[kind]} rax, {amount}")
                out.append(_store(fn, dst))
        elif dst == a and kind in RMW and fits32(k):
            # add qword ptr [rbp-8], 1: the whole update in one instruction.
            out.append(f"  {kind} {mem_operand(fn, dst)}, {k}")
        else:
            out.append(mov(RAX, slot_mem(fn, a)))
            if fits32(k):
                out.append(ARITH_INS[kind](RAX, Imm(k)))
            else:
                out.append(mov(RCX, Imm(k)))
                out.append(ARITH_INS[kind](RAX, RCX))
            out.append(_store(fn, dst))

    elif op == "cmp":
        _, cc, dst, a, b = ins
        out.append(mov(RAX, slot_mem(fn, a)))
        out.append(cmp_(RAX, slot_mem(fn, b)))
        out.append(setcc(SETCC[cc]))
        out.append(movzx(RAX, AL))
        out.append(_store(fn, dst))

    elif op == "cmpk":
        _, cc, dst, a, k = ins
        if fits32(k):
            out.append(f"  cmp {mem_operand(fn, a)}, {k}")
        else:
            out.append(mov(RAX, slot_mem(fn, a)))
            out.append(mov(RCX, Imm(k)))
            out.append(cmp_(RAX, RCX))
        out.append(setcc(SETCC[cc]))
        out.append(movzx(RAX, AL))
        out.append(_store(fn, dst))

    elif op == "neg":
        _, dst, a = ins
        out.append(mov(RAX, slot_mem(fn, a)))
        out.append(neg(RAX))
        out.append(_store(fn, dst))

    elif op == "not":
        _, dst, a = ins
        out.append(mov(RAX, slot_mem(fn, a)))
        out.append(test(RAX, RAX))
        out.append(setcc("e"))
        out.append(movzx(RAX, AL))
        out.append(_store(fn, dst))

    elif op == "bnot":
        _, dst, a = ins
        out.append(mov(RAX, slot_mem(fn, a)))
        out.append("  not rax")
        out.append(_store(fn, dst))

    elif op == "lab":
        out.append(define_label(ins[1]))

    elif op == "jmp":
        out.append(jmp(ins[1]))

    elif op in ("jz", "jnz"):
        _, src, target = ins
        out.append(f"  cmp {mem_operand(fn, src)}, 0")
        out.append(je(target) if op == "jz" else jne(target))

    elif op in ("jcc", "jcck"):
        _, cc, a, b, target = ins
        if op == "jcc":
            out.append(mov(RAX, slot_mem(fn, a)))
            out.append(cmp_(RAX, slot_mem(fn, b)))
        elif fits32(b):
            out.append(f"  cmp {mem_operand(fn, a)}, {b}")
        else:
            out.append(mov(RAX, slot_mem(fn, a)))
            out.append(mov(RCX, Imm(b)))
            out.append(cmp_(RAX, RCX))
        out.append(jcc(SETCC[cc], target))

    elif op in ("call", "bcall"):
        _, dst, target, args = ins
        for reg, arg in zip(ARGS, args):
            out.append(mov(reg, slot_mem(fn, arg)))
        out.append(call(target if op == "bcall" else f".Lfn_{target}"))
        if dst is not None:      # None: the result is never read
            out.append(_store(fn, dst))

    elif op == "ret":
        out.append(mov(RAX, slot_mem(fn, ins[1])))
        out.append(jmp(f".Lret_{fn.name}"))

    elif op == "ret0":
        out.append(xor_(AX_LO, AX_LO))
        out.append(jmp(f".Lret_{fn.name}"))

    elif op == "aloc":
        _, dst, count = ins
        out.append(mov(ARGS[0], slot_mem(fn, count)))
        out.append(call("__t_alloc"))
        out.append(_store(fn, dst))

    elif op in ("ld8", "st8", "ldb", "stb"):
        if op == "ld8":
            _, dst, base, idx = ins
            out.append(mov(RAX, slot_mem(fn, base)))
            out.append(mov(RCX, slot_mem(fn, idx)))
            out.append(mov(RAX, Mem(RAX, index=RCX)))
            out.append(_store(fn, dst))
        elif op == "st8":
            _, base, idx, val = ins
            out.append(mov(RAX, slot_mem(fn, base)))
            out.append(mov(RCX, slot_mem(fn, idx)))
            out.append(mov(RDX, slot_mem(fn, val)))
            out.append(mov(Mem(RAX, index=RCX), RDX))
        elif op == "ldb":
            _, dst, base, idx = ins
            out.append(mov(RAX, slot_mem(fn, base)))
            out.append(mov(RCX, slot_mem(fn, idx)))
            out.append(movzx(RAX, Mem(RAX, index=RCX, scale=1, size="byte")))
            out.append(_store(fn, dst))
        else:
            _, base, idx, val = ins
            out.append(mov(RAX, slot_mem(fn, base)))
            out.append(mov(RCX, slot_mem(fn, idx)))
            out.append(mov(RDX, slot_mem(fn, val)))
            out.append(mov(Mem(RAX, index=RCX, scale=1, size="byte"), DL))

    elif op == "fld":
        _, dst, base, off = ins
        out.append(mov(RAX, slot_mem(fn, base)))
        out.append(mov(RAX, Mem(RAX, off)))
        out.append(_store(fn, dst))

    elif op == "fst":
        _, base, off, val = ins
        out.append(mov(RAX, slot_mem(fn, base)))
        out.append(mov(RCX, slot_mem(fn, val)))
        out.append(mov(Mem(RAX, off), RCX))

    else:
        raise AssertionError(f"unknown IR op {op!r}")


def emit_function(fn):
    lines = [define_label(f".Lfn_{fn.name}"), push(RBP), mov(RBP, RSP)]
    frame = 16 * ((fn.nslots * 8 + 15) // 16)
    if frame:
        lines.append(sub(RSP, Imm(frame)))
    for i, _param in enumerate(fn.params):
        lines.append(mov(slot_mem(fn, i), ARGS[i]))

    body = []
    for ins in fn.ins:
        expand(fn, ins, body)
    lines.extend(peephole(body))

    lines.append(xor_(AX_LO, AX_LO))          # implicit `return 0`
    lines.append(define_label(f".Lret_{fn.name}"))
    lines.append(leave())
    lines.append(ret())
    return lines


def escape_bytes(data):
    out = []
    for byte in data:
        if byte == 0x22:
            out.append('\\"')
        elif byte == 0x5C:
            out.append("\\\\")
        elif 32 <= byte < 127:
            out.append(chr(byte))
        elif byte == 10:
            out.append("\\n")
        elif byte == 9:
            out.append("\\t")
        elif byte == 13:
            out.append("\\r")
        else:
            out.append("\\%03o" % byte)
    return "".join(out)


def compile_module(module):
    runtime_bodies, need_args = resolve_used(module.runtime_used)

    lines = [".intel_syntax noprefix", ".text", ".globl _start", "_start:"]
    if need_args:
        lines.append("  mov rax, [rsp]")
        lines.append("  mov [rip + __t_argc_val], rax")
        lines.append("  lea rax, [rsp + 8]")
        lines.append("  mov [rip + __t_argv_val], rax")
    if module.nglobals:
        lines.append("  call .Lfn___init")
    lines.append("  call .Lfn_main")
    lines.append("  mov edi, eax")
    lines.append("  mov eax, 60")
    lines.append("  syscall")
    lines.append("")

    for fn in module.funcs:
        lines.extend(emit_function(fn))
        lines.append("")

    for body in runtime_bodies:
        lines.append(body)
        lines.append("")

    # Data nobody references would just be dead weight in the file.
    used = "\n".join(lines)
    lines.append(".data")
    if "__t_empty" in used:
        lines.append("__t_empty:")
        lines.append("  .byte 0")
    if "__t_oom_msg" in used:
        lines.append("__t_oom_msg:")
        lines.append('  .ascii "%s"' % OOM_MSG.replace("\n", "\\n"))
    if "__t_bad_alloc_msg" in used:
        lines.append("__t_bad_alloc_msg:")
        lines.append('  .ascii "%s"' % BAD_ALLOC_MSG.replace("\n", "\\n"))
    if "__t_oob_msg" in used:
        lines.append("__t_oob_msg:")
        lines.append('  .ascii "%s"' % OOB_MSG.replace("\n", "\\n"))
    for name, data in module.strings.items():
        lines.append(f"{name}:")
        lines.append(f'  .ascii "{escape_bytes(data)}"')
        lines.append("  .byte 0")
    for index in range(module.nglobals):
        lines.append(f".Lglob{index}:")
        lines.append("  .quad 0")
    lines.append("")
    lines.append(BSS)
    lines.append('.section .note.GNU-stack,"",@progbits')
    lines.append("")
    return "\n".join(lines)
