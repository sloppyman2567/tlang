#!/usr/bin/env python3
"""Memory-safety checks must behave the same in both compilers.

Valid accesses keep working, bad array indices and string writes stop before
touching memory, and the allocation/slice guards reject impossible sizes.
"""

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from Bootstrap.driver import AS_FLAGS, LINK_FLAGS  # noqa: E402

TCOMP = os.path.join(ROOT, "tcomp")
TCOMP_TL = os.path.join(ROOT, "tcomp.tl")
OOB = "index out of bounds"
BAD_ALLOC = "invalid allocation size"
BAD_FREE = "invalid free"


def run(argv, **kwargs):
    return subprocess.run(argv, capture_output=True, text=True, **kwargs)


def build_stage0(source, output):
    proc = run([sys.executable, TCOMP, "build", source, "-o", output])
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr or proc.stdout)
    return output


def build_stage1(work):
    output = os.path.join(work, "tcomp1")
    return build_stage0(TCOMP_TL, output)


def build_stage1_program(compiler, source, output):
    asm = output + ".s"
    obj = output + ".o"
    proc = run([compiler, source])
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr or proc.stdout)
    with open(asm, "w", encoding="utf-8") as fh:
        fh.write(proc.stdout)
    proc = run(["as", *AS_FLAGS, "-o", obj, asm])
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr or proc.stdout)
    proc = run(["ld", *LINK_FLAGS, "-o", output, obj])
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr or proc.stdout)
    return output


def check(compiler, work, name, source, stdout, code, stderr=""):
    path = os.path.join(work, name + ".tl")
    out = os.path.join(work, name + "-" + os.path.basename(compiler))
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(source)
    try:
        if os.path.basename(compiler) == "tcomp":
            build_stage0(path, out)
        else:
            build_stage1_program(compiler, path, out)
        result = run([out])
    except RuntimeError as exc:
        return [f"{name} [{compiler}]: build failed\n{exc}"]
    failures = []
    if result.stdout != stdout:
        failures.append(
            f"{name} [{compiler}]: stdout {result.stdout!r}, expected {stdout!r}")
    if result.returncode != code:
        failures.append(
            f"{name} [{compiler}]: exit {result.returncode}, expected {code}")
    if stderr and stderr not in result.stderr:
        failures.append(
            f"{name} [{compiler}]: stderr lacks {stderr!r}: {result.stderr!r}")
    if not stderr and result.stderr:
        failures.append(
            f"{name} [{compiler}]: unexpected stderr {result.stderr!r}")
    return failures


def main():
    work = tempfile.mkdtemp(prefix="tlang-bounds-")
    failures = []
    try:
        stage0 = os.path.join(ROOT, "tcomp")
        try:
            stage1 = build_stage1(work)
        except RuntimeError as exc:
            print(f"could not build the self-hosted compiler:\n{exc}")
            return 1

        valid = '''fn main() {
  let a = alloc(3)
  a[0] = 4
  a[2] = 6
  let s = "abc"
  s[1] = 66
  print_int(a[0] + a[2])
  print(" ")
  print(s)
  print(" ")
  print(slice("abcdef", 2, 3))
  print("\\n")
}
'''
        checks = [
            ("valid", valid, "10 aBc cde\n", 0, ""),
            ("array-read-high",
             'fn main() { let a = alloc(2)\n  print_int(a[2]) }\n',
             "", 134, OOB),
            ("array-read-negative",
             'fn main() { let a = alloc(2)\n  print_int(a[-1]) }\n',
             "", 134, OOB),
            ("array-write-high",
             'fn main() { let a = alloc(2)\n  a[2] = 1 }\n',
             "", 134, OOB),
            ("typed-array-read",
             'struct P { x: int }\nfn main() { let a = alloc(2, P)\n'
             '  a[0] = P(7)\n  print_int(a[0].x) }\n',
             "7", 0, ""),
            ("typed-array-read-high",
             'struct P { x: int }\nfn main() { let a = alloc(2, P)\n'
             '  print_int(a[2].x) }\n',
             "", 134, OOB),
            ("string-read-negative",
             'fn main() { let s = "abc"\n  print_int(s[-1]) }\n',
             "", 134, OOB),
            ("string-write-negative",
             'fn main() { let s = "abc"\n  s[-1] = 65 }\n',
             "", 134, OOB),
            ("string-write-at-nul",
             'fn main() { let s = "abc"\n  s[3] = 33\n  print(s) }\n',
             "abc!", 0, ""),
            ("slice-overrun",
             'fn main() { print(slice("abc", 1, 3)) }\n',
             "", 134, OOB),
            ("slice-negative",
             'fn main() { print(slice("abc", -1, 1)) }\n',
             "", 134, OOB),
            ("alloc-negative",
             "fn main() { alloc(-1) }\n",
             "", 134, BAD_ALLOC),
            ("newbuf-negative",
             "fn main() { newbuf(-1) }\n",
             "", 134, BAD_ALLOC),
            ("free-invalid",
             "fn main() { free(1234) }\n",
             "", 134, BAD_FREE),
            ("free-null",
             'fn main() { free(0)\n  print("ok") }\n',
             "ok", 0, ""),
            ("argv-out-of-range",
             "fn main() { print(argv(9)) }\n",
             "", 0, ""),
            ("interior-pointer",
             'fn main() { let a = alloc(4)\n  a[0] = 1\n  a[1] = 2\n'
             '  let p = a + 1\n  print_int(p[0]) }\n',
             "2", 0, ""),
        ]

        for name, source, stdout, code, stderr in checks:
            for compiler in (stage0, stage1):
                failures.extend(check(
                    compiler, work, name, source, stdout, code, stderr))
                print(f"  {'ok' if not failures else '..'}   {name} "
                      f"[{os.path.basename(compiler)}]")

        # --no-bounds is an opt-out for emulator hot loops: valid programs
        # still run, but the trap routine is not emitted at all.
        nobounds = os.path.join(work, "nobounds.tl")
        with open(nobounds, "w") as fh:
            fh.write('fn main() { let a = alloc(3)\n  a[1] = 7\n'
                     '  print_int(a[1]) }\n')
        for label, argv in (
            ("stage0", [sys.executable, TCOMP, "build", "--asm",
                        "--no-bounds", nobounds]),
            ("stage1", [stage1, "--no-bounds", nobounds]),
        ):
            proc = run(argv)
            if proc.returncode != 0:
                failures.append(f"--no-bounds [{label}]: {proc.stderr.strip()}")
            elif "__t_bounds_fail" in proc.stdout:
                failures.append(f"--no-bounds [{label}]: check still emitted")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print()
    if failures:
        for failure in failures:
            print(failure)
        print(f"{len(failures)} failure(s)")
        return 1
    print(f"{len(checks)} memory-safety case(s) passed in both compilers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
