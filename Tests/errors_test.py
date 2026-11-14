#!/usr/bin/env python3
"""Both compilers must reject the same kind of type and syntax mistakes.

Each case is a program that should fail to compile, plus a phrase that should
appear in the diagnostic.  The self-hosted compiler is built from the current
tcomp.tl, so this checks both implementations, not a stale binary.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TCOMP = os.path.join(ROOT, "tcomp")
POSITION = re.compile(r":\d+:\d+: error: ")

CASES = [
    ("call type", 'fn f(x: int) { }\nfn main() { f("s") }\n', "argument 1"),
    ("return type", 'fn f() -> int { return "s" }\nfn main() { print_int(f()) }\n',
     "return"),
    ("print_int", 'fn main() { print_int("s") }\n', "print_int"),
    ("print array", 'fn main() { print(alloc(2)) }\n', "print"),
    ("append type", 'fn main() { let a = alloc(2, int)\n  a = append(a, "s") }\n',
     "append"),
    ("switch value", 'fn main() { switch 1 { case "a" { print("x") } } }\n', "case"),
    ("break", 'fn main() { break }\n', "break"),
    ("incdec expr", 'fn main() { let i = 0\n  let x = i++\n  print_int(x) }\n',
     "after '++'"),
    ("comment", '/* unterminated\n', "block comment"),
    ("arity", 'fn f(x: int) { }\nfn main() { f() }\n', "argument"),
    ("len", 'fn main() { print_int(len(3)) }\n', "len"),
    ("slice", 'fn main() { print(slice(3, 0, 1)) }\n', "slice"),
    ("alloc type", 'fn main() { let a = alloc(2, Nope) }\n', "Nope"),
    ("float concat", 'fn main() { print("x" + 1.5) }\n', "concatenate"),
    ("append element type", 'fn main() { append([1], "x") }\n', "append"),
    ("dead code type", 'fn unused() { print_int("s") }\nfn main() { print("hi") }\n',
     "print_int"),
    ("do without while", 'fn main() { do { print("x") } }\n', "while"),
]


def main():
    work = tempfile.mkdtemp(prefix="tlang-errors-")
    failures = []
    try:
        stage1 = os.path.join(work, "tcomp1")
        proc = subprocess.run(
            [sys.executable, TCOMP, "build", os.path.join(ROOT, "tcomp.tl"),
             "-o", stage1], capture_output=True, text=True)
        if proc.returncode != 0:
            print(f"could not build the self-hosted compiler:\n{proc.stderr}")
            return 1

        for i, (name, src, needle) in enumerate(CASES):
            path = os.path.join(work, f"e{i}.tl")
            with open(path, "w") as fh:
                fh.write(src)
            compilers = [
                ("stage0", [sys.executable, TCOMP, "build", path,
                            "-o", os.path.join(work, f"e{i}")]),
                ("stage1", [stage1, path]),
            ]
            ok = True
            for which, argv in compilers:
                result = subprocess.run(argv, capture_output=True, text=True)
                msg = (result.stderr + result.stdout).lower()
                if result.returncode == 0:
                    failures.append(f"{name} [{which}]: accepted; should reject")
                    ok = False
                elif needle.lower() not in msg:
                    failures.append(
                        f"{name} [{which}]: diagnostic lacks {needle!r}\n"
                        f"  {msg.strip()}")
                    ok = False
                elif POSITION.search(result.stderr) is None:
                    failures.append(
                        f"{name} [{which}]: diagnostic lacks file:line:col\n"
                        f"  {result.stderr.strip()}")
                    ok = False
            print(f"  {'ok  ' if ok else 'FAIL'} {name}")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print()
    if failures:
        for failure in failures:
            print(failure)
            print()
        print(f"{len(failures)} failure(s)")
        return 1
    print(f"{len(CASES)} rejected by both compilers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
