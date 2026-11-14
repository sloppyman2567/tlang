#!/usr/bin/env python3
"""Run Programs/tgameboy.tl on small generated Game Boy ROMs.

Each ROM is assembled here, so the expected 0xC000 memory dump comes from the
instruction sequence rather than from a ROM checked into the repository. The
cases cover ALU flags, loads, calls/stack, CB-prefixed ops, interrupts, and
MBC1 bank switching. Both the bootstrap and self-hosted compilers are used.
"""

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TCOMP = os.path.join(ROOT, "tcomp")
PROGRAM = os.path.join(ROOT, "Programs", "tgameboy.tl")
LDFLAGS = ["-s", "-z", "noseparate-code", "--build-id=none"]
sys.path.insert(0, ROOT)

from Bootstrap.elf import strip_sections  # noqa: E402


def rom(code, banks=2, mbc1=False, extra=None):
    """Build a ROM with a jump at 0x100 and code at 0x150.

    The cartridge header lives at 0x134-0x14F, so code that needs more than
    0x34 bytes has to start after it, as real ROMs do.
    """
    data = bytearray(0x4000 * banks)
    data[0x100:0x103] = bytes.fromhex("C35001")   # JP 0x0150
    data[0x150:0x150 + len(code)] = code
    for addr, chunk in (extra or {}).items():
        data[addr:addr + len(chunk)] = chunk
    data[0x134:0x13C] = b"TGAMEBOY"
    data[0x147] = 1 if mbc1 else 0
    data[0x148] = {2: 0, 4: 1, 8: 2}[banks]
    return bytes(data)


def store_a(addr):
    return bytes([0xEA, addr & 0xFF, (addr >> 8) & 0xFF])


def store_f(addr):
    # PUSH AF; POP BC; LD A,C; LD (addr),A; LD A,B restores the old A.
    return bytes.fromhex("F5C179") + store_a(addr) + bytes.fromhex("78")


def expect(values):
    data = bytearray(32)
    for addr, value in values.items():
        data[addr - 0xC000] = value
    return " ".join(f"{b:02x}" for b in data) + "\n"


def code_alu():
    code = bytes.fromhex("3E7FC601") + store_a(0xC000) + store_f(0xC001)
    code += bytes.fromhex("3E0FC601") + store_a(0xC002) + store_f(0xC003)
    code += bytes.fromhex("3E00D601") + store_a(0xC004) + store_f(0xC005)
    return code + bytes.fromhex("18FE")


def code_loads():
    code = bytes.fromhex("2110C0")                 # LD HL,0xC010
    code += bytes.fromhex("3EAB77")                 # LD A,0xAB; LD (HL),A
    code += bytes.fromhex("233ECD77")               # INC HL; LD A,0xCD; ...
    code += bytes.fromhex("2B460478")               # DEC HL; LD B,(HL); INC B; LD A,B
    code += store_a(0xC000)
    code += bytes.fromhex("7E") + store_a(0xC001)   # LD A,(HL)
    return code + bytes.fromhex("18FE")


def code_stack():
    code = bytes.fromhex("31FEFF013412C5D1")       # SP; BC; PUSH; POP DE
    code += bytes.fromhex("7A") + store_a(0xC000)
    code += bytes.fromhex("7B") + store_a(0xC001)
    code += bytes.fromhex("CD0002")                 # CALL 0x0200
    code += bytes.fromhex("3E77") + store_a(0xC002)
    code += bytes.fromhex("18FE")
    sub = bytes.fromhex("3E99") + store_a(0xC003) + bytes.fromhex("C9")
    return code, sub


def code_cb():
    code = bytes.fromhex("3E81CB07") + store_a(0xC000) + store_f(0xC001)
    code += bytes.fromhex("CB37") + store_a(0xC002) + store_f(0xC003)
    code += bytes.fromhex("CB67") + store_f(0xC004)   # BIT 4,A
    code += bytes.fromhex("CBA7") + store_a(0xC005)   # RES 4,A
    code += bytes.fromhex("CBC7") + store_a(0xC006)   # SET 0,A
    code += bytes.fromhex("CB3F") + store_a(0xC007) + store_f(0xC008)
    return code + bytes.fromhex("18FE")


