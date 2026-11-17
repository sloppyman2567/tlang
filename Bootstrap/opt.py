"""Peephole rewrites over selected instruction lines.

The adjacent-line rules are local; the slot roundtrip rule looks at a whole
function body, because moving a stored value into its only reader needs to know
that no other read can reach the store.  Either way a rewrite only fires when
the surrounding lines prove the result is unchanged.
"""

import re

# A store into a frame slot, and a load of one.  Instruction selection spells
# both with or without an explicit size.
SLOT_STORE = re.compile(r"^  mov (?:QWORD PTR )?\[rbp(-\d+)\], (.+)$")
SLOT_LOAD = re.compile(r"^  mov ([a-z0-9]+), (?:QWORD PTR )?\[rbp(-\d+)\]$")
SLOT_USE = re.compile(r"\[rbp(-\d+)\]")
LABEL_LINE = re.compile(r"^[^ \t][^:]*:$")
JUMP_LINE = re.compile(r"^  j[a-z]+ (\S+)$")
INT_LITERAL = re.compile(r"^-?\d+$")

# Each 64-bit register with every name that aliases it.
ALIASES = {}
for _full, _rest in (
        ("rax", ("eax", "ax", "al", "ah")),
        ("rbx", ("ebx", "bx", "bl", "bh")),
        ("rcx", ("ecx", "cx", "cl", "ch")),
        ("rdx", ("edx", "dx", "dl", "dh")),
        ("rsi", ("esi", "si", "sil")),
        ("rdi", ("edi", "di", "dil")),
        ("r8", ("r8d", "r8w", "r8b")),
        ("r9", ("r9d", "r9w", "r9b")),
        ("r10", ("r10d", "r10w", "r10b")),
        ("r11", ("r11d", "r11w", "r11b")),
):
    ALIASES[_full] = (_full,) + _rest

# Instructions that write a register without naming it, so a scan for the name
# alone would miss the clobber.
IMPLICIT_WRITES = {
    "call": ("rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11"),
    "cqo": ("rax", "rdx"),
    "idiv": ("rax", "rdx"),
    "syscall": ("rax", "rcx", "r11"),
}


def _is_reg(text):
    return bool(text) and not text.startswith("[") and text.isalnum()


def _blocks(lines):
    """Split a body at labels.  A block's only entry is its top line."""
    blocks = []
    for line in lines:
        if LABEL_LINE.match(line):
            blocks.append([line[:-1], []])
        elif blocks:
            blocks[-1][1].append(line)
        else:
            blocks.append(["<entry>", [line]])
    return blocks


def _successors(blocks):
    index = {}
    for k, (label, _body) in enumerate(blocks):
        index.setdefault(label, k)
    out = []
    for k, (_label, body) in enumerate(blocks):
        succ = set()
        falls = True
        for line in body:
            if line == "  ret":
                falls = False
                continue
            m = JUMP_LINE.match(line)
            if m:
                target = index.get(m.group(1))
                if target is not None:
                    succ.add(target)
                if line.startswith("  jmp "):
                    falls = False
        if falls and k + 1 < len(blocks):
            succ.add(k + 1)
        out.append(succ)
    return out


def _live_out(blocks, successors):
    """Frame slots a block can reach a read of before its next write."""
    gen, kill = [], []
    for _label, body in blocks:
        reads, writes = set(), set()
        for line in body:
            store = SLOT_STORE.match(line)
            if store:
                writes.add(store.group(1))
                continue
            for slot in SLOT_USE.findall(line):
                if slot not in writes:
                    reads.add(slot)
        gen.append(reads)
        kill.append(writes)
    live_in = [set() for _ in blocks]
    live_out = [set() for _ in blocks]
    changed = True
    while changed:
        changed = False
        for k in range(len(blocks) - 1, -1, -1):
            out = set()
            for target in successors[k]:
                out |= live_in[target]
            inn = gen[k] | (out - kill[k])
            if out != live_out[k] or inn != live_in[k]:
                live_out[k] = out
                live_in[k] = inn
                changed = True
    return live_out


def _untouched(value, between):
    """True when `value` still holds the store's value after `between`."""
    names = ALIASES.get(value)
    if names is None:
        return False          # xmm registers and memory operands: no rewrite
    for line in between:
        op = line[2:].split(" ", 1)[0]
        if value in IMPLICIT_WRITES.get(op, ()):
            return False
        for name in names:
            if re.search(r"\b" + name + r"\b", line):
                return False
    return True


