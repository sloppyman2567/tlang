"""Peephole rewrites over selected instruction lines.

Each rule is local and conservative: it only fires on adjacent lines whose
semantics are provably unchanged.
"""


def _is_reg(text):
    return bool(text) and not text.startswith("[") and text.isalnum()


def peephole(lines):
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
