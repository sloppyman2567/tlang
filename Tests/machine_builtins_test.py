#!/usr/bin/env python3
"""Machine builtins: kernel-only, listed once, linkable against the runtime.

Compiles one program that uses every machine builtin, links it with
Kernel/kruntime.s, and checks the kernel runtime defines the whole contract.
"""

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from Bootstrap.builtin_spec import (  # noqa: E402
    BUILTIN_SPECS, HOSTED_ONLY, KERNEL_ONLY,
)
from Bootstrap.builtins_gen import BUILTIN_IDS  # noqa: E402
from Bootstrap.driver import AS_FLAGS, compile_source  # noqa: E402
from Bootstrap.errors import TlangError  # noqa: E402

TCOMP = os.path.join(ROOT, "tcomp")
SCRIPT = os.path.join(ROOT, "Kernel", "kernel.ld")
RUNTIME = os.path.join(ROOT, "Kernel", "kruntime.s")
FONT = os.path.join(ROOT, "Kernel", "font8.s")

# print/alloc/exit are kernel-provided runtime entries the runtime must define.
KERNEL_SYMBOLS = ("__t_print", "__t_print_err", "__t_print_char",
                  "__t_print_int", "__t_alloc", "__t_exit", "__t_bounds_fail")

PROGRAM = """fn main() {
  let p = 4096
  poke8(p, 0)
  poke16(p, 0)
  poke32(p, 0)
  poke64(p, 0)
  let seen = peek8(p) + peek16(p) + peek32(p) + peek64(p)
  outb(1016, 65)
  let port = inb(1016)
  io_wait()
  cli()
  sti()
  hlt()
  lgdt(p)
  lidt(p)
  ltr(0)
  invlpg(p)
  let cr = read_cr2() + read_cr3()
  write_cr3(cr)
  fb_fill(0, 0, 8, 8, 1)
  fb_text(0, 0, 15, "k")
  fb_char(0, 0, 15, 65)
  let disk = ata_read(0, 1, p) + ata_write(1, 1, p)
  let screen = fb_back() + fb_present(0, 0, 8, 8)
  let clip = fb_clip(0, 0, 8, 8)
  let pic = fb_indexed(0, 0, 2, p, 4, 4)
  let dirty = console_dirty()
  console_place(8, 30)
  console_hide()
  let stamp = rdtsc()
  print("kernel ")
  print(seen + port + stamp + disk + screen + clip + pic + dirty)
  alloc(4)
  iretq(p)
}
"""


def main():
    failures = []
    symbols = {name: symbol for name, _ident, _arity, _result, symbol,
               _args, _stage0 in BUILTIN_SPECS}

    # The self-hosted compiler has its own machine-builtin parser.  Both must
    # accept every declared builtin, not just stage 0.
    workdir = tempfile.mkdtemp(prefix="tlang-machine-")
    stage1 = os.path.join(workdir, "tcomp1")
    proc = subprocess.run(
        [sys.executable, TCOMP, "build", os.path.join(ROOT, "tcomp.tl"),
         "-o", stage1], capture_output=True, text=True)
    if proc.returncode != 0:
        print(f"could not build the self-hosted compiler:\n{proc.stderr}")
        return 1
    prog_path = os.path.join(workdir, "prog.tl")
    with open(prog_path, "w", encoding="utf-8") as fh:
        fh.write(PROGRAM)
    proc = subprocess.run([stage1, "--freestanding", prog_path],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        failures.append("stage 1 cannot compile the machine builtins:\n"
                        f"{proc.stderr.strip()}")
    else:
        for name in sorted(KERNEL_ONLY):
            if f"call {symbols[name]}" not in proc.stdout:
                failures.append(f"stage 1 missed {symbols[name]}")

    if KERNEL_ONLY & HOSTED_ONLY:
        failures.append("a builtin is both kernel-only and hosted-only")
    for name in sorted(KERNEL_ONLY):
        if name not in BUILTIN_IDS:
            failures.append(f"{name}: kernel builtin is not in the table")
        elif not symbols[name].startswith("__k_"):
            failures.append(f"{name}: called symbol is {symbols[name]}, "
                            f"not __k_<name>")

    asm, _ = compile_source(PROGRAM, freestanding=True)
    for name in sorted(KERNEL_ONLY):
        if f"call {symbols[name]}" not in asm:
            failures.append(f"{name}: no call to {symbols[name]}")
    if "syscall" in asm:
        failures.append("kernel program contains a syscall")

    try:
        compile_source(PROGRAM)
    except TlangError as exc:
        if "--freestanding" not in str(exc):
            failures.append(f"hosted diagnostic does not name the fix: {exc}")
    else:
        failures.append("machine builtins compiled in a hosted build")

    try:
        obj = os.path.join(workdir, "kruntime.o")
        proc = subprocess.run(["as", "--64", "-mx86-used-note=no", "-o", obj,
                               RUNTIME], capture_output=True, text=True)
        if proc.returncode != 0:
            failures.append(f"assembling Kernel/kruntime.s failed:\n"
                            f"{proc.stderr.strip()}")
        else:
            nm = subprocess.run(["nm", obj], capture_output=True, text=True)
            for name in sorted(KERNEL_ONLY):
                if symbols[name] not in nm.stdout:
                    failures.append(f"kernel runtime misses {symbols[name]}")
            for name in KERNEL_SYMBOLS:
                if name not in nm.stdout:
                    failures.append(f"kernel runtime misses {name}")

            # Link the way Kernel/build.sh does: program, runtime and font.
            out = os.path.join(workdir, "kernel.elf")
            obj2 = os.path.join(workdir, "prog.o")
            asm_path = os.path.join(workdir, "prog.s")
            with open(asm_path, "w", encoding="utf-8") as fh:
                fh.write(asm)
            subprocess.run(["as", *AS_FLAGS, "-o", obj2, asm_path], check=True)
            data_objs = []
            for path in (FONT,):
                data_obj = os.path.join(
                    workdir, os.path.basename(path).replace(".s", ".o"))
                proc = subprocess.run(["as", "--64", "-mx86-used-note=no",
                                       "-o", data_obj, path],
                                      capture_output=True, text=True)
                if proc.returncode != 0:
                    failures.append(f"assembling {path} failed:\n"
                                    f"{proc.stderr.strip()}")
                    raise SystemExit(1)
                data_objs.append(data_obj)
            proc = subprocess.run(
                ["ld", "-z", "noseparate-code", "--build-id=none",
                 "-T", SCRIPT, "-o", out, obj2, obj, *data_objs],
                capture_output=True, text=True)
            if proc.returncode != 0:
                failures.append("linking the kernel runtime failed:\n"
                                f"{proc.stderr.strip()}")
            else:
                nm = subprocess.run(["nm", out], capture_output=True,
                                    text=True)
                if "_start" not in nm.stdout:
                    failures.append("kernel image has no _start")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print(f"{len(KERNEL_ONLY)} machine builtins compile to __k_ stubs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
