#!/usr/bin/env python3
"""Run Programs/tchip8.tl against a Python CHIP-8 reference.

The ROMs are assembled here from opcodes, so the expected frames are produced
by an independent interpreter rather than copied from the tlang output. Every
case is run through both the bootstrap compiler and a freshly built
self-hosted compiler.
"""

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TCOMP = os.path.join(ROOT, "tcomp")
PROGRAM = os.path.join(ROOT, "Programs", "tchip8.tl")
LDFLAGS = ["-s", "-z", "noseparate-code", "--build-id=none"]
sys.path.insert(0, ROOT)

from Bootstrap.elf import strip_sections  # noqa: E402

FONT = bytes([
    0xF0, 0x90, 0x90, 0x90, 0xF0, 0x20, 0x60, 0x20, 0x20, 0x70,
    0xF0, 0x10, 0xF0, 0x80, 0xF0, 0xF0, 0x10, 0xF0, 0x10, 0xF0,
    0x90, 0x90, 0xF0, 0x10, 0x10, 0xF0, 0x80, 0xF0, 0x10, 0xF0,
    0xF0, 0x80, 0xF0, 0x90, 0xF0, 0xF0, 0x10, 0x20, 0x40, 0x40,
    0xF0, 0x90, 0xF0, 0x90, 0xF0, 0xF0, 0x90, 0xF0, 0x10, 0xF0,
    0xF0, 0x90, 0xF0, 0x90, 0x90, 0xE0, 0x90, 0xE0, 0x90, 0xE0,
    0xF0, 0x80, 0x80, 0x80, 0xF0, 0xE0, 0x90, 0x90, 0x90, 0xE0,
    0xF0, 0x80, 0xF0, 0x80, 0xF0, 0xF0, 0x80, 0xF0, 0x80, 0x80,
])


