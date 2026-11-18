#!/usr/bin/env python3
"""Golden-output tests for tlang.

Each case is Tests/Cases/NAME.tl with optional NAME.in (stdin), NAME.out
(expected stdout) and NAME.code (expected exit status, default 0).

    python3 Tests/run_tests.py            # run
    python3 Tests/run_tests.py --update   # rewrite .out/.code from actual output
"""

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TCOMP = os.path.join(ROOT, "tcomp")
CASES = os.path.join(ROOT, "Tests", "Cases")
# Deliberately tight: hello world is 363 bytes, and a regression that brought
# back the assembler note and its two program headers (about 160 bytes) must
# not slip through.
SIZE_LIMIT = 400


def build(binary_dir, source):
    exe = os.path.join(binary_dir, os.path.basename(source)[:-3])
    proc = subprocess.run([sys.executable, TCOMP, "build", source, "-o", exe],
                          capture_output=True, text=True)
    return exe, proc


def run_case(path, update):
    name = os.path.basename(path)[:-3]
    source = os.path.join(CASES, path)
    workdir = tempfile.mkdtemp(prefix="tlang-test-")
    failures = []
    try:
        exe, proc = build(workdir, source)
        if proc.returncode != 0:
            return [f"{name}: build failed\n{proc.stderr.strip()}"]

        stdin_path = os.path.join(CASES, name + ".in")
        stdin_data = b""
        if os.path.exists(stdin_path):
            with open(stdin_path, "rb") as fh:
                stdin_data = fh.read()

        run = subprocess.run([exe], input=stdin_data, capture_output=True)

        out_path = os.path.join(CASES, name + ".out")
        code_path = os.path.join(CASES, name + ".code")
        expected_code = 0
        if os.path.exists(code_path):
            with open(code_path) as fh:
                expected_code = int(fh.read().strip())

        if update:
            with open(out_path, "wb") as fh:
                fh.write(run.stdout)
            with open(code_path, "w") as fh:
                fh.write(f"{run.returncode}\n")
            return []

        expected = b""
        if os.path.exists(out_path):
            with open(out_path, "rb") as fh:
                expected = fh.read()
        if run.stdout != expected:
            failures.append(
                f"{name}: stdout mismatch\n"
                f"  expected: {expected!r}\n  actual:   {run.stdout!r}")
        if run.returncode != expected_code:
            failures.append(
                f"{name}: exit status {run.returncode}, "
                f"expected {expected_code}")
        if run.stderr:
            failures.append(f"{name}: wrote to stderr: {run.stderr!r}")
        return failures
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def size_check():
    workdir = tempfile.mkdtemp(prefix="tlang-size-")
    try:
        source = os.path.join(ROOT, "Examples", "hello.tl")
        exe, proc = build(workdir, source)
        if proc.returncode != 0:
            return [f"size check: build failed\n{proc.stderr.strip()}"]
        size = os.path.getsize(exe)
        if size >= SIZE_LIMIT:
            return [f"hello binary is {size} bytes, over the {SIZE_LIMIT} limit"]
        return [], size
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def main(argv):
    update = "--update" in argv
    if not os.path.isdir(CASES):
        print("no Tests/Cases directory")
        return 1

    cases = sorted(f for f in os.listdir(CASES) if f.endswith(".tl"))
    failures = []
    for case in cases:
        result = run_case(case, update)
        status = "ok" if not result else "FAIL"
        print(f"  {status:4} {case[:-3]}")
        failures.extend(result)

    sizes = size_check()
    if isinstance(sizes, tuple):
        print(f"  ok   size (hello = {sizes[1]} bytes)")
    else:
        failures.extend(sizes)
        print("  FAIL size")

    print()
    if failures:
        for failure in failures:
            print(failure)
            print()
        print(f"{len(failures)} failure(s)")
        return 1
    print(f"{len(cases)} case(s) passed" + (" (golden files updated)" if update else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
