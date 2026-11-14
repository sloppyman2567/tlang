#!/usr/bin/env python3
"""Cross-compiler differential: stage 0 and the self-hosted compiler agree.

The fixed point proves tcomp.tl is self-consistent; it says nothing about the
two implementations agreeing. Compile each program with both and compare stdout
and exit status. Random programs come from diff_test's generator.

    python3 Tests/compare_test.py [ROUNDS]
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
sys.path.insert(0, os.path.join(ROOT, "Tests"))
import diff_test  # noqa: E402  (random program generator)

AS_FLAGS = ["--64", "-mx86-used-note=no"]
LD_FLAGS = ["-s", "-z", "noseparate-code", "--build-id=none"]

STAGE1 = ""


def build_stage0(source, exe):
    return subprocess.run(
        [sys.executable, TCOMP, "build", source, "-o", exe],
        capture_output=True, text=True)


def build_stage1(source, exe, workdir):
    """Compile with the self-hosted compiler, then assemble and link."""
    proc = subprocess.run([STAGE1, source], capture_output=True, text=True)
    if proc.returncode != 0:
        return proc
    asm = os.path.join(workdir, "stage1.s")
    obj = os.path.join(workdir, "stage1.o")
    with open(asm, "w") as fh:
        fh.write(proc.stdout)
    proc = subprocess.run(["as", *AS_FLAGS, "-o", obj, asm],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        return proc
    return subprocess.run(["ld", *LD_FLAGS, "-o", exe, obj],
                          capture_output=True, text=True)


def check(source, workdir, label):
    stdin_path = source[:-3] + ".in"
    stdin_data = b""
    if os.path.exists(stdin_path):
        with open(stdin_path, "rb") as fh:
            stdin_data = fh.read()

    exe0 = os.path.join(workdir, label + ".stage0")
    exe1 = os.path.join(workdir, label + ".stage1")
    proc = build_stage0(source, exe0)
    if proc.returncode != 0:
        return [f"{label}: stage 0 failed\n{proc.stderr.strip()}"]
    proc = build_stage1(source, exe1, workdir)
    if proc.returncode != 0:
        return [f"{label}: stage 1 failed\n{proc.stderr.strip()}"]

    run0 = subprocess.run([exe0], input=stdin_data, capture_output=True)
    run1 = subprocess.run([exe1], input=stdin_data, capture_output=True)
    if run0.stdout != run1.stdout or run0.returncode != run1.returncode:
        return [f"{label}: compilers disagree\n"
                f"  stage 0: {run0.stdout!r} (exit {run0.returncode})\n"
                f"  stage 1: {run1.stdout!r} (exit {run1.returncode})"]
    return []


def main(argv):
    global STAGE1
    rounds = int(argv[0]) if argv else 40
    workdir = tempfile.mkdtemp(prefix="tlang-compare-")
    STAGE1 = os.path.join(workdir, "tcomp1")
    failures = []
    checked = 0
    try:
        proc = subprocess.run(
            [sys.executable, TCOMP, "build", os.path.join(ROOT, "tcomp.tl"),
             "-o", STAGE1], capture_output=True, text=True)
        if proc.returncode != 0:
            print(f"could not build the self-hosted compiler:\n{proc.stderr}")
            return 1

        for directory in (CASES, EXAMPLES):
            if not os.path.isdir(directory):
                continue
            for name in sorted(os.listdir(directory)):
                if not name.endswith(".tl"):
                    continue
                failures.extend(check(os.path.join(directory, name),
                                      workdir, name[:-3]))
                checked += 1
                print(f"  {'ok' if not failures else '..'}   {name[:-3]}")

        rng = random.Random(20261114)
        for index in range(rounds):
            source = os.path.join(workdir, f"rand{index}.tl")
            with open(source, "w") as fh:
                fh.write(diff_test.gen_program(rng))
            failures.extend(check(source, workdir, f"rand{index}"))
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
    print(f"{checked} programs: stage 0 and stage 1 agree")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
