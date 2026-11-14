#!/usr/bin/env python3
"""Verify that tcomp is really self-hosted.

Stages and the fixed-point comparison live in Tools/selfhost.py.  This test
adds the behavioural requirement: the self-hosted compiler must pass every
golden case.

  1. stage 1 = the Python bootstrap compiler compiling tcomp.tl
  2. stage 2 = stage 1 compiling tcomp.tl
  3. stage 3 = stage 2 compiling tcomp.tl
  4. assert stage 2 and stage 3 emit identical assembly and binaries
  5. run every golden case through stage 3 and compare with the expected output

Usage: python3 Tests/fixedpoint.py
"""

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from Tools.selfhost import build_chain, check_generated, link_asm  # noqa: E402

CASES = os.path.join(ROOT, "Tests", "Cases")


def main():
    check_generated()
    workdir = tempfile.mkdtemp(prefix="tlang-fixedpoint-")
    failures = []
    try:
        chain = build_chain(workdir)
        print(f"  ok   stage 1 built ({os.path.getsize(chain.stage1)} bytes)")
        print(f"  ok   stage 2 built ({os.path.getsize(chain.stage3)} bytes)")
        failures.extend(chain.failures)
        if not failures:
            print(f"  ok   fixed point: stage 2 == stage 3 "
                  f"({os.path.getsize(chain.stage3)} bytes, identical)")

        cases = sorted(f for f in os.listdir(CASES) if f.endswith(".tl"))
        passed = 0
        for case in cases:
            name = case[:-3]
            src = os.path.join(CASES, case)
            proc = subprocess.run([chain.stage3, src], capture_output=True,
                                  text=True)
            if proc.returncode != 0:
                failures.append(f"{name}: self-hosted compile failed: "
                                f"{proc.stderr.strip()}")
                continue
            asm_path = os.path.join(workdir, "case_" + name + ".s")
            exe = os.path.join(workdir, "case_" + name)
            with open(asm_path, "w", encoding="utf-8") as fh:
                fh.write(proc.stdout)
            link_asm(asm_path, exe)

            stdin_path = os.path.join(CASES, name + ".in")
            data = b""
            if os.path.exists(stdin_path):
                with open(stdin_path, "rb") as fh:
                    data = fh.read()
            result = subprocess.run([exe], input=data, capture_output=True)

            expected = b""
            out_path = os.path.join(CASES, name + ".out")
            if os.path.exists(out_path):
                with open(out_path, "rb") as fh:
                    expected = fh.read()
            expected_code = 0
            code_path = os.path.join(CASES, name + ".code")
            if os.path.exists(code_path):
                with open(code_path) as fh:
                    expected_code = int(fh.read().strip())

            if result.stdout != expected:
                failures.append(
                    f"{name}: self-hosted output mismatch\n"
                    f"  expected {expected!r}\n  actual   {result.stdout!r}")
            elif result.returncode != expected_code:
                failures.append(
                    f"{name}: self-hosted exit {result.returncode}, "
                    f"expected {expected_code}")
            else:
                passed += 1
        print(f"  ok   self-hosted suite: {passed}/{len(cases)} cases")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    print()
    if failures:
        for failure in failures:
            print(failure)
        return 1
    print("self-hosting verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