def fold_slot_roundtrips(lines):
    """Store to a slot, then read it straight back: keep only the value.

    Instruction selection writes every value it computes into a frame slot, and
    the next instruction usually reads it back: an argument is stored and then
    loaded into its ABI register, a call result is stored and then loaded to be
    added.  When the slot is read exactly once before being overwritten, is in
    the same block, and is dead on the way out, the store can go and the load
    take the value.  Slots are reused by later statements, which is what the
    liveness test protects.
    """
    blocks = _blocks(lines)
    if not blocks:
        return lines
    live_out = _live_out(blocks, _successors(blocks))
    for k, (_label, body) in enumerate(blocks):
        dead = set()
        for i, line in enumerate(body):
            store = SLOT_STORE.match(line)
            if store is None:
                continue
            slot, value = store.group(1), store.group(2)
            if slot in live_out[k]:
                continue
            read = -1
            blocked = False
            for j in range(i + 1, len(body)):
                if slot not in SLOT_USE.findall(body[j]):
                    continue
                load = SLOT_LOAD.match(body[j])
                if load is not None and load.group(2) == slot:
                    if read >= 0:
                        blocked = True
                        break
                    read = j
                    continue
                overwrite = SLOT_STORE.match(body[j])
                if overwrite is not None and overwrite.group(1) == slot:
                    break       # the value is replaced; the read was its last use
                blocked = True
                break
            if blocked or read < 0:
                continue
            if INT_LITERAL.match(value):
                if not (-(1 << 31) <= int(value) < (1 << 31)):
                    continue
            elif not _untouched(value, body[i + 1:read]):
                continue
            reg = SLOT_LOAD.match(body[read]).group(1)
            body[read] = f"  mov {reg}, {value}"
            dead.add(i)
        if dead:
            blocks[k][1] = [l for n, l in enumerate(body) if n not in dead]
    out = []
    for label, body in blocks:
        if label != "<entry>":
            out.append(label + ":")
        out.extend(body)
    return out


def drop_unreachable(lines):
    """Drop instructions after a jmp/ret until the next label.

    A label is a possible entry point, so only the rest of the current block is
    dead.  This catches, for example, the `xor eax, eax` left behind when a
    return is emitted ahead of a function's epilogue label.
    """
    out = []
    terminated = False
    for line in lines:
        if LABEL_LINE.match(line):
            terminated = False
        if terminated:
            continue
        out.append(line)
        if line == "  ret" or line.startswith("  jmp "):
            terminated = True
    return out


def peephole(lines):
    lines = fold_slot_roundtrips(lines)
    out = []
    i = 0
    n = len(lines)
    while i < n:
        cur = lines[i]
        nxt = lines[i + 1] if i + 1 < n else None

        # mov rax, SRC ; mov DST, rax  ->  mov DST, SRC   (DST must be a register:
        # memory-to-memory moves do not exist).
        if (cur.startswith("  mov rax, ") and nxt
                and nxt.startswith("  mov ") and nxt.endswith(", rax")):
            src = cur[len("  mov rax, "):]
            dst = nxt[len("  mov "):-len(", rax")]
            if "rax" not in src and _is_reg(dst):
                out.append(f"  mov {dst}, {src}")
                i += 2
                continue

        # lea rax, SRC ; mov DST, rax  ->  lea DST, SRC.  String arguments are
        # the common case: instruction selection builds the address in rax and
        # then copies it into an ABI register for the call.
        if (cur.startswith("  lea rax, ") and nxt
                and nxt.startswith("  mov ") and nxt.endswith(", rax")):
            src = cur[len("  lea rax, "):]
            dst = nxt[len("  mov "):-len(", rax")]
            if "rax" not in src and _is_reg(dst):
                out.append(f"  lea {dst}, {src}")
                i += 2
                continue

        # mov rax, 0 -> xor eax, eax
        if cur == "  mov rax, 0":
            out.append("  xor eax, eax")
            i += 1
            continue

        # mov DST, rax ; mov rax, DST -> keep only the store
        if cur.startswith("  mov ") and cur.endswith(", rax") and nxt:
            dst = cur[len("  mov "):-len(", rax")]
            if nxt == f"  mov rax, {dst}":
                out.append(cur)
                i += 2
                continue

        # jmp L followed immediately by L:
        if cur.startswith("  jmp ") and nxt is not None:
            if nxt == f"{cur[len('  jmp '):]}:":
                i += 1
                continue

        # mov X, X -> nothing
        if cur.startswith("  mov ") and ", " in cur:
            dst, _, src = cur[len("  mov "):].partition(", ")
            if dst == src:
                i += 1
                continue

        out.append(cur)
        i += 1
    return out
