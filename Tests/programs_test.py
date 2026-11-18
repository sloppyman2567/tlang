#!/usr/bin/env python3
"""Behavioural tests for the programs in Programs/.

Each case builds a program, runs it with real arguments and stdin, and compares
stdout and exit status. Three of the checks go further than expected strings:

  tbox   is compared against the system wc/grep/head/tail, byte for byte
  tjson  is compared against Python's json module on generated documents
  tbf    is proved by running Brainfuck programs whose output is known

    python3 Tests/programs_test.py
"""

import json
import os
import random
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TCOMP = os.path.join(ROOT, "tcomp")
PROGRAMS = os.path.join(ROOT, "Programs")

sys.path.insert(0, ROOT)
from Bootstrap.elf import strip_sections  # noqa: E402

LDFLAGS = ["-s", "-z", "noseparate-code", "--build-id=none"]

SAMPLE_JSON = (
    b'{"name":"tlang","version":"1.0.0","tags":["tiny","fast"],'
    b'"nested":{"a":1,"b":[true,false,null]},"pi":3.14159,'
    b'"esc":"line\\nbreak \\"q\\" \\u0041"}'
)

HELLO_BF = b"""Hello World in Brainfuck
++++++++[>++++[>++>+++>+++>+<<<<-]>+>+>->>+[<]<-]>>.>---.+++++++..+++.>>.<-.<.+++.------.--------.>>+.>++.
"""

# clear, I = 0x300, V0 = V1 = 0, draw one row at (0,0), loop; sprite at 0x300.
DRAW_ROM = (bytes.fromhex("00E0A30060006100D011120A")
            + bytes(0x100 - 12) + b"\x80")
ONE_PIXEL_FRAME = ("#" + "." * 63 + "\n" + ("." * 64 + "\n") * 31).encode()

# A 32 KB Game Boy ROM: write 0x42 and 0x99 to 0xC000/0xC001, then spin.
GB_ROM = bytearray(0x8000)
_gb_code = bytes.fromhex("3E42EA00C03E99EA01C018FE")
GB_ROM[0x100:0x100 + len(_gb_code)] = _gb_code
GB_ROM[0x134:0x13C] = b"TGAMEBOY"
GB_ROM = bytes(GB_ROM)
GB_DUMP = ("42 99 " + " ".join(["00"] * 30) + "\n").encode()

# name -> bytes written into the temp dir, referenced from cases as {name}
FIXTURES = {
    "draw.ch8": DRAW_ROM,
    "demo.gb": GB_ROM,
    "sample.json": SAMPLE_JSON,
    "bracket.json": b'{"a.b":1,"a\\u0062":2,"quote\\"key":3}',
    "pointer.json": (b'{"foo":["bar","baz"],"":0,"a/b":1,"c%d":2,'
                     b'"e^f":3,"g|h":4,"i\\\\j":5,"k\\"l":6," ":7,"m~n":8}'),
    "unicode.json": b'{"caf\\u00e9":"caf\\u00e9","\\uD834\\uDD1E":"clef"}',
    "pretty.json": b'{ "a" : [ 1 , 2 ] , "b" : { } , "c" : [ ] }\n',
    "bad.json": b'{"a":1,}',
    "empty.json": b"",
    "hello.bf": HELLO_BF,
    "cat.bf": b",[.,]",
    "mul.bf": b"+++++[>+++++++++++<-]>.",
    "wrap.bf": b"-.",
    "wrapback.bf": b"<+.",
    "clear.bf": b"+++++[-].",
    "clearplus.bf": b"+++++[+].",
    "open.bf": b"[",
}