def code_interrupt():
    handler = bytes.fromhex("3E5A") + store_a(0xC010) + bytes.fromhex("D9")
    code = bytes.fromhex("3E01") + store_a(0xFFFF)    # IE = 1
    code += bytes.fromhex("3E01") + store_a(0xFF0F)   # IF = 1
    code += bytes.fromhex("FB00")                     # EI; NOP
    code += bytes.fromhex("3E11") + store_a(0xC000)
    code += bytes.fromhex("18FE")
    return code, handler


def code_mbc1():
    code = bytes.fromhex("3E02") + store_a(0x2000)
    code += bytes.fromhex("FA0040") + store_a(0xC000)
    code += bytes.fromhex("3E01") + store_a(0x2000)
    code += bytes.fromhex("FA0040") + store_a(0xC001)
    return code + bytes.fromhex("18FE")


def code_joypad():
    # Select directions, read P1; select buttons, read P1.
    code = bytes.fromhex("3E20E000F000") + store_a(0xC000)
    code += bytes.fromhex("3E10E000F000") + store_a(0xC001)
    return code + bytes.fromhex("18FE")


CASES = [
    ("alu-flags", rom(code_alu()), 200,
     expect({0xC000: 0x80, 0xC001: 0x20,
             0xC002: 0x10, 0xC003: 0x20,
             0xC004: 0xFF, 0xC005: 0x70})),
    ("loads", rom(code_loads()), 200,
     expect({0xC000: 0xAC, 0xC001: 0xAB,
             0xC010: 0xAB, 0xC011: 0xCD})),
    ("stack-call", None, 300,
     expect({0xC000: 0x12, 0xC001: 0x34,
             0xC002: 0x77, 0xC003: 0x99})),
    ("cb-prefix", rom(code_cb()), 300,
     expect({0xC000: 0x03, 0xC001: 0x10,
             0xC002: 0x30, 0xC003: 0x00,
             0xC004: 0x20, 0xC005: 0x20,
             0xC006: 0x21, 0xC007: 0x10,
             0xC008: 0x10})),
    ("interrupt", None, 100,
     expect({0xC000: 0x11, 0xC010: 0x5A})),
]

# The two cases that need extra code are assembled after the helper is defined.
_stack_code, _stack_sub = code_stack()
CASES[2] = ("stack-call", rom(_stack_code, extra={0x200: _stack_sub}), 300,
            CASES[2][3])
_interrupt_code, _interrupt_handler = code_interrupt()
CASES[4] = ("interrupt", rom(_interrupt_code, extra={0x40: _interrupt_handler}),
            100, CASES[4][3])

_bank_data = bytearray(0x10000)
_bank_data[0x4000:0x8000] = b"\x11" * 0x4000
_bank_data[0x8000:0xC000] = b"\x22" * 0x4000
_bank_data[0x100:0x103] = bytes.fromhex("C35001")
_bank_data[0x150:0x150 + len(code_mbc1())] = code_mbc1()
_bank_data[0x134:0x13C] = b"TGAMEBOY"
_bank_data[0x147] = 1
_bank_data[0x148] = 1
CASES.append(("mbc1-banking", bytes(_bank_data), 200,
              expect({0xC000: 0x22, 0xC001: 0x11})))

# Held bits: Left+Up (directions) and A+B (buttons).
KEY_CASES = [("joypad", rom(code_joypad()), 0x36, 50,
              expect({0xC000: 0xE9, 0xC001: 0xDC}))]

DEMO = os.path.join(ROOT, "Examples", "tgameboy-demo.gb")
if os.path.exists(DEMO):
    with open(DEMO, "rb") as fh:
        _demo = fh.read()
    CASES.append(("demo-rom", _demo, 80,
                  expect({0xC000: 0x47, 0xC001: 0x42, 0xC002: 0x44,
                          0xC003: 0x4D, 0xC004: 0x47})))

SCREEN = os.path.join(ROOT, "Examples", "tgameboy-screen.gb")
FRAME_CASES = []
if os.path.exists(SCREEN):
    with open(SCREEN, "rb") as fh:
        _screen = fh.read()
    _stripe = ".o" * 80 + "\n"
    FRAME_CASES.append(("screen-frame", _screen, 70224, _stripe * 144))


