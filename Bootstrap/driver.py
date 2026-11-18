"""Compile source to assembly, then assemble and link a native binary."""

import os
import re
import shutil
import subprocess
import sys
import tempfile

from .elf import ElfError, strip_sections
from .errors import TlangError

# The compiler lives in tcomp.tl.  Tools/tcomp-seed is the checked-in bootstrap
# binary: it compiles tcomp.tl so the rest of the toolchain can be rebuilt from
# source without a second compiler implementation.
SEED = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    "Tools", "tcomp-seed")

# These flags are most of the reason tlang binaries are tiny:
#   -s                     strip the symbol table
#   -z noseparate-code     no separate read-only segment next to the code
#   --build-id=none        no build-id note
LINK_FLAGS = ["-s", "-z", "noseparate-code", "--build-id=none"]

# `as` adds a 48-byte .note.gnu.property (x86 ISA/feature bits) plus two
# program headers pointing at it.  No loader reads either, so switching it off
# frees 160 bytes of headers.  Small programs keep all of it (hello: 165 bytes
# with alignment); a larger one can spend it again aligning .data to a page.
AS_FLAGS = ["--64", "-mx86-used-note=no"]


class BuildError(Exception):
    pass


class CompileFailed(TlangError):
    """The compiler already printed a positioned diagnostic to stderr.

    Subclasses TlangError so callers that inspect compile diagnostics keep
    working; the CLI catches it first because the message was already printed.
    """


def compile_source(src, filename="<input>", freestanding=False, entry="main",
                   bounds=True):
    """Return (assembly text, None) for inline source."""
    workdir = tempfile.mkdtemp(prefix="tlang-src-")
    try:
        path = os.path.join(workdir, "input.tl")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(src)
        asm, module = compile_path(path, freestanding=freestanding,
                                   entry=entry, bounds=bounds)
        return asm.replace(path, filename), module
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def compile_path(path, freestanding=False, entry="main", bounds=True):
    """Compile a file (and its imports) with the checked-in seed compiler."""
    argv = [SEED]
    if freestanding:
        argv.append("--freestanding")
    if not bounds:
        argv.append("--no-bounds")
    if entry != "main":
        argv += ["--entry", entry]
    argv.append(path)
    proc = subprocess.run(argv, capture_output=True, text=True)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip()
        sys.stderr.write(proc.stderr or proc.stdout)
        raise CompileFailed(detail)
    return proc.stdout, None


def _tool(name):
    path = shutil.which(name)
    if path is None:
        raise BuildError(
            f"'{name}' not found on PATH; tcomp needs binutils to link")
    return path


def _run(argv):
    proc = subprocess.run(argv, capture_output=True, text=True)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise BuildError(f"{os.path.basename(argv[0])} failed:\n{detail}")
    return proc


def build(asm, out_path, asm_path=None, sstrip=True, freestanding=False,
          script=None):
    """Assemble and link `asm` into `out_path`; return the binary size.

    `_start` is the ELF entry point (a linker script may override it), so there
    is no `-e` flag here: the `--entry` option selects the function `_start`
    calls, not the ELF entry symbol.
    """
    as_tool = _tool("as")
    ld_tool = _tool("ld")
    flags = [flag for flag in LINK_FLAGS if not (freestanding and flag == "-s")]
    if script:
        flags += ["-T", script]
    workdir = tempfile.mkdtemp(prefix="tcomp-")
    try:
        src_path = asm_path or os.path.join(workdir, "prog.s")
        obj_path = os.path.join(workdir, "prog.o")
        with open(src_path, "w", encoding="utf-8") as fh:
            fh.write(asm)
        _run([as_tool, *AS_FLAGS, "-o", obj_path, src_path])
        _run([ld_tool, *flags, "-o", out_path, obj_path])
    finally:
        if asm_path is None:
            shutil.rmtree(workdir, ignore_errors=True)
    if sstrip and not freestanding:
        try:
            return strip_sections(out_path)
        except (ElfError, OSError) as exc:
            raise BuildError(f"cannot shrink {out_path}: {exc}") from None
    return os.path.getsize(out_path)


IMPORT_RE = re.compile(
    r'^[ \t]*import[ \t]+"([^"]+)"[ \t]*(?:#.*)?$', re.MULTILINE)


class Source:
    """Expanded source plus a virtual-line -> (file, real line) map."""

    def __init__(self, path, text, locations):
        self.path = path
        self.text = text
        self.locations = locations

    def locate(self, line):
        if 0 < line < len(self.locations):
            return self.locations[line]
        return self.path, line


def _expand_imports(path, seen, lines, locations, display=None):
    """Append one file's lines after its imports, recording their positions.

    `path` is absolute for deduplication; `display` is the path as the user
    wrote it, so diagnostics match the self-hosted compiler's relative paths.
    """
    if display is None:
        display = path
    try:
        with open(path, "r", encoding="utf-8") as fh:
            src = fh.read()
    except OSError as exc:
        raise TlangError(f"cannot read {display}: {exc.strerror}",
                         display) from None

    for number, line in enumerate(src.splitlines(keepends=True), 1):
        match = IMPORT_RE.match(line.rstrip("\r\n"))
        if match is None:
            if not line.endswith("\n"):
                line += "\n"
            lines.append(line)
            locations.append((display, number))
            continue
        name = match.group(1)
        if os.path.isabs(name):
            shown = name
        else:
            shown = os.path.join(os.path.dirname(display), name)
        target = name if os.path.isabs(name) else os.path.join(
            os.path.dirname(path), name)
        target = os.path.abspath(os.path.normpath(target))
        if target in seen:
            raise TlangError(f"import cycle or duplicate: {shown}", display)
        if not os.path.exists(target):
            raise TlangError(f"cannot read {shown}", display)
        seen.add(target)
        _expand_imports(target, seen, lines, locations, shown)


def read_source(path):
    target = os.path.abspath(path)
    lines = []
    locations = [("", 0)]
    _expand_imports(target, {target}, lines, locations, path)
    return Source(path, "".join(lines), locations)
