#!/usr/bin/env python3
"""Both compilers must reject the same programs with the same diagnostic.

Each case is a program that should fail to compile.  Stage 0 and the
self-hosted compiler must both fail, both name a file:line:col, and both print
the same text after `error: ` -- one language, one message.  The columns may
differ (stage 0 reports an expression's start, tlang reports the operator), so
only the text is compared.

`ACCEPT` programs must build and run in both compilers and print the expected
output; those cover the silent divergences (a forward global, a struct used
before its declaration, `\\e` in a character literal, `s += x`).

The self-hosted compiler is built from the current tcomp.tl, so this checks
both implementations, not a stale binary.
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

# name, source, a phrase the diagnostic must contain, extra files to write.
CASES = [
    ("call type", 'fn f(x: int) { }\nfn main() { f("s") }\n',
     "argument 1", None),
    ("return type", 'fn f() -> int { return "s" }\nfn main() { print_int(f()) }\n',
     "returns int", None),
    ("print_int", 'fn main() { print_int("s") }\n', "print_int", None),
    ("print array", 'fn main() { print(alloc(2)) }\n', "print", None),
    ("append type", 'fn main() { let a = alloc(2, int)\n  a = append(a, "s") }\n',
     "append", None),
    ("switch value", 'fn main() { switch 1 { case "a" { print("x") } } }\n',
     "cannot match", None),
    ("string switch", 'fn main() { let s = "a"\n switch s { case 1 { } } }\n',
     "cannot match", None),
    ("float switch", 'fn main() { switch 1.5 { case 1 { } } }\n',
     "float", None),
    ("case literal", 'fn main() { switch 1 { case nope { } } }\n',
     "literal after 'case'", None),
    ("break", 'fn main() { break }\n', "'break'", None),
    ("continue", 'fn main() { continue }\n', "'continue'", None),
    ("compound target", 'fn main() { let a = [1]\n  a[0] += 1 }\n',
     "plain variable", None),
    ("string increment", 'fn main() { let s = "a"\n  s += 1\n  s -= 1 }\n',
     "on strings", None),
    ("comment", '/* unterminated\n', "block comment", None),
    ("unterminated string", 'fn main() { let s = "a\n', "unterminated string", None),
    ("unknown string escape", 'fn main() { print("\\q") }\n',
     "unknown escape '\\q'", None),
    ("unknown char escape", "fn main() { print_int('\\q') }\n",
     "unknown escape '\\q'", None),
    ("short hex escape", 'fn main() { print("\\x4") }\n',
     "\\x needs two hex digits", None),
    ("assign to const", "const N = 5\nfn main() { N = 6 }\n",
     "cannot assign to const 'N'", None),
    ("assign through const", "const N = 3\nfn main() { N[0] = 9 }\n",
     "cannot assign to const 'N'", None),
    ("const needs a literal", "const N = 1.5\nfn main() { print_int(N) }\n",
     "needs an int or string literal", None),
    ("const twice", "const N = 5\nconst N = 6\nfn main() { }\n",
     "const 'N' defined twice", None),
    ("bad hex digits", "fn main() { print_int('\\xq1') }\n",
     "\\x needs two hex digits", None),
    ("long char", "fn main() { print_int('ab') }\n",
     "exactly one character", None),
    ("unexpected character", "fn main() { let x = @ }\n",
     "unexpected character '@'", None),
    ("arity", 'fn f(x: int) { }\nfn main() { f() }\n', "argument", None),
    ("len", 'fn main() { print_int(len(3)) }\n', "len", None),
    ("slice", 'fn main() { print(slice(3, 0, 1)) }\n', "slice", None),
    ("alloc type", 'fn main() { let a = alloc(2, Nope) }\n', "unknown type", None),
    ("alloc arity", 'fn main() { let a = alloc(2, 3) }\n',
     "takes 1 argument", None),
    ("builtin arity", 'fn main() { let a = read_file() }\n',
     "read_file() takes 1 argument(s), got 0", None),
    ("builtin trailing comma", 'fn main() { print(1,) }\n',
     "expected an expression", None),
    ("len trailing comma", 'fn main() { let a = len(1,) }\n',
     "expected an expression", None),
    ("builtin extra args", 'fn main() { print_int(1, 2) }\n',
     "print_int() takes 1 argument(s), got 2", None),
    ("len arity", 'fn main() { let a = len() }\n',
     "len() takes exactly one argument", None),
    ("env type", 'fn main() { let a = env(1) }\n',
     "env() argument 1 should be str, got int", None),
    ("float type", 'fn main() { print_float(float("x")) }\n',
     "float() argument 1 should be int or float, got str", None),
    ("const keyword in diagnostic", 'fn main() { let x = const }\n',
     "found 'const'", None),
    ("float concat", 'fn main() { print("x" + 1.5) }\n', "concatenate", None),
    ("append element type", 'fn main() { append([1], "x") }\n', "append", None),
    ("dead code type", 'fn unused() { print_int("s") }\nfn main() { print("hi") }\n',
     "print_int", None),
    ("do without while", 'fn main() { do { print("x") } }\n', "while", None),
    ("no main", 'fn f() { }\n', "main", None),
    ("main parameters", 'fn main(a) { }\n', "main", None),
    ("duplicate function", 'fn f() { }\nfn f() { }\nfn main() { }\n', "twice", None),
    ("duplicate global", 'let g = 1\nlet g = 2\nfn main() { }\n', "twice", None),
    ("duplicate struct", 'struct S { a }\nstruct S { b }\nfn main() { }\n',
     "twice", None),
    ("duplicate field", 'struct S { a, a }\nfn main() { }\n', "duplicate fields", None),
    ("builtin function", 'fn len(x) { }\nfn main() { }\n', "is a builtin", None),
    ("builtin struct", 'struct int { a }\nfn main() { }\n', "is a builtin", None),
    ("unknown parameter type", 'fn f(x: Nope) { }\nfn main() { }\n',
     "unknown type", None),
    ("unknown field type", 'struct S { a: Nope }\nfn main() { }\n',
     "unknown type", None),
    ("too many parameters", 'fn f(a, b, c, d, e, f, g) { }\nfn main() { }\n',
     "at most 6", None),
    ("modulo string", 'fn main() { print_int("a" % 2) }\n', "on strings", None),
    ("and string", 'fn main() { print_int("a" & 1) }\n', "on strings", None),
    ("shift string", 'fn main() { print_int("a" << 1) }\n', "on strings", None),
    ("logical shift string", 'fn main() { print_int("x" >>> 1) }\n',
     "cannot use '>>>' on strings", None),
    ("unary minus string", 'fn main() { print_int(-"a") }\n', "on a string", None),
    ("complement string", 'fn main() { print_int(~"a") }\n', "on a string", None),
    ("unknown function", 'fn main() { mystery(1) }\n', "unknown function", None),
    ("unknown variable", 'fn main() { print_int(nope) }\n', "unknown variable", None),
    ("struct arity", 'struct S { a, b }\nfn main() { let s = S(1) }\n',
     "field(s)", None),
    ("struct field", 'struct S { a }\nfn main() { let s = S(1)\n print_int(s.zzz) }\n',
     "has no field", None),
    ("field on int", 'fn main() { let x = 1\n print_int(x.a) }\n',
     "cannot read field", None),
    ("missing import", 'import "nope.tl"\nfn main() { }\n',
     "cannot read", {}),
    ("import cycle", 'import "cyc_a.tl"\nfn main() { }\n',
     "import cycle", {"cyc_a.tl": 'import "cyc_a.tl"\n'}),
]

# Import errors belong to a file, not a line, so they carry no line:col.
UNPOSITIONED = {"missing import", "import cycle"}

# name, source, expected stdout
ACCEPT = [
    ("forward global",
     'fn main() { print_int(g)\n print("\\n") }\nlet g = 41\n', "41\n"),
    ("forward struct",
     'fn f(p: Pair) -> int { return p.a }\nstruct Pair { a }\n'
     'fn main() { print_int(f(Pair(7)))\n print("\\n") }\n', "7\n"),
    ("mutual structs",
     'struct A { b: B }\nstruct B { x: int }\n'
     'fn main() { let a = A(B(3))\n print_int(a.b.x)\n print("\\n") }\n', "3\n"),
    ("char escape",
     "fn main() { print_int('\\e')\n print(\"\\n\") }\n", "27\n"),
    ("string compound",
     'fn main() { let s = "n="\n s += 1\n s += "/"\n s += "x"\n'
     ' print(s + "\\n") }\n', "n=1/x\n"),
    ("forward call",
     'fn main() { print_int(add(2, 3))\n print("\\n") }\n'
     'fn add(a: int, b: int) -> int { return a + b }\n', "5\n"),
]


def diagnostic(text):
    """The message after the first `error: `, or None if there is none."""
    if "error: " not in text:
        return None
    return text.split("error: ", 1)[1].strip()


def compile_stage0(work, src, out):
    return subprocess.run(
        [sys.executable, TCOMP, "build", src, "-o", out],
        cwd=work, capture_output=True, text=True)


def compile_stage1(work, stage1, src, out):
    """Ask the self-hosted compiler for assembly, then assemble and link."""
    result = subprocess.run([stage1, src], cwd=work, capture_output=True,
                            text=True)
    if result.returncode != 0:
        return result
    with open(os.path.join(work, src + ".s"), "w") as fh:
        fh.write(result.stdout)
    result = subprocess.run(
        ["as", "--64", "-mx86-used-note=no", "-o", src + ".o", src + ".s"],
        cwd=work, capture_output=True, text=True)
    if result.returncode != 0:
        return result
    return subprocess.run(
        ["ld", "-s", "-z", "noseparate-code", "--build-id=none",
         "-o", out, src + ".o"],
        cwd=work, capture_output=True, text=True)


def main():
    work = tempfile.mkdtemp(prefix="tlang-errors-")
    failures = []
    try:
        stage1 = os.path.join(work, "tcomp1")
        proc = subprocess.run(
            [sys.executable, TCOMP, "build",
             os.path.join(ROOT, "tcomp.tl"), "-o", stage1],
            capture_output=True, text=True)
        if proc.returncode != 0:
            print(f"could not build the self-hosted compiler:\n{proc.stderr}")
            return 1

        for i, (name, src, needle, extra) in enumerate(CASES):
            filename = f"e{i}.tl"
            with open(os.path.join(work, filename), "w") as fh:
                fh.write(src)
            for extra_name, extra_src in (extra or {}).items():
                path = os.path.join(work, extra_name)
                if not os.path.exists(path):
                    with open(path, "w") as fh:
                        fh.write(extra_src)
            results = {
                "stage0": compile_stage0(work, filename, f"e{i}"),
                "stage1": subprocess.run(
                    [stage1, filename], cwd=work, capture_output=True,
                    text=True),
            }
            messages = {}
            ok = True
            for which, result in results.items():
                message = diagnostic(result.stderr)
                messages[which] = message
                if result.returncode == 0:
                    failures.append(
                        f"{name} [{which}]: accepted; should reject")
                    ok = False
                elif message is None:
                    failures.append(
                        f"{name} [{which}]: no 'error: ' in the diagnostic\n"
                        f"  {result.stderr.strip()}")
                    ok = False
                elif (name not in UNPOSITIONED
                      and POSITION.search(result.stderr) is None):
                    failures.append(
                        f"{name} [{which}]: diagnostic lacks file:line:col\n"
                        f"  {result.stderr.strip()}")
                    ok = False
                elif (name in UNPOSITIONED
                      and not re.search(r": error: ", result.stderr)):
                    failures.append(
                        f"{name} [{which}]: diagnostic lacks a file prefix\n"
                        f"  {result.stderr.strip()}")
                    ok = False
                elif needle.lower() not in message.lower():
                    failures.append(
                        f"{name} [{which}]: diagnostic lacks {needle!r}\n"
                        f"  {message}")
                    ok = False
            if ok and messages["stage0"] != messages["stage1"]:
                failures.append(
                    f"{name}: the compilers disagree\n"
                    f"  stage0: {messages['stage0']}\n"
                    f"  stage1: {messages['stage1']}")
                ok = False
            print(f"  {'ok  ' if ok else 'FAIL'} {name}")

        for i, (name, src, expected) in enumerate(ACCEPT):
            filename = f"a{i}.tl"
            with open(os.path.join(work, filename), "w") as fh:
                fh.write(src)
            binaries = {}
            ok = True
            built = {
                "stage0": compile_stage0(work, filename, f"a{i}.s0"),
                "stage1": compile_stage1(work, stage1, filename, f"a{i}.s1"),
            }
            for which, result in built.items():
                if result.returncode != 0:
                    failures.append(
                        f"{name} [{which}]: build failed\n"
                        f"  {(result.stderr or result.stdout).strip()}")
                    ok = False
                    continue
                out = os.path.join(work, f"a{i}.s0" if which == "stage0"
                                   else f"a{i}.s1")
                run = subprocess.run([out], cwd=work, capture_output=True,
                                     text=True)
                binaries[which] = (run.returncode, run.stdout)
                if run.stdout != expected:
                    failures.append(
                        f"{name} [{which}]: output {run.stdout!r}, "
                        f"expected {expected!r}")
                    ok = False
            if ok and binaries["stage0"] != binaries["stage1"]:
                failures.append(
                    f"{name}: the compilers disagree\n"
                    f"  stage0: {binaries['stage0']!r}\n"
                    f"  stage1: {binaries['stage1']!r}")
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
    print(f"{len(CASES)} rejected by both compilers, "
          f"{len(ACCEPT)} accepted and equal")
    return 0


if __name__ == "__main__":
    sys.exit(main())
