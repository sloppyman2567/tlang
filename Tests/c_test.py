#!/usr/bin/env python3
"""C -> tlang translation tests.

Every program in Tests/C/ is built twice: once by gcc, once by translating it
with Tools/ctolang.py and compiling the result with tcomp.  The two binaries
must agree on stdout and exit status, which is the only claim that matters —
"it translated" is not the same as "it still does the same thing".

    python3 Tests/c_test.py            # run
    python3 Tests/c_test.py -v         # also show size ratios
"""

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TCOMP = os.path.join(ROOT, "tcomp")
CTOLANG = os.path.join(ROOT, "Tools", "ctolang.py")
CASES = os.path.join(ROOT, "Tests", "C")

# name -> (arguments after the program name, stdin)
RUNS = {
    "args": (["3", "4", "35"], b""),
    "wc": ([], b"the quick brown fox\njumps over\nthe lazy dog\n"),
    "hello": ([], b""),
}

# Constructs the translator must refuse rather than mistranslate.
REJECTS = [
    ("char *a; if (a == a) { }", "comparing two strings"),
    ("int x; goto out;", "goto"),
    ("printf(\"%5d\", 1);", "field widths"),
    ("switch (1) { case 1: printf(\"a\"); case 2: printf(\"b\"); }",
     "fallthrough"),
    ("int n = sizeof(int);", "sizeof"),
    ("int *p = malloc(sizeof(float) * 2);", "sizeof"),
    ("char *p = malloc(sizeof(char) * 4);", "sizeof"),
]


def sh(argv, **kwargs):
    try:
        return subprocess.run(argv, capture_output=True, timeout=60, **kwargs)
    except subprocess.TimeoutExpired:
        raise SystemExit("timed out: " + " ".join(argv))


def check_case(name, workdir, verbose):
    source = os.path.join(CASES, name + ".c")
    args, stdin = RUNS.get(name, ([], b""))
    failures = []

    gcc_bin = os.path.join(workdir, name + "_gcc")
    build = sh(["gcc", "-O1", "-w", "-o", gcc_bin, source])
    if build.returncode != 0:
        return [f"{name}: gcc failed\n{build.stderr.decode()}"], 0, 0

    tl_source = os.path.join(workdir, name + ".tl")
    conv = sh([sys.executable, CTOLANG, source, "-o", tl_source])
    if conv.returncode != 0:
        return [f"{name}: ctolang failed\n{conv.stderr.decode()}"], 0, 0

    tl_bin = os.path.join(workdir, name + "_tl")
    comp = sh([sys.executable, TCOMP, "build", tl_source, "-o", tl_bin])
    if comp.returncode != 0:
        return [f"{name}: tcomp failed\n{comp.stderr.decode()}"], 0, 0

    want = sh([gcc_bin] + args, input=stdin)
    got = sh([tl_bin] + args, input=stdin)
    if want.stdout != got.stdout:
        failures.append(
            f"{name}: output differs\n  c   : {want.stdout!r}\n  tlang: {got.stdout!r}")
    if want.returncode != got.returncode:
        failures.append(f"{name}: exit {want.returncode} vs {got.returncode}")

    failures.extend(check_selfhosted(name, tl_source, want, args, stdin, workdir))
    return failures, os.path.getsize(gcc_bin), os.path.getsize(tl_bin)


def check_selfhosted(name, tl_source, want, args, stdin, workdir):
    """The translation must also behave when tcomp.tl compiles it."""
    compiler = os.path.join(ROOT, "Build", "tcomp")
    if not os.path.exists(compiler):
        return []
    asm = sh([compiler, tl_source])
    if asm.returncode != 0:
        return [f"{name}: self-hosted compiler failed\n{asm.stderr.decode()}"]
    asm_path = os.path.join(workdir, name + "_s1.s")
    obj_path = os.path.join(workdir, name + "_s1.o")
    exe = os.path.join(workdir, name + "_s1")
    with open(asm_path, "wb") as fh:
        fh.write(asm.stdout)
    if sh(["as", "--64", "-mx86-used-note=no", "-o", obj_path, asm_path]).returncode != 0:
        return [f"{name}: as failed on self-hosted output"]
    if sh(["ld", "-s", "-z", "noseparate-code", "--build-id=none",
           "-o", exe, obj_path]).returncode != 0:
        return [f"{name}: ld failed on self-hosted output"]
    sh([sys.executable, "-m", "bootstrap.elf", exe])
    got = sh([exe] + args, input=stdin)
    if got.stdout != want.stdout or got.returncode != want.returncode:
        return [f"{name}: self-hosted build differs\n"
                f"  c   : {want.stdout!r} ({want.returncode})\n"
                f"  tlang: {got.stdout!r} ({got.returncode})"]
    return []


def main(argv):
    verbose = "-v" in argv
    if not shutil.which("gcc"):
        print("gcc is not installed; cannot check translations")
        return 1
    if not os.path.isdir(CASES):
        print("no Tests/c directory")
        return 1

    workdir = tempfile.mkdtemp(prefix="ctolang-test-")
    failures = []
    total_c = total_tl = 0
    names = sorted(f[:-2] for f in os.listdir(CASES) if f.endswith(".c"))
    try:
        for name in names:
            result, size_c, size_tl = check_case(name, workdir, verbose)
            total_c += size_c
            total_tl += size_tl
            status = "ok" if not result else "FAIL"
            extra = ""
            if verbose and size_c:
                extra = f"   {size_c:>7} B -> {size_tl:>6} B  ({size_c / size_tl:.1f}x)"
            print(f"  {status:4} {name}{extra}")
            failures.extend(result)

        for index, (snippet, expected) in enumerate(REJECTS):
            source = os.path.join(workdir, f"reject{index}.c")
            with open(source, "w") as fh:
                fh.write("int main() {\n  " + snippet + "\n}\n")
            conv = sh([sys.executable, CTOLANG, source, "-o", os.devnull])
            if conv.returncode == 0:
                failures.append(f"reject{index}: accepted {snippet!r}")
            elif expected not in conv.stderr.decode():
                failures.append(
                    f"reject{index}: wrong message for {snippet!r}\n"
                    f"  {conv.stderr.decode().strip()}")
        print(f"  {'ok' if not failures else 'FAIL'}   "
              f"{len(REJECTS)} constructs refused")
    finally:
        if not failures:
            shutil.rmtree(workdir, ignore_errors=True)

    print()
    if failures:
        for failure in failures[:12]:
            print(failure)
            print()
        print(f"{len(failures)} failure(s) (sources kept in {workdir})")
        return 1
    ratio = total_c / total_tl if total_tl else 0
    print(f"{len(names)} C programs translated and behaviourally identical; "
          f"{total_c} B of gcc output vs {total_tl} B of tlang ({ratio:.1f}x)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
