"""Optimization over the three-address IR.

The instruction templates in `isa` are written for clarity, not for the fewest
possible bytes, so every expression arrives as "compute into a fresh temp, then
copy into its destination".  This module takes that slack back with three
conservative passes:

  hoist     move a loop-invariant pure call (notably `len`) out of its loop
  fold      constant folding, immediate operands, algebraic identities
  coalesce  "compute into a temp, then copy" -> compute into the target, and
            "compare into a temp, then branch" -> a direct conditional branch
  dead      drop pure definitions that nothing ever reads

Each pass is a linear sweep with no global analysis: a rewrite only fires when
the adjacent instruction makes it provably equivalent, so a bug here shows up
as wrong output rather than as a miscompile nobody notices.
"""

from .ir import TEMP_BASE

# Definitions that compute a value and nothing else: safe to delete when unread.
PURE = {"imm", "lea", "mov", "bin", "bink", "fbin", "ffma", "cmp", "cmpk",
        "neg", "not", "bnot", "ld8", "ldb", "fld"}

# Instructions that define exactly one slot (`writes` knows where it sits).
DEFS_DST = PURE | {"call", "bcall", "aloc"}

COMMUTATIVE = {"add", "mul", "and", "or", "xor"}

# cc -> the condition that is false exactly when cc is true.
INVERSE = {"eq": "ne", "ne": "eq", "lt": "ge", "ge": "lt", "le": "gt", "gt": "le"}

DST_INDEX = {"bin": 2, "bink": 2, "fbin": 2, "ffma": 1, "cmp": 2, "cmpk": 2}


def writes(ins):
    """The slot this instruction defines, or None if it defines nothing."""
    if ins[0] in DST_INDEX:
        return ins[DST_INDEX[ins[0]]]
    if ins[0] in DEFS_DST:
        return ins[1]
    return None


def with_dst(ins, dst):
    index = DST_INDEX.get(ins[0], 1)
    return ins[:index] + (dst,) + ins[index + 1:]


def _reads(ins):
    op = ins[0]
    if op == "mov":
        return (ins[2],)
    if op in ("bin", "fbin", "cmp"):
        return (ins[3], ins[4])
    if op == "ffma":
        return (ins[2], ins[3], ins[4])
    if op in ("bink", "cmpk"):
        return (ins[3],)
    if op in ("neg", "not", "bnot"):
        return (ins[2],)
    if op in ("jz", "jnz", "jcck", "ret"):
        return (ins[1] if op in ("jz", "jnz", "ret") else ins[2],)
    if op == "jtable":
        return (ins[1],)
    if op == "jcc":
        return (ins[2], ins[3])
    if op in ("call", "bcall"):
        return tuple(ins[3])
    if op == "aloc":
        return (ins[2],)
    if op in ("ld8", "ldb"):
        return (ins[2], ins[3])
    if op in ("st8", "stb"):
        return (ins[1], ins[2], ins[3])
    if op == "fld":
        return (ins[2],)
    if op == "fst":
        return (ins[1], ins[3])
    return ()


def read_counts(ins_list):
    counts = {}
    for ins in ins_list:
        for slot in _reads(ins):
            counts[slot] = counts.get(slot, 0) + 1
    return counts


# -- constant folding ------------------------------------------------------

def _trunc_div(a, b):
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def _trunc_mod(a, b):
    return a - _trunc_div(a, b) * b


def _wrap64(v):
    """Signed 64-bit wraparound, so folding past an overflow stays faithful."""
    v &= (1 << 64) - 1
    return v - (1 << 64) if v >= (1 << 63) else v


def fold_bin(kind, a, b):
    """Value of `a <kind> b`, or None when it must stay a runtime operation."""
    if kind == "add":
        return _wrap64(a + b)
    if kind == "sub":
        return _wrap64(a - b)
    if kind == "mul":
        return _wrap64(a * b)
    if kind in ("div", "mod"):
        # x86 idiv traps on both of these, so they must stay runtime ops.
        if b == 0 or (a == -(1 << 63) and b == -1):
            return None
        return _trunc_div(a, b) if kind == "div" else _trunc_mod(a, b)
    if kind == "shl":
        return _wrap64(a << (b & 63))
    if kind == "shr":
        return a >> (b & 63)
    if kind == "ushr":
        return (a & ((1 << 64) - 1)) >> (b & 63)
    if kind == "and":
        return a & b
    if kind == "or":
        return a | b
    if kind == "xor":
        return a ^ b
    return None


def fold_cmp(cc, a, b):
    return {"eq": a == b, "ne": a != b, "lt": a < b,
            "le": a <= b, "gt": a > b, "ge": a >= b}[cc]


