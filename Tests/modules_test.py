#!/usr/bin/env python3
"""Build the module regression with both compilers."""

import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from Bootstrap.elf import strip_sections  # noqa: E402

TCOMP = os.path.join(ROOT, "tcomp")
PROGRAM = os.path.join(ROOT, "Tests", "Modules", "main.tl")
EXPECTED = b"90\n"
LDFLAGS = ["-s", "-z", "noseparate-code", "--build-id=none"]


def build_stage1(work):
    exe = os.path.join(work, "tcomp1")
    subprocess.run([sys.executable, TCOMP, "build",
                    os.path.join(ROOT, "tcomp.tl"), "-o", exe],
                   check=True, capture_output=True)
    return exe


def link(work, asm_text, name):
    asm = os.path.join(work, name + ".s")
    obj = os.path.join(work, name + ".o")
    exe = os.path.join(work, name)
    with open(asm, "w") as fh:
        fh.write(asm_text)
    subprocess.run(["as", "--64", "-mx86-used-note=no", "-o", obj, asm], check=True)
    subprocess.run(["ld", *LDFLAGS, "-o", exe, obj], check=True)
    strip_sections(exe)
    return exe


def main():
    with tempfile.TemporaryDirectory(prefix="tlang-modules-") as work:
        stage1 = build_stage1(work)
        for label, compiler in (("stage0", None), ("stage1", stage1)):
            exe = os.path.join(work, "modules-" + label)
            if compiler is None:
                cmd = [sys.executable, TCOMP, "build", PROGRAM, "-o", exe]
                built = subprocess.run(cmd, capture_output=True)
                if built.returncode != 0:
                    print(f"FAIL {label}: build failed", file=sys.stderr)
                    print(built.stderr.decode(errors="replace"), file=sys.stderr)
                    return 1
            else:
                built = subprocess.run([compiler, PROGRAM], capture_output=True)
                if built.returncode != 0:
                    print(f"FAIL {label}: compile failed", file=sys.stderr)
                    print(built.stderr.decode(errors="replace"), file=sys.stderr)
                    return 1
                exe = link(work, built.stdout.decode(), "modules-stage1")
            run = subprocess.run([exe], capture_output=True)
            if run.returncode != 0 or run.stdout != EXPECTED:
                print(f"FAIL {label}: {run.returncode=} {run.stdout=}",
                      file=sys.stderr)
                return 1
            print(f"  ok   {label}")
        print("\nmodules work in both compilers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
