"""Command line interface for tcomp."""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

from . import __version__
from .driver import BuildError, CompileFailed, build, compile_path
from .errors import TlangError


def cmd_build(ns):
    asm, module = compile_path(ns.file, freestanding=ns.freestanding,
                               entry=ns.entry, bounds=not ns.no_bounds)
    if ns.asm:
        print(asm, end="")
        return 0
    out = ns.output or os.path.splitext(os.path.basename(ns.file))[0]
    size = build(asm, out, ns.keep_asm, sstrip=not ns.keep_sections,
                 freestanding=ns.freestanding, script=ns.script)
    print(f"tcomp: {out} ({size} bytes)")
    return 0


def cmd_run(ns):
    if ns.freestanding or "--freestanding" in ns.args:
        print("tcomp: --freestanding has nothing to exec into; "
              "use 'tcomp build --freestanding -T SCRIPT'", file=sys.stderr)
        return 1
    asm, _module = compile_path(ns.file)
    workdir = tempfile.mkdtemp(prefix="tcomp-run-")
    try:
        exe = os.path.join(workdir, "prog")
        build(asm, exe)
        proc = subprocess.run([exe, *ns.args])
        return proc.returncode if proc.returncode >= 0 else 128 - proc.returncode
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="tcomp", description="tlang compiler: tiny native binaries")
    ap.add_argument("--version", action="version",
                    version=f"tcomp {__version__}")
    sub = ap.add_subparsers(dest="cmd")

    b = sub.add_parser("build", help="compile a .tl file to a native binary")
    b.add_argument("file")
    b.add_argument("-o", "--output", help="output path (default: source name)")
    b.add_argument("--asm", action="store_true",
                   help="print the generated assembly instead of building")
    b.add_argument("--keep-asm", metavar="PATH",
                   help="also write the assembly to PATH")
    b.add_argument("--keep-sections", action="store_true",
                   help="keep ELF section headers (slightly larger, and "
                        "readable by objdump/readelf)")
    b.add_argument("--no-bounds", action="store_true",
                   help="omit index bounds checks (emulator hot loops only)")
    b.add_argument("--freestanding", action="store_true",
                   help="emit a kernel image: no argv, no exit syscall, and "
                        "runtime entry points come from a kernel runtime")
    b.add_argument("--entry", default="main", metavar="NAME",
                   help="function _start calls (default: main)")
    b.add_argument("-T", "--script", metavar="PATH",
                   help="linker script for the image")

    r = sub.add_parser("run", help="compile to a temporary directory and run")
    r.add_argument("file")
    r.add_argument("--freestanding", action="store_true",
                   help="rejected: a kernel image cannot run as a process")
    r.add_argument("args", nargs=argparse.REMAINDER,
                   help="arguments passed to the program")

    sub.add_parser("version", help="print the tcomp version")

    ns = ap.parse_args(argv)
    if ns.cmd in (None, "version"):
        print(f"tcomp {__version__}")
        return 0

    try:
        if ns.cmd == "build":
            return cmd_build(ns)
        return cmd_run(ns)
    except CompileFailed:
        return 1
    except TlangError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except BuildError as exc:
        print(f"tcomp: {exc}", file=sys.stderr)
        return 1