def _is_pow2(v):
    return v > 0 and (v & (v - 1)) == 0


def fold(ins_list):
    out = []
    consts = {}
    for ins in ins_list:
        op = ins[0]

        # A label can be reached from anywhere, so nothing is known past it.
        if op == "lab":
            consts.clear()
            out.append(ins)
            continue

        # A call may write any global, so drop everything we knew.
        if op in ("call", "bcall"):
            consts.clear()
            out.append(ins)
            continue

        if op == "imm":
            _, dst, value = ins
            if dst >= 0:
                consts[dst] = value
            out.append(ins)
            continue

        if op == "mov":
            _, dst, src = ins
            if src in consts:
                out.append(("imm", dst, consts[src]))
                consts[dst] = consts[src]
            else:
                consts.pop(dst, None)
                out.append(ins)
            continue

        if op in ("bin", "cmp"):
            dst = ins[2]
            a, b = ins[3], ins[4]
            ka, kb = consts.get(a), consts.get(b)
            new = None
            if op == "bin":
                kind = ins[1]
                if ka is not None and kb is not None:
                    value = fold_bin(kind, ka, kb)
                    if value is not None:
                        new = ("imm", dst, value)
                if new is None and kb is not None:
                    # Identities: with a zero operand these are free copies, and
                    # with a one the multiply or divide disappears.
                    if kb == 0 and kind in ("add", "sub", "or", "xor",
                                            "shl", "shr", "ushr"):
                        new = ("mov", dst, a)
                    elif kb == 0 and kind in ("mul", "and"):
                        new = ("imm", dst, 0)
                    elif kb == 1 and kind in ("mul", "div"):
                        new = ("mov", dst, a)
                    elif kind == "mul" and _is_pow2(kb):
                        new = ("bink", "shl", dst, a, kb.bit_length() - 1)
                    elif kind in ("add", "sub", "mul", "div", "mod", "shl",
                                  "shr", "ushr", "and", "or", "xor"):
                        new = ("bink", kind, dst, a, kb)
                if new is None and ka is not None and kind in COMMUTATIVE:
                    new = ("bink", kind, dst, b, ka)
            else:
                cc = ins[1]
                if ka is not None and kb is not None:
                    new = ("imm", dst, 1 if fold_cmp(cc, ka, kb) else 0)
                if new is None and kb is not None:
                    new = ("cmpk", cc, dst, a, kb)
                elif new is None and ka is not None and cc in ("eq", "ne"):
                    new = ("cmpk", cc, dst, b, ka)
            if new is None:
                consts.pop(dst, None)
                out.append(ins)
            else:
                if new[0] == "imm":
                    consts[dst] = new[2]
                else:
                    consts.pop(dst, None)
                out.append(new)
            continue

        if op in ("neg", "not", "bnot"):
            dst, a = ins[1], ins[2]
            ka = consts.get(a)
            if ka is None:
                consts.pop(dst, None)
                out.append(ins)
                continue
            if op == "neg":
                value = _wrap64(-ka)
            elif op == "bnot":
                value = _wrap64(~ka)
            else:
                value = 0 if ka else 1
            out.append(("imm", dst, value))
            consts[dst] = value
            continue

        if op in ("jz", "jnz"):
            src, target = ins[1], ins[2]
            if src in consts:
                zero = consts[src] == 0
                taken = zero if op == "jz" else not zero
                if taken:
                    out.append(("jmp", target))
                continue
            out.append(ins)
            continue

        dst = writes(ins)
        if dst is not None and dst >= 0:
            consts.pop(dst, None)
        out.append(ins)
    return out


# -- coalescing ------------------------------------------------------------

def _copy_is_last_use(ins_list, index, src):
    """True when a copy is the last read before `src` is overwritten."""
    for x in ins_list[index + 1:]:
        if writes(x) == src:
            return True
        if src in _reads(x):
            return False
    return False


# Anything that can be jumped to or from ends a straight-line run: a label is
# entered from elsewhere and a branch leaves, so a value could travel around it.
BARRIERS = {"lab", "jmp", "jz", "jnz", "jcc", "jcck", "jtable", "ret", "ret0"}


def _dead_before_redefine(ins_list, index, slot):
    """True when `slot` is overwritten before it is read, with no control flow.

    IR temps are reused from statement to statement, so a whole-function read
    count says nothing about one definition. Inside a straight-line run the
    only path is fall-through, which makes "redefined before read" a proof
    that this definition's value is never used.
    """
    for x in ins_list[index + 1:]:
        if x[0] in BARRIERS:
            return False
        if slot in _reads(x):
            return False
        if writes(x) == slot:
            return True
    return True


def _label_map(ins_list):
    return {ins[1]: i for i, ins in enumerate(ins_list) if ins[0] == "lab"}


