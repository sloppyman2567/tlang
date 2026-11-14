#!/usr/bin/env python3
"""Test the text-file output builtins in both compilers.

The main case writes, appends, checks existence, and reads the result back.
A second no-output case catches a missing __t_strlen dependency in the
self-hosted compiler.
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


def build_stage1(work):
    compiler = os.path.join(work, "tcomp1")
    subprocess.run([sys.executable, TCOMP, "build",
                    os.path.join(ROOT, "tcomp.tl"), "-o", compiler],
                   check=True, capture_output=True)
    return compiler


def source(path):
    return f'''fn main() {{
  let path = "{path}"
  print_int(write_file(path, "one\\n"))
  print_int(append_file(path, "two\\n"))
  print_int(file_exists(path))
  print_int(file_exists(path + ".missing"))
  print("\\n")
  let data = read_file(path)
  print_int(len(data))
  print("\\n")
  print(data)
}}
'''


def silent_source(path):
    return f'''fn main() {{
  let ok = write_file("{path}", "silent")
}}
'''


def build_with_stage1(compiler, src, work, name):
    text = os.path.join(work, name + ".tl")
    asm = os.path.join(work, name + ".s")
    obj = os.path.join(work, name + ".o")
    exe = os.path.join(work, name)
    with open(text, "w") as fh:
        fh.write(src)
    result = subprocess.run([compiler, text], capture_output=True)
    if result.returncode != 0:
        return None, result.stderr.decode()
    with open(asm, "wb") as fh:
        fh.write(result.stdout)
    subprocess.run(["as", "--64", "-mx86-used-note=no", "-o", obj, asm], check=True)
    subprocess.run(["ld", *LDFLAGS, "-o", exe, obj], check=True)
    strip_sections(exe)
    return exe, ""


def main():
    work = tempfile.mkdtemp(prefix="tlang-io-")
    failures = []
    try:
        stage1 = build_stage1(work)
        stage0_size = 0

        compilers = [("stage0", None), ("stage1", stage1)]
        for which, compiler in compilers:
            path = os.path.join(work, "out-" + which + ".txt")
            src_path = os.path.join(work, "main-" + which + ".tl")
            with open(src_path, "w") as fh:
                fh.write(source(path))
            if which == "stage0":
                exe = os.path.join(work, "main-" + which)
                proc = subprocess.run([sys.executable, TCOMP, "build",
                                       src_path, "-o", exe],
                                      capture_output=True)
            else:
                exe, err = build_with_stage1(compiler, source(path), work,
                                             "main-" + which)
                proc = subprocess.CompletedProcess([], 0 if exe else 1,
                                                   b"", err.encode())
            if proc.returncode != 0:
                failures.append(f"{which}: build failed\n{proc.stderr}")
                continue
            if which == "stage0":
                stage0_size = os.path.getsize(exe)
            run = subprocess.run([exe], capture_output=True)
            want = b"1110\n8\none\ntwo\n"
            if run.stdout != want or run.returncode != 0:
                failures.append(
                    f"{which}: round-trip mismatch\n"
                    f"  expected {want!r} (exit 0)\n"
                    f"  got      {run.stdout!r} (exit {run.returncode})")
            if not os.path.exists(path) or open(path, "rb").read() != b"one\ntwo\n":
                failures.append(f"{which}: unexpected file contents")

            # No print() here: write_file must pull in __t_strlen by itself.
            silent_path = os.path.join(work, "silent-" + which + ".txt")
            silent = silent_source(silent_path)
            if which == "stage0":
                text = os.path.join(work, "silent-" + which + ".tl")
                exe2 = os.path.join(work, "silent-" + which)
                with open(text, "w") as fh:
                    fh.write(silent)
                result = subprocess.run([sys.executable, TCOMP, "build",
                                         text, "-o", exe2],
                                        capture_output=True)
                if result.returncode == 0:
                    result = subprocess.run([exe2], capture_output=True)
            else:
                exe2, err = build_with_stage1(compiler, silent, work,
                                               "silent-" + which)
                result = subprocess.CompletedProcess([], 0 if exe2 else 1,
                                                     b"", err.encode())
                if result.returncode == 0:
                    result = subprocess.run([exe2], capture_output=True)
            if result.returncode != 0:
                failures.append(f"{which}: silent write failed\n{result.stderr}")
            elif open(silent_path, "rb").read() != b"silent":
                failures.append(f"{which}: silent write produced wrong file")
            print(f"  {'ok  ' if not failures else 'FAIL'} {which}")

        print(f"  stage0 test binary={stage0_size} bytes, "
              f"self-hosted compiler={os.path.getsize(stage1)} bytes")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    if failures:
        print()
        for failure in failures:
            print(failure)
            print()
        print(f"{len(failures)} failure(s)")
        return 1
    print("\nfile I/O works in both compilers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