def build_stage0(work):
    exe = os.path.join(work, "tgameboy-0")
    subprocess.run([sys.executable, TCOMP, "build", PROGRAM, "-o", exe],
                   check=True, capture_output=True)
    return exe


def build_stage1(work):
    compiler = os.path.join(work, "tcomp1")
    subprocess.run([sys.executable, TCOMP, "build",
                    os.path.join(ROOT, "tcomp.tl"), "-o", compiler],
                   check=True, capture_output=True)
    asm = subprocess.run([compiler, PROGRAM], check=True,
                         capture_output=True).stdout
    src = os.path.join(work, "tgameboy.s")
    obj = os.path.join(work, "tgameboy.o")
    exe = os.path.join(work, "tgameboy-1")
    with open(src, "wb") as fh:
        fh.write(asm)
    subprocess.run(["as", "--64", "-mx86-used-note=no", "-o", obj, src], check=True,
                   capture_output=True)
    subprocess.run(["ld", *LDFLAGS, "-o", exe, obj], check=True,
                   capture_output=True)
    strip_sections(exe)
    return exe


def main():
    work = tempfile.mkdtemp(prefix="tlang-gameboy-")
    failures = []
    try:
        binaries = [("stage0", build_stage0(work)),
                    ("stage1", build_stage1(work))]
        for index, (name, data, steps, expected) in enumerate(CASES):
            path = os.path.join(work, f"test{index}.gb")
            with open(path, "wb") as fh:
                fh.write(data)
            ok = True
            for which, exe in binaries:
                proc = subprocess.run([exe, path, str(steps)],
                                      capture_output=True, text=True)
                if proc.returncode != 0:
                    failures.append(f"{name} [{which}]: exit "
                                    f"{proc.returncode}\n{proc.stderr}")
                    ok = False
                elif proc.stdout != expected:
                    failures.append(f"{name} [{which}]: dump mismatch\n"
                                    f"  expected {expected!r}\n"
                                    f"  got      {proc.stdout!r}")
                    ok = False
            print(f"  {'ok  ' if ok else 'FAIL'} {name}")

        for index, (name, data, mask, steps, expected) in enumerate(KEY_CASES):
            path = os.path.join(work, f"keys{index}.gb")
            with open(path, "wb") as fh:
                fh.write(data)
            ok = True
            for which, exe in binaries:
                proc = subprocess.run([exe, path, "keys", str(mask), str(steps)],
                                      capture_output=True, text=True)
                if proc.returncode != 0:
                    failures.append(f"{name} [{which}]: exit "
                                    f"{proc.returncode}\n{proc.stderr}")
                    ok = False
                elif proc.stdout != expected:
                    failures.append(f"{name} [{which}]: pad mismatch\n"
                                    f"  expected {expected!r}\n"
                                    f"  got      {proc.stdout!r}")
                    ok = False
            print(f"  {'ok  ' if ok else 'FAIL'} {name}")

        for index, (name, data, cycles, expected) in enumerate(FRAME_CASES):
            path = os.path.join(work, f"frame{index}.gb")
            with open(path, "wb") as fh:
                fh.write(data)
            ok = True
            for which, exe in binaries:
                proc = subprocess.run([exe, path, "frame", str(cycles)],
                                      capture_output=True, text=True)
                if proc.returncode != 0:
                    failures.append(f"{name} [{which}]: exit "
                                    f"{proc.returncode}\n{proc.stderr}")
                    ok = False
                elif proc.stdout != expected:
                    failures.append(f"{name} [{which}]: frame mismatch\n"
                                    f"  expected {len(expected)} bytes\n"
                                    f"  got      {len(proc.stdout)} bytes")
                    ok = False
            print(f"  {'ok  ' if ok else 'FAIL'} {name}")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print()
    if failures:
        for failure in failures:
            print(failure)
            print()
        print(f"{len(failures)} failure(s)")
        return 1
    print(f"{len(CASES)} ROMs, {len(KEY_CASES)} key case, and "
          f"{len(FRAME_CASES)} frame match in both compilers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
