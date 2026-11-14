"""Command line interface for tcomp."""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

from . import __version__
from .driver import BuildError, build, compile_path
from .errors import TlangError


def cmd_build(ns):
    asm, module = compile_path(ns.file, opt=not ns.no_opt)
    if ns.ir:
        print(module.format_ir())
        return 0
    if ns.asm:
        print(asm, end="")
        return 0
    out = ns.output or os.path.splitext(os.path.basename(ns.file))[0]
    size = build(asm, out, ns.keep_asm, sstrip=not ns.keep_sections)
    print(f"tcomp: {out} ({size} bytes)")
    return 0


def cmd_run(ns):
    asm, _module = compile_path(ns.file, opt=not ns.no_opt)
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
    b.add_argument("--ir", action="store_true",
                   help="print the generated IR instead of building")
    b.add_argument("--keep-asm", metavar="PATH",
                   help="also write the assembly to PATH")
    b.add_argument("--keep-sections", action="store_true",
                   help="keep ELF section headers (slightly larger, and "
                        "readable by objdump/readelf)")
    b.add_argument("--no-opt", action="store_true",
                   help="skip IR optimization (for debugging codegen)")

    r = sub.add_parser("run", help="compile to a temporary directory and run")
    r.add_argument("file")
    r.add_argument("--no-opt", action="store_true",
                   help="skip IR optimization (for debugging codegen)")
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
    except TlangError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except BuildError as exc:
        print(f"tcomp: {exc}", file=sys.stderr)
        return 1