class Chip8:
    def __init__(self, rom, keys=0):
        self.mem = bytearray(4096)
        self.mem[0x50:0x50 + 80] = FONT
        self.mem[0x200:0x200 + len(rom)] = rom
        self.V = [0] * 16
        self.stack = []
        self.pc = 0x200
        self.I = 0
        self.dt = 0
        self.st = 0
        self.disp = [[0] * 64 for _ in range(32)]
        self.keys = [(keys >> i) & 1 for i in range(16)]
        self.seed = 0x1357
        self.ticks = 0
        self.halted = False

    def step(self):
        if self.halted:
            return
        op = (self.mem[self.pc] << 8) | self.mem[self.pc + 1]
        self.pc = (self.pc + 2) & 0xFFF
        nnn, nn, n = op & 0xFFF, op & 0xFF, op & 0xF
        x, y = (op >> 8) & 0xF, (op >> 4) & 0xF
        high = op & 0xF000
        if high == 0x0000:
            if op == 0x00E0:
                self.disp = [[0] * 64 for _ in range(32)]
            elif op == 0x00EE:
                self.pc = self.stack.pop()
        elif high == 0x1000:
            self.pc = nnn
        elif high == 0x2000:
            self.stack.append(self.pc)
            self.pc = nnn
        elif high == 0x3000:
            if self.V[x] == nn:
                self.pc = (self.pc + 2) & 0xFFF
        elif high == 0x4000:
            if self.V[x] != nn:
                self.pc = (self.pc + 2) & 0xFFF
        elif high == 0x5000:
            if self.V[x] == self.V[y]:
                self.pc = (self.pc + 2) & 0xFFF
        elif high == 0x6000:
            self.V[x] = nn
        elif high == 0x7000:
            self.V[x] = (self.V[x] + nn) & 0xFF
        elif high == 0x8000:
            if n == 0:
                self.V[x] = self.V[y]
            elif n == 1:
                self.V[x] |= self.V[y]
            elif n == 2:
                self.V[x] &= self.V[y]
            elif n == 3:
                self.V[x] ^= self.V[y]
            elif n == 4:
                total = self.V[x] + self.V[y]
                self.V[0xF] = 1 if total > 255 else 0
                self.V[x] = total & 0xFF
            elif n == 5:
                self.V[0xF] = 1 if self.V[x] >= self.V[y] else 0
                self.V[x] = (self.V[x] - self.V[y]) & 0xFF
            elif n == 6:
                self.V[0xF] = self.V[x] & 1
                self.V[x] >>= 1
            elif n == 7:
                self.V[0xF] = 1 if self.V[y] >= self.V[x] else 0
                self.V[x] = (self.V[y] - self.V[x]) & 0xFF
            elif n == 0xE:
                self.V[0xF] = (self.V[x] >> 7) & 1
                self.V[x] = (self.V[x] << 1) & 0xFF
        elif high == 0x9000:
            if self.V[x] != self.V[y]:
                self.pc = (self.pc + 2) & 0xFFF
        elif high == 0xA000:
            self.I = nnn
        elif high == 0xB000:
            self.pc = nnn + self.V[0]
        elif high == 0xC000:
            self.seed = (self.seed * 1103515245 + 12345) & 0x7FFFFFFF
            self.V[x] = ((self.seed >> 16) & 0xFF) & nn
        elif high == 0xD000:
            self.draw(self.V[x], self.V[y], n)
        elif high == 0xE000:
            if nn == 0x9E:
                if self.keys[x]:
                    self.pc = (self.pc + 2) & 0xFFF
            elif nn == 0xA1:
                if not self.keys[x]:
                    self.pc = (self.pc + 2) & 0xFFF
        elif high == 0xF000:
            if nn == 0x07:
                self.V[x] = self.dt
            elif nn == 0x0A:
                held = [i for i in range(16) if self.keys[i]]
                if held:
                    self.V[x] = held[0]
                else:
                    self.halted = True
            elif nn == 0x15:
                self.dt = self.V[x]
            elif nn == 0x18:
                self.st = self.V[x]
            elif nn == 0x1E:
                self.I += self.V[x]
            elif nn == 0x29:
                self.I = 0x50 + (self.V[x] & 0xF) * 5
            elif nn == 0x33:
                self.mem[self.I] = self.V[x] // 100
                self.mem[self.I + 1] = (self.V[x] // 10) % 10
                self.mem[self.I + 2] = self.V[x] % 10
            elif nn == 0x55:
                for i in range(x + 1):
                    self.mem[self.I + i] = self.V[i]
            elif nn == 0x65:
                for i in range(x + 1):
                    self.V[i] = self.mem[self.I + i]

    def draw(self, x, y, h):
        h = h or 16
        self.V[0xF] = 0
        for row in range(h):
            sprite = self.mem[self.I + row]
            for bit in range(8):
                if sprite & (0x80 >> bit):
                    px, py = (x + bit) & 63, (y + row) & 31
                    if self.disp[py][px]:
                        self.V[0xF] = 1
                    self.disp[py][px] ^= 1

    def run(self, cycles):
        for _ in range(cycles):
            if self.halted:
                break
            self.step()
            self.ticks += 1
            if self.ticks >= 10:
                self.ticks = 0
                self.dt = max(0, self.dt - 1)
                self.st = max(0, self.st - 1)

    def render(self):
        return "".join(
            "".join("#" if self.disp[y][x] else "." for x in range(64)) + "\n"
            for y in range(32)
        )


def assemble(ops, data=b"", at=0x300):
    code = bytearray()
    for op in ops:
        code += op.to_bytes(2, "big")
    if data:
        offset = at - 0x200
        if len(code) > offset:
            raise ValueError("code overlaps data")
        code += bytes(offset - len(code)) + data
    return bytes(code)


CASES = []


def case(name, ops, data=b"", cycles=200, keys=0, check=None, frame=0):
    rom = assemble(ops, data)
    ref = Chip8(rom, keys)
    ref.run(cycles)
    if check is not None:
        check(ref)
    CASES.append((name, rom, cycles, keys, frame, ref.render()))


def frame_case(name, ops, data=b"", cycles=30, keys=0, frame=10):
    """Run in chunks and join the clear-plus-frame the tool should print."""
    rom = assemble(ops, data)
    ref = Chip8(rom, keys)
    expected = ""
    done = 0
    while done < cycles:
        chunk = min(frame, cycles - done)
        ref.run(chunk)
        expected += "\x1b[2J\x1b[H" + ref.render()
        done += chunk
    CASES.append((name, rom, cycles, keys, frame, expected))


def blank(ref):
    assert ref.V[0xF] == 1, "expected a collision"
    assert all(px == 0 for row in ref.disp for px in row), "frame should be blank"


# A 3x3 outlined block at (10, 5), then a self-jump.
case("draw", [0x00E0, 0xA300, 0x600A, 0x6105, 0xD013, 0x120A],
     bytes([0xE0, 0xA0, 0xE0]))

# 123 -> BCD, then digits 1,2,3 drawn from the font at x = 5, 16, 27.
case("bcd-font", [
    0x607B, 0xA300, 0xF033,
    0x6301, 0xF329, 0x6205, 0x6105, 0xD235,
    0x6302, 0xF329, 0x6210, 0xD235,
    0x6303, 0xF329, 0x621B, 0xD235,
    0x1220,
], bytes([1, 2, 3]), cycles=300)

# Drawing the same sprite twice XORs it away and sets VF.
case("collision", [0x00E0, 0xA300, 0x6000, 0x6100, 0xD011, 0xD011, 0x120C],
     bytes([0x80]), check=blank)

# EX9E skips the draw when key 0 is held.
case("key-not-held", [0x00E0, 0xA300, 0x6000, 0x6100, 0xE09E, 0xD011, 0x120C],
     bytes([0x80]))
case("key-held", [0x00E0, 0xA300, 0x6000, 0x6100, 0xE09E, 0xD011, 0x120C],
     bytes([0x80]), keys=1)

# Frame mode: redraw the same 3x3 block three times, clearing before each.
frame_case("frames", [0x00E0, 0xA300, 0x600A, 0x6105, 0xD013, 0x120A],
           bytes([0xE0, 0xA0, 0xE0]))

# The shipped demo ROM must load and run, not just generated test ROMs.
DEMO = os.path.join(ROOT, "Examples", "tchip8-demo.ch8")
if os.path.exists(DEMO):
    with open(DEMO, "rb") as fh:
        _demo = fh.read()
    _ref = Chip8(_demo)
    _ref.run(30)
    CASES.append(("demo-rom", _demo, 30, 0, 0, _ref.render()))


def build_stage0(work):
    exe = os.path.join(work, "tchip8-0")
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
    src = os.path.join(work, "tchip8.s")
    obj = os.path.join(work, "tchip8.o")
    exe = os.path.join(work, "tchip8-1")
    with open(src, "wb") as fh:
        fh.write(asm)
    subprocess.run(["as", "--64", "-mx86-used-note=no", "-o", obj, src], check=True,
                   capture_output=True)
    subprocess.run(["ld", *LDFLAGS, "-o", exe, obj], check=True,
                   capture_output=True)
    strip_sections(exe)
    return exe


def main():
    work = tempfile.mkdtemp(prefix="tlang-chip8-")
    failures = []
    try:
        binaries = [("stage0", build_stage0(work)),
                    ("stage1", build_stage1(work))]
        for index, (name, rom, cycles, keys, frame, expected) in enumerate(CASES):
            path = os.path.join(work, f"rom{index}.ch8")
            with open(path, "wb") as fh:
                fh.write(rom)
            ok = True
            for which, exe in binaries:
                result = subprocess.run(
                    [exe, path, str(cycles), str(keys), str(frame)],
                    capture_output=True, text=True)
                if result.returncode != 0:
                    failures.append(f"{name} [{which}]: exit "
                                    f"{result.returncode}\n{result.stderr}")
                    ok = False
                elif result.stdout != expected:
                    failures.append(f"{name} [{which}]: frame mismatch\n"
                                    f"  expected {len(expected)} bytes, "
                                    f"got {len(result.stdout)}")
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
    print(f"{len(CASES)} ROMs match the reference in both compilers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
