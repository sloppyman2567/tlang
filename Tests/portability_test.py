#!/usr/bin/env python3
"""Test the common Linux builtins in both compilers.

Time, entropy, process identity and directory operations are checked for
behaviour rather than fixed output: a timestamp or pid is not reproducible,
so the programs report invariants and the harness runs them in a private
temporary directory. Both stage 0 and the self-hosted compiler must agree.
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

TIME_SRC = '''fn main() {
  print_int(now() > 0)
  print(" ")
  print_int(sleep_ns(1000000) == 0)
  print(" ")
  print_int(getpid() > 0)
  print(" ")
  print(getcwd())
  print(" ")
  let a = random_int()
  let b = random_int()
  print_int(a != b)
  print("\\n")
}
'''

FS_SRC = '''fn main() {
  print_int(mkdir(argv(1), 493))
  print(" ")
  print_int(write_file(argv(2), "hi"))
  print(" ")
  print_int(rename(argv(2), argv(3)))
  print(" ")
  print_int(unlink(argv(3)))
  print(" ")
  print_int(file_exists(argv(3)))
  print("\\n")
}
'''

BAD_ARGS = (
    ('fn main() { now(1) }', 'now'),
    ('fn main() { sleep_ns("x") }', 'sleep_ns'),
    ('fn main() { mkdir(1, 2) }', 'mkdir'),
    ('fn main() { rename("a", 3) }', 'rename'),
)


def build_stage1(work):
    compiler = os.path.join(work, "tcomp1")
    subprocess.run([sys.executable, TCOMP, "build",
                    os.path.join(ROOT, "tcomp.tl"), "-o", compiler],
                   check=True, capture_output=True)
    return compiler


def build(source, compiler, work, name):
    text = os.path.join(work, name + ".tl")
    exe = os.path.join(work, name)
    with open(text, "w", encoding="utf-8") as fh:
        fh.write(source)
    if compiler is None:
        subprocess.run([sys.executable, TCOMP, "build", text, "-o", exe],
                       check=True, capture_output=True)
        return exe
    proc = subprocess.run([compiler, text], capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode(errors="replace"))
    asm = os.path.join(work, name + ".s")
    obj = os.path.join(work, name + ".o")
    with open(asm, "wb") as fh:
        fh.write(proc.stdout)
    subprocess.run(["as", "--64", "-mx86-used-note=no", "-o", obj, asm],
                   check=True)
    subprocess.run(["ld", *LDFLAGS, "-o", exe, obj], check=True)
    strip_sections(exe)
    return exe


def check_rejections(compiler, failures, label):
    for source, name in BAD_ARGS:
        if compiler is None:
            proc = subprocess.run([sys.executable, TCOMP, "build", "-", "-o",
                                   os.devnull], input=source, text=True,
                                  capture_output=True)
        else:
            proc = subprocess.run([compiler, "-"], input=source, text=True,
                                  capture_output=True)
        if proc.returncode == 0:
            failures.append(f"{label}: {name}() accepted bad arguments")


def main():
    work = tempfile.mkdtemp(prefix="tlang-portability-")
    failures = []
    try:
        stage1 = build_stage1(work)
        for label, compiler in (("stage0", None), ("stage1", stage1)):
            time_exe = build(TIME_SRC, compiler, work, "time-" + label)
            fs_exe = build(FS_SRC, compiler, work, "fs-" + label)

            got = subprocess.run([time_exe], cwd=work, capture_output=True,
                                 text=True)
            want = f"1 1 1 {work} 1\n"
            if (got.returncode, got.stdout) != (0, want):
                failures.append(f"{label}: time {got.returncode} {got.stdout!r}")

            path = os.path.join(work, "ops-" + label)
            a = os.path.join(path, "a.txt")
            b = os.path.join(path, "b.txt")
            got = subprocess.run([fs_exe, path, a, b], capture_output=True,
                                 text=True)
            if (got.returncode, got.stdout) != (0, "0 1 0 0 0\n"):
                failures.append(f"{label}: fs {got.returncode} {got.stdout!r}")
            shutil.rmtree(path, ignore_errors=True)

            check_rejections(compiler, failures, label)
            if not any(f.startswith(label) for f in failures):
                print(f"  ok   {label}")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    if failures:
        for failure in failures:
            print("  FAIL " + failure)
        return 1
    print("\ncommon Linux builtins work in both compilers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
