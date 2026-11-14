#!/usr/bin/env python3
"""Run the floating-point regression through both compilers."""

import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from Bootstrap.elf import strip_sections  # noqa: E402

TCOMP = os.path.join(ROOT, "tcomp")
FLOAT_DIR = os.path.join(ROOT, "Tests", "Floats")
LDFLAGS = ["-s", "-z", "noseparate-code", "--build-id=none"]

CASES = {
    "basic": """\
1.500000
1.500000
3.500000
1.414214
3
4.250000
1000.000000
0.250000
""",
    "math": """\
5.500000
5.500000
10.000000
3.750000
2.250000
3.000000
111010010
inf
nan
3
2.000000
3.750000
6.750000
1.500000
1.500000
1.500000
2.000000
1.000000
""",
}


def build_stage1(work):
    compiler = os.path.join(work, "tcomp1")
    subprocess.run([sys.executable, TCOMP, "build",
                    os.path.join(ROOT, "tcomp.tl"), "-o", compiler],
                   check=True, capture_output=True)
    return compiler


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
    failures = []
    with tempfile.TemporaryDirectory(prefix="tlang-floats-") as work:
        stage1 = build_stage1(work)
        for name, expected in CASES.items():
            source_path = os.path.join(FLOAT_DIR, name + ".tl")
            for label, compiler in (("stage0", None), ("stage1", stage1)):
                tag = name + "-" + label
                if compiler is None:
                    exe = os.path.join(work, tag)
                    proc = subprocess.run(
                        [sys.executable, TCOMP, "build", source_path, "-o", exe],
                        capture_output=True)
                    if proc.returncode != 0:
                        failures.append(
                            f"{tag}: build failed\n"
                            f"{proc.stderr.decode(errors='replace')}")
                        continue
                else:
                    proc = subprocess.run([compiler, source_path],
                                          capture_output=True)
                    if proc.returncode != 0:
                        failures.append(
                            f"{tag}: compile failed\n"
                            f"{proc.stderr.decode(errors='replace')}")
                        continue
                    exe = link(work, proc.stdout.decode(), tag)
                run = subprocess.run([exe], capture_output=True)
                got = run.stdout.decode(errors="replace")
                if run.returncode != 0 or got != expected:
                    failures.append(
                        f"{tag}: expected {expected!r}, got {got!r} "
                        f"(exit {run.returncode})")
                else:
                    print(f"  ok   {tag}")

        if not failures:
            print("\nfloating point works in both compilers")
    for failure in failures:
        print(failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
