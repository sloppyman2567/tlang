#!/usr/bin/env python3
"""Diagnostics in an imported file must name that file, not the entry file.

Both compilers expand imports into one source string, so this checks the line
map that turns a virtual position back into the real file and line.
"""

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TCOMP = os.path.join(ROOT, "tcomp")


def build_stage1(work):
    exe = os.path.join(work, "tcomp1")
    proc = subprocess.run(
        [sys.executable, TCOMP, "build", os.path.join(ROOT, "tcomp.tl"),
         "-o", exe], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr)
    return exe


def check(work, stage1, name, files, entry, expected):
    case = os.path.join(work, name)
    os.makedirs(case, exist_ok=True)
    for filename, text in files.items():
        with open(os.path.join(case, filename), "w") as fh:
            fh.write(text)
    source = os.path.join(case, entry)
    failures = []
    for label, argv in (
        ("stage0", [sys.executable, TCOMP, "build", source,
                    "-o", os.path.join(case, "out")]),
        ("stage1", [stage1, source]),
    ):
        proc = subprocess.run(argv, capture_output=True, text=True)
        if proc.returncode == 0:
            failures.append(f"{name} [{label}]: accepted; should reject")
            continue
        if expected not in proc.stderr:
            failures.append(
                f"{name} [{label}]: expected {expected!r} in diagnostic, "
                f"got:\n{proc.stderr.strip()}")
    return failures


def main():
    work = tempfile.mkdtemp(prefix="tlang-sourcemap-")
    try:
        stage1 = build_stage1(work)
        failures = []
        failures += check(
            work, stage1, "direct",
            {
                "main.tl": 'import "lib.tl"\nfn main() { print_int(helper()) }\n',
                "lib.tl": 'fn helper() -> int {\n  return "not an int"\n}\n',
            },
            "main.tl", "lib.tl:2:",
        )
        failures += check(
            work, stage1, "nested",
            {
                "main.tl": 'import "a.tl"\nfn main() { print_int(helper()) }\n',
                "a.tl": 'import "b.tl"\n',
                "b.tl": 'fn helper() -> int {\n  return "not an int"\n}\n',
            },
            "main.tl", "b.tl:2:",
        )
    except RuntimeError as exc:
        print(f"could not build the self-hosted compiler:\n{exc}")
        return 1
    finally:
        shutil.rmtree(work, ignore_errors=True)

    if failures:
        print("\n".join(failures))
        return 1
    print("imported-file diagnostics name the imported file in both compilers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
