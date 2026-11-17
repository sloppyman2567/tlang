#!/usr/bin/env python3
"""Freestanding build mode: the image assumes no Linux under it.

Checks the emitted assembly, links the result against Kernel/kernel.ld, and
checks that both directions of misuse are named errors rather than a crash.
"""

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from Bootstrap.driver import build, compile_source  # noqa: E402
from Bootstrap.errors import TlangError  # noqa: E402

SCRIPT = os.path.join(ROOT, "Kernel", "kernel.ld")


def main():
    failures = []

    hosted, _ = compile_source(
        'fn main() { if argc() > 0 { print(argv(0)) } }')
    free, _ = compile_source('fn main() { print("hi") }', freestanding=True)
    if "syscall" not in hosted:
        failures.append("hosted build lost its exit syscall")
    if "mov rax, [rsp]" not in hosted:
        failures.append("hosted build lost its argv capture")
    if "syscall" in free:
        failures.append("freestanding build contains a syscall")
    if "mov rax, [rsp]" in free:
        failures.append("freestanding build captures argv")
    if ".Lk_halt:" not in free or "  hlt" not in free:
        failures.append("freestanding build does not end in a halt")
    if "67108864" in free or "__t_arena" in free:
        failures.append("freestanding build still reserves the hosted arena")

    alloc_free, _ = compile_source("fn main() { let a = alloc(2) }",
                                   freestanding=True)
    if "__t_alloc:" in alloc_free or "__t_arena" in alloc_free:
        failures.append("freestanding build emits the hosted allocator")

    entry, _ = compile_source("fn kmain() { }", freestanding=True,
                              entry="kmain")
    if "call .Lfn_kmain" not in entry:
        failures.append("--entry does not select the entry function")
    hosted_entry, _ = compile_source("fn kmain() { }", entry="kmain")
    if "call .Lfn_kmain" not in hosted_entry:
        failures.append("--entry does not select the hosted entry function")

    misuse = (
        ("fn main() { let p = peek8(4096) }", False, "--freestanding"),
        ('fn main() { read_file("x") }', True, "--freestanding"),
    )
    for source, freestanding, want in misuse:
        try:
            compile_source(source, freestanding=freestanding)
        except TlangError as exc:
            if want not in str(exc):
                failures.append(
                    f"{source!r}: diagnostic does not name {want}: {exc}")
        else:
            failures.append(f"{source!r} built but should have been refused")

    # A program that needs no runtime links with the kernel script alone.
    bare, _ = compile_source("fn main() { }", freestanding=True)
    workdir = tempfile.mkdtemp(prefix="tlang-free-")
    try:
        out = os.path.join(workdir, "kernel.elf")
        try:
            size = build(bare, out, freestanding=True, script=SCRIPT)
        except Exception as exc:  # BuildError carries the ld message
            failures.append(f"linking with Kernel/kernel.ld failed: {exc}")
        else:
            if not os.path.exists(out) or size <= 0:
                failures.append("linked kernel image is missing")
            else:
                nm = subprocess.run(["nm", out], capture_output=True, text=True)
                if "_start" not in nm.stdout:
                    failures.append("linked kernel image has no _start")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("freestanding mode emits a halt, not a process")
    return 0


if __name__ == "__main__":
    sys.exit(main())
