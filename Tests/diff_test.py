#!/usr/bin/env python3
"""Differential test: the IR optimizer must not change what a program does.

Every case is compiled twice -- once with optimization, once without -- and the
two binaries must agree on stdout and exit status.  A folding bug (sign of
truncating division, a strength-reduced shift, a compare folded into a branch)
shows up here as a mismatch.

    python3 Tests/diff_test.py [ROUNDS]
"""

import os
import random
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TCOMP = os.path.join(ROOT, "tcomp")
CASES = os.path.join(ROOT, "Tests", "Cases")
EXAMPLES = os.path.join(ROOT, "Examples")

OPS = ["+", "-", "*", "%", "&", "|", "^", "<<", ">>"]


def gen_expr(rng, depth, names):
    if depth <= 0 or rng.random() < 0.25:
        if names and rng.random() < 0.6:
            return rng.choice(names)
        return str(rng.randint(-40, 40))
    op = rng.choice(OPS)
    left = gen_expr(rng, depth - 1, names)
    if op == "%":
        # Keep the divisor a nonzero constant so the program cannot divide by
        # zero -- both builds would fault and the comparison would be useless.
        right = str(rng.randint(1, 17))
    elif op in ("<<", ">>"):
        # A small count keeps the values in range; the point is that folding a
        # shift agrees with the instruction the runtime would have executed.
        right = str(rng.randint(0, 7))
    else:
        right = gen_expr(rng, depth - 1, names)
    return f"({left} {op} {right})"


def gen_program(rng):
    """A program that prints a lot of arithmetic and branches on it."""
    names = []
    lines = ["fn main() {"]
    for index in range(4):
        name = f"v{index}"
        lines.append(f"  let {name} = {gen_expr(rng, 3, names)}")
        names.append(name)
        lines.append(f"  print_int({name})")
        lines.append('  print(" ")')
    a, b = names[0], names[1]
    lines.append(f"  if {a} < {b} {{ print(\"lt\") }} else {{ print(\"ge\") }}")
    lines.append('  print("\\n")')
    lines.append("  let acc = 0")
    lines.append(f"  for i in 1..7 {{")
    lines.append(f"    acc += (i * {a} + {b}) % 997")
    lines.append('    print(",")')
    lines.append("  }")
    lines.append('  print("\\n")')
    lines.append("  print_int(acc)")
    lines.append('  print("\\n")')
    for index, name in enumerate(names):
        other = names[(index + 1) % len(names)]
        lines.append(f"  print_int({name} == {other})")
        lines.append(f"  print_int({name} * 2)")
        lines.append(f"  print_int({name} / 3)")
        lines.append(f"  print_int({name} & 255)")
        lines.append(f"  print_int({name} ^ {other})")
        lines.append(f"  print_int(~{name})")
        lines.append(f"  print_int({name} >> 2)")
    lines.append('  print("\\n")')
    # A string scan whose loop condition calls len(): the optimizer hoists it,
    # the unoptimized build recomputes it, and both must print the same total.
    lines.append('  let s = "abcdefghij"')
    lines.append("  let k = 0")
    lines.append("  let total = 0")
    lines.append("  while k < len(s) {")
    lines.append("    total = total + s[k]")
    lines.append("    k = k + 1")
    lines.append("  }")
    lines.append("  print_int(total)")
    lines.append("  print_int(k)")
    lines.append('  print("\\n")')
    lines.append(f"  return ({a} % 7) + 3")
    lines.append("}")
    return "\n".join(lines) + "\n"


def compile_and_run(source_path, workdir, tag, stdin_data):
    exe = os.path.join(workdir, tag)
    for extra in ([], ["--no-opt"]):
        out = exe + ("-noopt" if extra else "")
        proc = subprocess.run(
            [sys.executable, TCOMP, "build", source_path, "-o", out, *extra],
            capture_output=True, text=True)
        if proc.returncode != 0:
            return None, f"build failed ({'no-opt' if extra else 'opt'})\n" \
                         f"{proc.stderr.strip()}"
    opt = subprocess.run([exe], input=stdin_data, capture_output=True)
    noopt = subprocess.run([exe + "-noopt"], input=stdin_data,
                           capture_output=True)
    if opt.stdout != noopt.stdout or opt.returncode != noopt.returncode:
        return False, ("optimized and unoptimized builds disagree\n"
                       f"  opt:   {opt.stdout!r} (exit {opt.returncode})\n"
                       f"  noopt: {noopt.stdout!r} (exit {noopt.returncode})")
    return True, None


def check_file(source_path, workdir, label):
    stdin_path = source_path[:-3] + ".in"
    stdin_data = b""
    if os.path.exists(stdin_path):
        with open(stdin_path, "rb") as fh:
            stdin_data = fh.read()
    ok, detail = compile_and_run(source_path, workdir, label, stdin_data)
    if ok is None:
        return [f"{label}: {detail}"]
    if ok is False:
        return [f"{label}: {detail}"]
    return []


def main(argv):
    rounds = int(argv[0]) if argv else 150
    workdir = tempfile.mkdtemp(prefix="tlang-diff-")
    failures = []
    checked = 0
    try:
        for directory in (CASES, EXAMPLES):
            if not os.path.isdir(directory):
                continue
            for name in sorted(os.listdir(directory)):
                if not name.endswith(".tl"):
                    continue
                failures.extend(check_file(
                    os.path.join(directory, name), workdir, name[:-3]))
                checked += 1
                print(f"  {'ok' if not failures else '..'}   {name[:-3]}")

        rng = random.Random(20261030)
        for index in range(rounds):
            source = os.path.join(workdir, f"rand{index}.tl")
            with open(source, "w") as fh:
                fh.write(gen_program(rng))
            failures.extend(check_file(source, workdir, f"rand{index}"))
            checked += 1
        print(f"  {'ok' if not failures else 'FAIL'}   {rounds} random programs")
    finally:
        if not failures:
            shutil.rmtree(workdir, ignore_errors=True)

    print()
    if failures:
        for failure in failures[:10]:
            print(failure)
            print()
        print(f"{len(failures)} disagreement(s) across {checked} programs "
              f"(sources kept in {workdir})")
        return 1
    print(f"{checked} programs: optimized and unoptimized builds agree")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
