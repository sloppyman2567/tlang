#!/usr/bin/env python3
"""Differential tests for Modules/tjson.tl and Modules/tzip.tl.

JSON output is compared with Python's json module; ZIP archives written by
tlang are read with zipfile (including compressed, binary and empty entries),
and archives written by zipfile are read back by tlang. The deflated cases
cover both fixed and dynamic Huffman blocks.
"""

import os
import random
import subprocess
import sys
import tempfile
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from Bootstrap.elf import strip_sections  # noqa: E402

TCOMP = os.path.join(ROOT, "tcomp")
PROGRAM = os.path.join(ROOT, "Tests", "Modules", "stdlib.tl")
LDFLAGS = ["-s", "-z", "noseparate-code", "--build-id=none"]

JSON_EXPECTED = b"""12|tlang|4|1|-1|-1.5e2
-1
{
  "name": "tlang",
  "tags": [
    "fast",
    1,
    true,
    null
  ],
  "nested": {
    "x": -1.5e2
  }
}
{"name":"tlang","tags":["fast",1,true,null],"nested":{"x":-1.5e2}}
-1|object keys must be strings|7
-1|leading zero in number|1
-1|raw control character in string|2
-1|fraction needs a digit|2
"""


def build_stage1(work):
    exe = os.path.join(work, "tcomp1")
    subprocess.run([sys.executable, TCOMP, "build",
                    os.path.join(ROOT, "tcomp.tl"), "-o", exe],
                   check=True, capture_output=True)
    return exe


def link(work, asm_text, name):
    asm = os.path.join(work, name + ".s")
    obj = os.path.join(work, name + ".o")
    exe = os.path.join(work, name)
    with open(asm, "w") as fh:
        fh.write(asm_text)
    subprocess.run(["as", "--64", "-mx86-used-note=no", "-o", obj, asm],
                   check=True)
    subprocess.run(["ld", *LDFLAGS, "-o", exe, obj], check=True)
    strip_sections(exe)
    return exe


def build_program(work, label, compiler):
    exe = os.path.join(work, "stdlib-" + label)
    if compiler is None:
        built = subprocess.run([sys.executable, TCOMP, "build", PROGRAM, "-o", exe],
                               capture_output=True)
        if built.returncode != 0:
            raise RuntimeError(built.stderr.decode(errors="replace"))
        return exe
    built = subprocess.run([compiler, PROGRAM], capture_output=True)
    if built.returncode != 0:
        raise RuntimeError(built.stderr.decode(errors="replace"))
    return link(work, built.stdout.decode(), "stdlib-" + label)


def run(exe, *args, expect=0):
    proc = subprocess.run([exe, *args], capture_output=True)
    if proc.returncode != expect:
        raise AssertionError(
            f"{os.path.basename(exe)} {' '.join(args)} exited "
            f"{proc.returncode}, expected {expect}\n"
            f"stdout: {proc.stdout!r}\nstderr: {proc.stderr!r}")
    return proc.stdout


def expected_listing(path):
    lines = []
    with zipfile.ZipFile(path) as zf:
        lines.append(str(len(zf.infolist())))
        for info in zf.infolist():
            name = info.filename.encode("utf-8")
            data = zf.read(info).hex()
            lines.append(
                f"{name.decode('utf-8', 'replace')}|{info.compress_type}|"
                f"{info.file_size}|{info.CRC & 0xFFFFFFFF}|{data}")
    return ("\n".join(lines) + "\n").encode()


def check_json(exe):
    got = run(exe, "json")
    if got != JSON_EXPECTED:
        raise AssertionError(f"JSON output differs\nwant: {JSON_EXPECTED!r}\n"
                             f"got:  {got!r}")