# name, argv[1:], stdin, expected stdout (None = ignore), expected exit status
CASES = {
    "tbox": [
        ("wc words", ["wc"], b"alpha beta\ngamma\n", b"2 3 17\n", 0),
        ("wc empty", ["wc"], b"", b"0 0 0\n", 0),
        ("wc no trailing newline", ["wc"], b"a b", b"1 2 3\n", 0),
        ("wc blank lines", ["wc"], b"a\n\n\nb\n", b"4 2 6\n", 0),
        ("wc tabs", ["wc"], b"a\tb  c\n", b"1 3 7\n", 0),
        ("grep hit", ["grep", "beta"], b"alpha\nbeta\n", b"beta\n", 0),
        ("grep miss", ["grep", "nope"], b"alpha\nbeta\n", b"", 1),
        ("grep -n", ["grep", "-n", "a"], b"x\nalpha\n", b"2:alpha\n", 0),
        ("grep -c", ["grep", "-c", "a"], b"x\nalpha\ngamma\n", b"2\n", 0),
        ("grep -v", ["grep", "-v", "a"], b"x\nalpha\ngamma\n", b"x\n", 0),
        ("grep -i", ["grep", "-i", "ALPHA"], b"alpha\nBeta\n", b"alpha\n", 0),
        ("grep -in", ["grep", "-in", "beta"], b"x\nBETA\n", b"2:BETA\n", 0),
        ("grep empty pattern", ["grep", "-c", ""], b"a\n\nb\n", b"3\n", 0),
        ("head", ["head", "-n", "2"], b"1\n2\n3\n4\n", b"1\n2\n", 0),
        ("head default", ["head"], b"1\n2\n3\n", b"1\n2\n3\n", 0),
        ("head n=0", ["head", "-n", "0"], b"1\n2\n", b"", 0),
        ("tail", ["tail", "-n", "2"], b"1\n2\n3\n4\n", b"3\n4\n", 0),
        ("tail more than file", ["tail", "-n", "9"], b"1\n2\n", b"1\n2\n", 0),
        ("tail n=0", ["tail", "-n", "0"], b"1\n2\n", b"", 0),
        ("usage", [], b"", None, 2),
        ("unknown tool", ["nope"], b"", None, 2),
        ("grep needs a pattern", ["grep"], b"", None, 2),
        ("grep bad option", ["grep", "-Z", "x"], b"", None, 2),
    ],
    "tjson": [
        ("fmt", ["fmt", "{sample.json}"], b"", None, 0),
        ("fmt --compact", ["fmt", "--compact", "{sample.json}"], b"", None, 0),
        ("fmt empty containers", ["fmt", "{pretty.json}"], b"", None, 0),
        ("fmt from stdin", ["fmt"], SAMPLE_JSON, None, 0),
        ("get string", ["get", ".name", "{sample.json}"], b"", b"tlang\n", 0),
        ("get number", ["get", ".pi", "{sample.json}"], b"", b"3.14159\n", 0),
        ("get bool", ["get", ".nested.b[0]", "{sample.json}"], b"", b"true\n", 0),
        ("get null", ["get", ".nested.b[2]", "{sample.json}"], b"", b"null\n", 0),
        ("get nested", ["get", ".nested.a", "{sample.json}"], b"", b"1\n", 0),
        ("get decoded escape", ["get", ".esc", "{sample.json}"], b"",
         b'line\nbreak "q" A\n', 0),
        ("get without dot", ["get", "tags[1]", "{sample.json}"], b"",
         b"fast\n", 0),
        ("get negative index", ["get", ".tags[-1]", "{sample.json}"], b"",
         b"fast\n", 0),
        ("get negative zero", ["get", ".tags[-0]", "{sample.json}"], b"",
         b"tiny\n", 0),
        ("get negative missing", ["get", ".tags[-9]", "{sample.json}"], b"",
         None, 1),
        ("get leading zero index", ["get", ".tags[01]", "{sample.json}"], b"",
         b"fast\n", 0),
        ("get plus index", ["get", ".tags[+1]", "{sample.json}"], b"", None, 1),
        ("get trailing dot", ["get", ".name.", "{sample.json}"], b"", None, 1),
        ("get pointer nested", ["get", "--pointer", "/foo/0",
                                "{pointer.json}"], b"", b"bar\n", 0),
        ("get pointer slash escape", ["get", "--pointer", "/a~1b",
                                      "{pointer.json}"], b"", b"1\n", 0),
        ("get pointer tilde escape", ["get", "--pointer", "/m~0n",
                                      "{pointer.json}"], b"", b"8\n", 0),
        ("get pointer empty key", ["get", "--pointer", "/",
                                   "{pointer.json}"], b"", b"0\n", 0),
        ("get pointer backslash key", ["get", "--pointer", "/i\\\\j",
                                      "{pointer.json}"], b"", b"5\n", 0),
        ("get pointer quote key", ["get", "--pointer", '/k"l',
                                   "{pointer.json}"], b"", b"6\n", 0),
        ("keys pointer root", ["keys", "--pointer", "", "{pointer.json}"],
         b"", b"foo\n\na/b\nc%d\ne^f\ng|h\ni\\j\nk\"l\n \nm~n\n", 0),
        ("get pointer leading zero", ["get", "--pointer", "/foo/01",
                                      "{pointer.json}"], b"", None, 1),
        ("get pointer end marker", ["get", "--pointer", "/foo/-",
                                    "{pointer.json}"], b"", None, 1),
        ("get pointer bad escape", ["get", "--pointer", "/a~2b",
                                    "{pointer.json}"], b"", None, 1),
        ("get pointer missing", ["get", "--pointer", "/missing",
                                 "{pointer.json}"], b"", None, 1),
        ("get unicode escape", ["get", '.["caf\\u00e9"]', "{unicode.json}"],
         b"", b"caf\xc3\xa9\n", 0),
        ("get astral escape", ["get", '.["\\uD834\\uDD1E"]', "{unicode.json}"],
         b"", b"clef\n", 0),
        ("keys unicode escapes", ["keys", ".", "{unicode.json}"], b"",
         b"caf\xc3\xa9\n\xf0\x9d\x84\x9e\n", 0),
        ("get too many arguments", ["get", ".name", "{sample.json}", "extra"],
         b"", None, 2),
        ("get dotted key", ["get", '.["a.b"]', "{bracket.json}"], b"",
         b"1\n", 0),
        ("get escaped key", ["get", ".ab", "{bracket.json}"], b"",
         b"2\n", 0),
        ("get quoted escaped key", ["get", '.["quote\\"key"]',
                                    "{bracket.json}"], b"", b"3\n", 0),
        ("keys with escaped names", ["keys", ".", "{bracket.json}"], b"",
         b'a.b\nab\nquote"key\n', 0),
        ("get missing", ["get", ".nope", "{sample.json}"], b"", None, 1),
        ("get bad index", ["get", ".tags[9]", "{sample.json}"], b"", None, 1),
        ("keys", ["keys", ".", "{sample.json}"], b"",
         b"name\nversion\ntags\nnested\npi\nesc\n", 0),
        ("keys of an array", ["keys", ".tags", "{sample.json}"], b"", None, 1),
        ("reject trailing comma", ["fmt", "{bad.json}"], b"", None, 2),
        ("reject empty input", ["fmt", "{empty.json}"], b"", None, 2),
        ("usage", [], b"", None, 2),
        ("unknown command", ["nope"], b"", None, 2),
    ],
    "tchip8": [
        ("draw one pixel", ["{draw.ch8}", "100"], b"", ONE_PIXEL_FRAME, 0),
    ],
    "tgameboy": [
        ("cpu dump", ["{demo.gb}", "30"], b"", GB_DUMP, 0),
    ],
    "tbf": [
        ("hello world", ["{hello.bf}"], b"", b"Hello World!\n", 0),
        ("cat", ["{cat.bf}"], b"echo me", b"echo me", 0),
        ("multiply 5x11", ["{mul.bf}"], b"", b"7", 0),
        ("cell wraps at zero", ["{wrap.bf}"], b"", b"\xff", 0),
        ("tape wraps backwards", ["{wrapback.bf}"], b"", b"\x01", 0),
        ("[-] clears the cell", ["{clear.bf}"], b"", b"\x00", 0),
        ("[+] clears the cell", ["{clearplus.bf}"], b"", b"\x00", 0),
        ("unmatched bracket", ["{open.bf}"], b"", None, 2),
        ("usage", [], b"", None, 2),
    ],
}