def _value_dead_after(ins_list, index, slot, labels):
    """True when `slot` is never read again before being written or returning.

    Follows jumps instead of giving up at a label. A compare result feeding a
    branch is usually dead on both edges: the fall-through returns and the
    taken edge overwrites the same temp. A whole-function read count misses
    that because the temp is reused by the branch target.
    """
    n = len(ins_list)
    seen = set()
    work = [index + 1]
    while work:
        i = work.pop()
        if i >= n or i in seen:
            continue
        seen.add(i)
        ins = ins_list[i]
        op = ins[0]
        if slot in _reads(ins):
            return False
        if writes(ins) == slot or op in ("ret", "ret0"):
            continue
        if op == "jmp":
            target = labels.get(ins[1])
            if target is not None:
                work.append(target)
            continue
        if op in ("jz", "jnz", "jcc", "jcck"):
            target = labels.get(ins[-1])
            if target is not None:
                work.append(target)
        work.append(i + 1)
    return True


def coalesce(ins_list):
    """Remove copies and fold compare-then-branch into one jump.

    A copy is removable when it is the final read of a temporary before the
    next definition of that slot. Whole-function counts are too conservative
    for IR temps, which are reused from statement to statement.
    """
    counts = read_counts(ins_list)
    labels = _label_map(ins_list)
    out = []
    for index, ins in enumerate(ins_list):
        op = ins[0]

        if op == "mov":
            _, dst, src = ins
            if (src >= TEMP_BASE and out
                    and out[-1][0] in DEFS_DST and out[-1][0] != "mov"
                    and writes(out[-1]) == src
                    and _copy_is_last_use(ins_list, index, src)):
                out[-1] = with_dst(out[-1], dst)
                continue
            out.append(ins)
            continue

        if op in ("jz", "jnz") and out:
            src, target = ins[1], ins[2]
            prev = out[-1]
            if (counts.get(src, 0) == 1
                    or (src >= TEMP_BASE
                        and (_dead_before_redefine(ins_list, index, src)
                             or _value_dead_after(ins_list, index, src,
                                                  labels)))):
                if prev[0] == "cmp" and prev[2] == src:
                    cc = prev[1] if op == "jnz" else INVERSE[prev[1]]
                    out[-1] = ("jcc", cc, prev[3], prev[4], target)
                    continue
                if prev[0] == "cmpk" and prev[2] == src:
                    cc = prev[1] if op == "jnz" else INVERSE[prev[1]]
                    out[-1] = ("jcck", cc, prev[3], prev[4], target)
                    continue
                # !x branched on is just x branched on, the other way round.
                if prev[0] == "not" and prev[1] == src:
                    out[-1] = ("jnz" if op == "jz" else "jz", prev[2], target)
                    continue
            out.append(ins)
            continue

        out.append(ins)
    return out


# -- dead definitions ------------------------------------------------------

def dead(ins_list):
    """Drop pure instructions whose temporary is never read.

    A temporary is written, read and forgotten inside one statement, so "no
    reader anywhere in the function" is enough: there is no partial liveness to
    reason about, and no control-flow graph to build.
    """
    while True:
        counts = read_counts(ins_list)
        kept = []
        for index, ins in enumerate(ins_list):
            op = ins[0]
            dst = writes(ins)
            unused = (dst is not None and dst >= TEMP_BASE
                      and (counts.get(dst, 0) == 0
                           or _dead_before_redefine(ins_list, index, dst)))
            if unused and op in PURE:
                continue
            if unused and op in ("call", "bcall"):
                # The call still has to run; only its result can go.
                kept.append((op, None) + ins[2:])
                continue
            kept.append(ins)
        if kept == ins_list:
            return kept
        ins_list = kept


# -- loop-invariant hoisting -----------------------------------------------

# Runtime calls whose value depends only on their argument. `len()` walks the
# whole string, so calling it from a loop condition makes the loop quadratic;
# caching it is the difference between a scan and a stall.
HOISTABLE = {"__t_strlen"}

READ_POSITIONS = {
    "mov": (2,), "bin": (3, 4), "cmp": (3, 4), "bink": (3,), "cmpk": (3,),
    "neg": (2,), "not": (2,), "bnot": (2,),
    "fbin": (3, 4), "ffma": (2, 3, 4),
    "jz": (1,), "jnz": (1,), "ret": (1,),
    "jcc": (2, 3), "jcck": (2,), "aloc": (2,),
    "ld8": (2, 3), "ldb": (2, 3), "st8": (1, 2, 3), "stb": (1, 2, 3),
    "fld": (2,), "fst": (1, 3),
}