def check_zip(exe, work):
    archive = os.path.join(work, "tlang.zip")
    if os.path.exists(archive):
        os.unlink(archive)
    if run(exe, "zip-create", archive) != b"created 5\n":
        raise AssertionError("zip-create did not report five entries")

    expected = {
        "hello.txt": b"hello\n",
        "bin.dat": b"\x00\x01\xffA",
        "empty": b"",
        "repeat.txt": b"abcd" * 200,
        "dir/nested.txt": b"nested",
    }
    with zipfile.ZipFile(archive) as zf:
        if zf.testzip() is not None:
            raise AssertionError("zipfile.testzip() found a bad CRC")
        if zf.namelist() != list(expected):
            raise AssertionError(f"names differ: {zf.namelist()!r}")
        repeat = zf.getinfo("repeat.txt")
        if repeat.compress_type != zipfile.ZIP_DEFLATED:
            raise AssertionError("repeat.txt was not deflated")
        if repeat.compress_size >= repeat.file_size:
            raise AssertionError("repeat.txt was not actually smaller")
        if zf.getinfo("empty").compress_type != zipfile.ZIP_STORED:
            raise AssertionError("empty entry should fall back to stored")
        for name, want in expected.items():
            got = zf.read(name)
            if got != want:
                raise AssertionError(f"{name}: {got!r} != {want!r}")

    listing = run(exe, "zip-list", archive)
    want_listing = expected_listing(archive)
    if listing != want_listing:
        raise AssertionError(f"zip-list differs\nwant: {want_listing!r}\n"
                             f"got:  {listing!r}")

    for index, name in enumerate(expected):
        out = os.path.join(work, "extract-%d.bin" % index)
        if os.path.exists(out):
            os.unlink(out)
        if run(exe, "zip-extract", archive, str(index), out) != b"1 0\n":
            raise AssertionError(f"extract of {name} failed")
        with open(out, "rb") as fh:
            if fh.read() != expected[name]:
                raise AssertionError(f"extracted {name} differs")

    # A changed data byte must fail the CRC check, not be extracted silently.
    corrupt = os.path.join(work, "corrupt.zip")
    with open(archive, "rb") as fh:
        blob = bytearray(fh.read())
    at = blob.find(b"hello\n")
    if at < 0:
        raise AssertionError("could not locate hello.txt data")
    blob[at] = blob[at] ^ 1
    with open(corrupt, "wb") as fh:
        fh.write(blob)
    if run(exe, "zip-extract", corrupt, "0",
           os.path.join(work, "corrupt-out.bin")) != b"0 1\n":
        raise AssertionError("corrupt entry was not rejected with ZIP_E_FORMAT")

    # Python-written stored archive: UTF-8 names, binary data and an empty file.
    stored = os.path.join(work, "python-stored.zip")
    with zipfile.ZipFile(stored, "w", zipfile.ZIP_STORED) as zf:
        zf.writestr("a.txt", "alpha\n")
        zf.writestr("raw.bin", bytes([0, 1, 2, 255, 65, 0, 66]))
        zf.writestr("empty", "")
        zf.writestr("naïve.txt", "unicode\n")
    listing = run(exe, "zip-list", stored)
    want_listing = expected_listing(stored)
    if listing != want_listing:
        raise AssertionError(f"stored listing differs\nwant: {want_listing!r}\n"
                             f"got:  {listing!r}")

    # Python uses fixed blocks for tiny inputs and dynamic blocks when the tree
    # pays for itself; both must be listed and extracted byte-for-byte.
    deflated = os.path.join(work, "python-deflated.zip")
    deflated_want = {
        "compressed.txt": ("abcd" * 100).encode(),
        "dynamic.txt": ("the quick brown fox jumps over the lazy dog\n" * 400).encode(),
        "empty": b"",
    }
    with zipfile.ZipFile(deflated, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, data in deflated_want.items():
            zf.writestr(name, data)
    listing = run(exe, "zip-list", deflated)
    want_listing = expected_listing(deflated)
    if listing != want_listing:
        raise AssertionError(f"deflated listing differs\nwant: {want_listing!r}\n"
                             f"got:  {listing!r}")
    for index, name in enumerate(deflated_want):
        out = os.path.join(work, "deflated-%d.bin" % index)
        if run(exe, "zip-extract", deflated, str(index), out) != b"1 0\n":
            raise AssertionError(f"extract of deflated {name} failed")
        with open(out, "rb") as fh:
            if fh.read() != deflated_want[name]:
                raise AssertionError(f"extracted deflated {name} differs")

    # Larger payloads exercise stored DEFLATE blocks (incompressible data) and
    # multiple blocks, not just a single small fixed/dynamic tree.
    stress = os.path.join(work, "python-stress.zip")
    noise = bytes(random.Random(11).randrange(256) for _ in range(20000))
    stress_want = {
        "noise.bin": noise,
        "long.txt": b"abc" * 20000,
    }
    with zipfile.ZipFile(stress, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, data in stress_want.items():
            zf.writestr(name, data)
    for index, name in enumerate(stress_want):
        out = os.path.join(work, "stress-%d.bin" % index)
        if run(exe, "zip-extract", stress, str(index), out) != b"1 0\n":
            raise AssertionError(f"extract of large deflated {name} failed")
        with open(out, "rb") as fh:
            if fh.read() != stress_want[name]:
                raise AssertionError(f"extracted large deflated {name} differs")

    # Truncated and empty inputs are rejected, not read past the buffer.
    broken = os.path.join(work, "broken.zip")
    with open(broken, "wb") as fh:
        fh.write(b"PK\x05\x06")
    if run(exe, "zip-list", broken, expect=1) != b"error 1\n":
        raise AssertionError("truncated archive was not rejected as ZIP_E_FORMAT")
    empty = os.path.join(work, "empty.zip")
    open(empty, "wb").close()
    if run(exe, "zip-list", empty, expect=1) != b"error 3\n":
        raise AssertionError("empty archive was not rejected as ZIP_E_IO")


def check_writer_stress(exe, work):
    archive = os.path.join(work, "tlang-stress.zip")
    if run(exe, "zip-stress", archive) != b"created 3\n":
        raise AssertionError("zip-stress did not report three entries")
    with zipfile.ZipFile(archive) as zf:
        if zf.testzip() is not None:
            raise AssertionError("stress archive has a bad CRC")
        large = zf.getinfo("large.txt")
        if large.compress_type != zipfile.ZIP_DEFLATED or large.compress_size >= large.file_size:
            raise AssertionError("large.txt was not compressed")
        for index, info in enumerate(zf.infolist()):
            out = os.path.join(work, "tlang-stress-%d.bin" % index)
            if run(exe, "zip-extract", archive, str(index), out) != b"1 0\n":
                raise AssertionError(f"extract of tlang {info.filename} failed")
            with open(out, "rb") as fh:
                if fh.read() != zf.read(info):
                    raise AssertionError(f"tlang {info.filename} does not round-trip")


def main():
    with tempfile.TemporaryDirectory(prefix="tlang-stdlib-") as work:
        stage1 = build_stage1(work)
        for label, compiler in (("stage0", None), ("stage1", stage1)):
            case = os.path.join(work, label)
            os.makedirs(case, exist_ok=True)
            exe = build_program(work, label, compiler)
            try:
                check_json(exe)
                check_zip(exe, case)
                check_writer_stress(exe, case)
            except AssertionError as exc:
                print(f"FAIL {label}: {exc}", file=sys.stderr)
                return 1
            print(f"  ok   {label}")
        print("\nJSON and ZIP modules match Python in both compilers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
