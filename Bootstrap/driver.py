"""Compile source to assembly, then assemble and link a native binary."""

import os
import re
import shutil
import subprocess
import tempfile

from .elf import ElfError, strip_sections
from .errors import TlangError
from .isa import compile_module
from .lower import lower_program
from .parser import parse

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


def compile_source(src, filename="<input>", opt=True):
    """Return (assembly text, module)."""
    program = parse(src, filename)
    module = lower_program(program, filename, opt)
    return compile_module(module), module


def compile_path(path, opt=True):
    """Compile a file with imports, reporting errors at their real position."""
    source = read_source(path)
    try:
        program = parse(source.text, path)
        module = lower_program(program, path, opt)
    except TlangError as exc:
        exc.remap(source)
        raise
    return compile_module(module), module


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


def build(asm, out_path, asm_path=None, sstrip=True):
    """Assemble and link `asm` into `out_path`; return the binary size."""
    as_tool = _tool("as")
    ld_tool = _tool("ld")
    workdir = tempfile.mkdtemp(prefix="tcomp-")
    try:
        src_path = asm_path or os.path.join(workdir, "prog.s")
        obj_path = os.path.join(workdir, "prog.o")
        with open(src_path, "w", encoding="utf-8") as fh:
            fh.write(asm)
        _run([as_tool, *AS_FLAGS, "-o", obj_path, src_path])
        _run([ld_tool, *LINK_FLAGS, "-o", out_path, obj_path])
    finally:
        if asm_path is None:
            shutil.rmtree(workdir, ignore_errors=True)
    if sstrip:
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


def _expand_imports(path, seen, lines, locations):
    """Append one file's lines after its imports, recording their positions."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            src = fh.read()
    except OSError as exc:
        raise TlangError(f"cannot read {path}: {exc.strerror}") from None

    for number, line in enumerate(src.splitlines(keepends=True), 1):
        match = IMPORT_RE.match(line.rstrip("\r\n"))
        if match is None:
            if not line.endswith("\n"):
                line += "\n"
            lines.append(line)
            locations.append((path, number))
            continue
        name = match.group(1)
        target = name if os.path.isabs(name) else os.path.join(
            os.path.dirname(path), name)
        target = os.path.abspath(os.path.normpath(target))
        if target in seen:
            raise TlangError(f"import cycle or duplicate: {target}")
        seen.add(target)
        _expand_imports(target, seen, lines, locations)


def read_source(path):
    target = os.path.abspath(path)
    lines = []
    locations = [("", 0)]
    _expand_imports(target, {target}, lines, locations)
    return Source(path, "".join(lines), locations)