def _swap(ins, old, new):
    parts = list(ins)
    if ins[0] in ("call", "bcall"):
        parts[3] = tuple(new if s == old else s for s in parts[3])
        return tuple(parts)
    for pos in READ_POSITIONS.get(ins[0], ()):
        if parts[pos] == old:
            parts[pos] = new
    return tuple(parts)


def _loop_bodies(ins_list):
    """(label index, back-jump index) for every loop a plain `jmp` closes."""
    labels = {}
    for index, ins in enumerate(ins_list):
        if ins[0] == "lab":
            labels.setdefault(ins[1], index)
    bodies = []
    for index, ins in enumerate(ins_list):
        if ins[0] == "jmp":
            start = labels.get(ins[1])
            if start is not None and start < index:
                bodies.append((start, index))
    return bodies


def hoist(fn):
    """Move `len(s)` out of a loop whose body cannot change `s`.

    The call is pure and its argument is untouched, so computing it once before
    the loop is equivalent. The result gets a fresh slot rather than reusing the
    temporary: IR temps are reused from statement to statement, so the original
    slot would be clobbered by the second iteration of the same body.
    """
    for _ in range(4):
        moved = False
        for start, end in _loop_bodies(fn.ins):
            body = fn.ins[start + 1:end]
            written = set()
            for x in body:
                dst = writes(x)
                if dst is not None:
                    written.add(dst)
            for ins in body:
                if ins[0] != "bcall" or ins[1] is None or ins[2] not in HOISTABLE:
                    continue
                dst, args = ins[1], ins[3]
                if len(args) != 1 or args[0] in written:
                    continue
                # A user call could rewrite a string a global points at, and a
                # byte store could plant the terminating NUL.
                if any(x[0] == "call" for x in body):
                    continue
                if any(x[0] == "stb" and x[1] == args[0] for x in body):
                    continue
                # The temp is reused from statement to statement, so only the
                # reads that happen before the next write to that slot are the
                # length; the rest are unrelated work borrowing the slot.
                reads_dst = 0
                writes_seen = False
                for x in body:
                    if x[0] == "bcall" and x[1] == dst and x[2] == ins[2]:
                        continue
                    if not writes_seen:
                        reads_dst += _reads(x).count(dst)
                    if writes(x) == dst:
                        writes_seen = True
                if reads_dst == 0:
                    continue
                fresh = TEMP_BASE + fn.max_temp
                fn.max_temp += 1
                kept = []
                rewrites = True
                for x in body:
                    if rewrites and x[0] == "bcall" and x[1] == dst and x[2] == ins[2]:
                        continue
                    if rewrites:
                        kept.append(_swap(x, dst, fresh))
                        if writes(x) == dst:
                            rewrites = False
                    else:
                        kept.append(x)
                # Before the label, not after it: the back-jump lands on the
                # label, so the call runs once on entry instead of every pass.
                fn.ins = (fn.ins[:start]
                          + [("bcall", fresh, ins[2], args)]
                          + fn.ins[start:start + 1] + kept + fn.ins[end:])
                moved = True
                break
            if moved:
                break
        if not moved:
            break
    return fn


def fuse_float_mul_add(ins_list):
    """Turn `mul t, a, b; add d, t, c` into one ffma instruction.

    The two SSE operations still round separately: the multiply result is kept
    in xmm0, but the temporary store/reload is removed. The temporary must have
    exactly one reader, so its old slot cannot be needed elsewhere.
    """
    out = []
    i = 0
    while i < len(ins_list):
        a = ins_list[i]
        if (i + 1 < len(ins_list)
                and a[0] == "fbin" and a[1] == "mul"):
            b = ins_list[i + 1]
            # IR temps are reused for unrelated statements. Reads before this
            # definition do not matter, and reads after the next write to the
            # slot belong to that later value. Count only the live interval
            # from the multiply through the add.
            end = i + 1
            while end < len(ins_list) and writes(ins_list[end]) != a[2]:
                end += 1
            suffix_reads = sum(_reads(x).count(a[2])
                               for x in ins_list[i + 1:end])
            if (b[0] == "fbin" and b[1] == "add"
                    and b[3] == a[2] and suffix_reads == 1):
                out.append(("ffma", b[2], a[3], a[4], b[4]))
                i += 2
                continue
        out.append(a)
        i += 1
    return out


def optimize(ins_list):
    """Run the pipeline to a fixed point (two sweeps is enough in practice)."""
    for _ in range(2):
        before = len(ins_list)
        ins_list = dead(coalesce(fold(fuse_float_mul_add(ins_list))))
        if len(ins_list) == before:
            break
    return ins_list


def optimize_module(module):
    for fn in module.funcs:
        hoist(fn)
        fn.ins = optimize(fn.ins)
    return module
