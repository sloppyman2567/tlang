#!/usr/bin/env python3
"""Contract tests for the assembly runtime.

Every runtime entry must have resolvable dependencies, reference a symbol that
actually assembles, and be reachable through the dependency resolver.  This is
not a behavioural substitute for the program suite; it catches table and
assembly drift before those tests do.
"""

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from Bootstrap.builtin_spec import KERNEL_ONLY  # noqa: E402
from Bootstrap.runtime import (  # noqa: E402
    BUILTINS, RUNTIME, RUNTIME_SYMBOLS, resolve_used,
)
from Bootstrap.driver import AS_FLAGS  # noqa: E402


def main():
    failures = []
    for name, (body, deps) in RUNTIME.items():
        if not body.strip():
            failures.append(f"{name}: empty assembly body")
        for dep in deps:
            if dep != "args" and dep not in RUNTIME:
                failures.append(f"{name}: missing dependency {dep}")
    for name, (_arity, _result, symbol) in BUILTINS.items():
        if name in KERNEL_ONLY:
            if not symbol.startswith("__k_"):
                failures.append(f"builtin {name}: not a __k_ symbol")
            continue
        if symbol not in RUNTIME_SYMBOLS:
            failures.append(f"builtin {name}: missing runtime symbol {symbol}")
    # A freestanding image leaves kernel entries to the linker.
    if resolve_used({"__k_poke8", "__t_print", "__t_alloc"},
                     freestanding=True) != ([], False):
        failures.append("freestanding resolver emitted a kernel symbol")

    for name in RUNTIME:
        try:
            bodies, _args = resolve_used({"__t_" + name})
        except KeyError as exc:
            failures.append(f"{name}: resolver failed: {exc}")
            continue
        if not bodies:
            failures.append(f"{name}: resolver returned no assembly")

    workdir = tempfile.mkdtemp(prefix="tlang-runtime-")
    try:
        asm = [".intel_syntax noprefix", ".text"]
        for _name, (body, _deps) in RUNTIME.items():
            asm.append(body)
        asm.append('.section .note.GNU-stack,"",@progbits')
        asm_path = os.path.join(workdir, "runtime.s")
        obj_path = os.path.join(workdir, "runtime.o")
        with open(asm_path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(asm) + "\n")
        proc = subprocess.run(["as", *AS_FLAGS, "-o", obj_path, asm_path],
                              capture_output=True, text=True)
        if proc.returncode != 0:
            failures.append("assembling all runtime entries failed\n"
                            + proc.stderr.strip())
        else:
            nm = subprocess.run(["nm", obj_path], capture_output=True, text=True)
            if nm.returncode != 0:
                failures.append("nm failed\n" + nm.stderr.strip())
            else:
                for name in RUNTIME:
                    if "__t_" + name not in nm.stdout:
                        failures.append(f"{name}: symbol missing after assembly")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print(f"{len(RUNTIME)} runtime entries assemble and resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