def build(program, workdir):
    exe = os.path.join(workdir, os.path.basename(program)[:-3])
    proc = subprocess.run(
        [sys.executable, TCOMP, "build", os.path.join(PROGRAMS, program),
         "-o", exe], capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(f"cannot build {program}:\n{proc.stderr}")
    return exe


def fill(args, paths):
    """Substitute {fixture.name}; str.format is out because JSON has braces."""
    out = []
    for arg in args:
        for name, path in paths.items():
            arg = arg.replace("{" + name + "}", path)
        out.append(arg)
    return out


def system_check(binary, workdir):
    """Compare our wc/grep/head/tail against the real ones on a real file."""
    failures = []
    sample = bytearray()
    words = ["alpha", "beta", "gamma", "delta", "epsilon"]
    for i in range(300):
        sample += " ".join(words[(i + k) % len(words)] for k in
                           range(1 + i % 4)).encode() + b"\n"
    sample += b"\n\ntrailing words here\n"
    path = os.path.join(workdir, "sample.txt")
    with open(path, "wb") as fh:
        fh.write(sample)

    for args in (["wc", path], ["grep", "-c", "a", path],
                 ["grep", "-n", "gamma", path], ["grep", "-v", "a", path],
                 ["head", "-n", "7", path], ["tail", "-n", "7", path]):
        ours = subprocess.run([binary, *args], capture_output=True)
        ref = subprocess.run([args[0], *args[1:]], capture_output=True)
        if ref.returncode > 1:          # system tool not available
            continue
        # wc pads its numbers; everything else is compared byte for byte
        same = (ours.stdout.split() == ref.stdout.split()
                if args[0] == "wc" else ours.stdout == ref.stdout)
        if not same or ours.returncode != ref.returncode:
            failures.append(
                f"tbox {' '.join(args[:-1])} differs from the system "
                f"{args[0]}\n  ours:   {ours.stdout[:80]!r}\n"
                f"  system: {ref.stdout[:80]!r}")
    return failures


def json_differential(binary, workdir, rounds=25):
    """tjson fmt must agree with Python's json module on random documents."""
    rng = random.Random(20261030)

    def value(depth):
        pick = rng.random()
        if depth > 3 or pick < 0.35:
            return rng.choice([1, -2, 0, 1234567890, "text", "", "a b",
                               True, False, None, 3.5, -0.25])
        if pick < 0.65:
            return [value(depth + 1) for _ in range(rng.randint(0, 3))]
        return {f"k{i}": value(depth + 1) for i in range(rng.randint(0, 3))}

    failures = []
    for n in range(rounds):
        doc = value(0)
        path = os.path.join(workdir, f"gen{n}.json")
        with open(path, "w") as fh:
            fh.write(json.dumps(doc))
        pretty = subprocess.run([binary, "fmt", path], capture_output=True)
        compact = subprocess.run([binary, "fmt", "--compact", path],
                                 capture_output=True)
        want_pretty = (json.dumps(doc, indent=2) + "\n").encode()
        want_compact = (json.dumps(doc, separators=(",", ":")) + "\n").encode()
        if pretty.stdout != want_pretty:
            failures.append(f"tjson fmt differs from json.dumps on {doc!r}\n"
                            f"  ours:   {pretty.stdout[:120]!r}\n"
                            f"  python: {want_pretty[:120]!r}")
        if compact.stdout != want_compact:
            failures.append(f"tjson fmt --compact differs on {doc!r}\n"
                            f"  ours:   {compact.stdout[:120]!r}\n"
                            f"  python: {want_compact[:120]!r}")
        if len(failures) > 3:
            break
    return failures


# Every program must also build with the compiler written in tlang, not just
# with stage 0 -- otherwise "self-hosted" only covers the test cases.
def selfhost_check(workdir, paths):
    failures = []
    stage1 = os.path.join(workdir, "tcomp_self")
    proc = subprocess.run([sys.executable, TCOMP, "build",
                           os.path.join(ROOT, "tcomp.tl"), "-o", stage1],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        return [f"cannot build the self-hosted compiler:\n{proc.stderr}"]

    for program in sorted(os.listdir(PROGRAMS)):
        if not program.endswith(".tl"):
            continue
        tool = program[:-3]
        asm = subprocess.run([stage1, os.path.join(PROGRAMS, program)],
                             capture_output=True, text=True)
        if asm.returncode != 0:
            failures.append(f"self-hosted compiler failed on {program}:\n"
                            f"{asm.stderr.strip()}")
            continue
        src = os.path.join(workdir, tool + "_self.s")
        obj = os.path.join(workdir, tool + "_self.o")
        exe = os.path.join(workdir, tool + "_self")
        with open(src, "w") as fh:
            fh.write(asm.stdout)
        subprocess.run(["as", "--64", "-mx86-used-note=no", "-o", obj, src], check=True)
        subprocess.run(["ld", *LDFLAGS, "-o", exe, obj], check=True)
        strip_sections(exe)

        # Same invocation through both compilers must produce the same output.
        name, args, stdin, _expected, _status = CASES[tool][0]
        ours = subprocess.run([exe, *fill(args, paths)], input=stdin,
                              capture_output=True)
        stage0 = os.path.join(workdir, tool)
        ref = subprocess.run([stage0, *fill(args, paths)], input=stdin,
                             capture_output=True)
        if ours.stdout != ref.stdout or ours.returncode != ref.returncode:
            failures.append(
                f"self-hosted {tool} disagrees with stage 0 on '{name}'\n"
                f"  self-hosted: {ours.stdout[:80]!r} (exit {ours.returncode})\n"
                f"  stage 0:     {ref.stdout[:80]!r} (exit {ref.returncode})")
    return failures


def main():
    workdir = tempfile.mkdtemp(prefix="tlang-programs-")
    failures = []
    paths = {}
    for name, data in FIXTURES.items():
        paths[name] = os.path.join(workdir, name)
        with open(paths[name], "wb") as fh:
            fh.write(data)

    try:
        for program in sorted(os.listdir(PROGRAMS)):
            if not program.endswith(".tl"):
                continue
            exe = build(program, workdir)
            print(f"  ok   {program} ({os.path.getsize(exe)} bytes)")

        total = 0
        for tool, cases in CASES.items():
            exe = os.path.join(workdir, tool)
            for name, args, stdin, expected, status in cases:
                proc = subprocess.run([exe, *fill(args, paths)], input=stdin,
                                      capture_output=True)
                before = len(failures)
                if expected is not None and proc.stdout != expected:
                    failures.append(f"{tool} {name}: expected {expected!r}, "
                                    f"got {proc.stdout!r}")
                if proc.returncode != status:
                    failures.append(f"{tool} {name}: exit {proc.returncode}, "
                                    f"expected {status}")
                total += 1
                print(f"  {'ok' if len(failures) == before else '..'}   "
                      f"{tool} {name}")

        failures.extend(system_check(os.path.join(workdir, "tbox"), workdir))
        print("  ok   tbox matches the system wc/grep/head/tail"
              if not failures else "  ..   system comparison")

        json_failures = json_differential(os.path.join(workdir, "tjson"),
                                          workdir)
        failures.extend(json_failures)
        print("  ok   tjson matches python json on 25 documents"
              if not json_failures else "  ..   json comparison")
        total += 50

        selfhost_failures = selfhost_check(workdir, paths)
        failures.extend(selfhost_failures)
        print("  ok   every program builds with the self-hosted compiler"
              if not selfhost_failures else "  ..   self-hosted build")
        total += 3
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    print()
    if failures:
        for failure in failures:
            print(failure)
            print()
        print(f"{len(failures)} failure(s)")
        return 1
    print(f"{total} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
