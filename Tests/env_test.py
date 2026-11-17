#!/usr/bin/env python3
"""Test the env() builtin in both compilers.

Each program runs with a controlled environment, so the cases are independent
of the machine running the tests.  Unset names, an empty name, a name that is
a prefix of another variable, and values containing '=' all go through the
same lookup, while argv() keeps working beside it.
"""

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TCOMP = os.path.join(ROOT, "tcomp")
LDFLAGS = ["-s", "-z", "noseparate-code", "--build-id=none"]
sys.path.insert(0, ROOT)

from Bootstrap.elf import strip_sections  # noqa: E402

SOURCE = '''fn main() {
  print(env("TL_HOME"))
  print("|")
  print_int(len(env("TL_MISSING")))
  print("|")
  print_int(len(env("TL_HOM")))
  print("|")
  print(env("TL_EQ"))
  print("|")
  print_int(len(env("")))
  print("|")
  print(env("TL_SPACE"))
  print("|")
  print(argv(1))
  print("\\n")
}
'''

ENVIRONMENT = {
    "TL_HOME": "/home/tlang",
    "TL_EQ": "a=b",
    "TL_SPACE": "two words",
    "PATH": "/usr/bin:/bin",
}


def build_stage1(work):
    compiler = os.path.join(work, "tcomp1")
    subprocess.run([sys.executable, TCOMP, "build",
                    os.path.join(ROOT, "tcomp.tl"), "-o", compiler],
                   check=True, capture_output=True)
    return compiler


def build_with_stage0(work):
    text = os.path.join(work, "env0.tl")
    exe = os.path.join(work, "env0")
    with open(text, "w") as fh:
        fh.write(SOURCE)
    subprocess.run([sys.executable, TCOMP, "build", text, "-o", exe],
                   check=True, capture_output=True)
    return exe


def build_with_stage1(compiler, work):
    text = os.path.join(work, "env1.tl")
    asm = os.path.join(work, "env1.s")
    obj = os.path.join(work, "env1.o")
    exe = os.path.join(work, "env1")
    with open(text, "w") as fh:
        fh.write(SOURCE)
    result = subprocess.run([compiler, text], capture_output=True)
    if result.returncode != 0:
        return None, result.stderr.decode()
    with open(asm, "wb") as fh:
        fh.write(result.stdout)
    subprocess.run(["as", "--64", "-mx86-used-note=no", "-o", obj, asm],
                   check=True)
    subprocess.run(["ld", *LDFLAGS, "-o", exe, obj], check=True)
    strip_sections(exe)
    return exe, ""


def run(exe):
    result = subprocess.run([exe, "first"], env=ENVIRONMENT,
                            capture_output=True, text=True)
    return result.returncode, result.stdout


def main():
    work = tempfile.mkdtemp(prefix="tlang-env-")
    failures = []
    try:
        stage0 = build_with_stage0(work)
        stage1 = build_stage1(work)
        expected = (0, "/home/tlang|0|0|a=b|0|two words|first\n")
        for name, exe in (("stage0", stage0), ("stage1", None)):
            if name == "stage1":
                exe, error = build_with_stage1(stage1, work)
                if exe is None:
                    failures.append(f"{name}: {error.strip()}")
                    continue
            result = run(exe)
            if result != expected:
                failures.append(f"{name}: {result!r}")
            else:
                print(f"  ok   {name}")
    finally:
        import shutil
        shutil.rmtree(work, ignore_errors=True)

    if failures:
        for failure in failures:
            print(f"  FAIL {failure}")
        return 1
    print("\nenv() reads the process environment in both compilers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
