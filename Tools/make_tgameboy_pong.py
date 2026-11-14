#!/usr/bin/env python3
"""Build Examples/tgameboy-pong.gb, a small background-only Pong game.

The ROM is assembled with a tiny set of SM83 helpers rather than a full
assembler, so the game's constants and data stay in one readable file.  The
emulator's PPU only renders the background, so paddles and the ball are tiles
in the 0x9800 map; the game waits for VBlank and redraws the map there.
"""

import os

BASE = 0x150
TILE_BYTES = 13 * 16

# Game state in WRAM.
PLAYER_Y = 0xC000
AI_Y = 0xC001
BALL_X = 0xC002
BALL_Y = 0xC003
DX = 0xC004
DY = 0xC005
SCORE_P = 0xC006
SCORE_A = 0xC007
AI_TICK = 0xC008
OLD_PLAYER_Y = 0xC009
OLD_AI_Y = 0xC00A
OLD_BALL_X = 0xC00B
OLD_BALL_Y = 0xC00C
TICK = 0xC00D


class Asm:
    def __init__(self):
        self.code = bytearray()
        self.labels = {
            "PLAYER_Y": PLAYER_Y,
            "AI_Y": AI_Y,
            "BALL_X": BALL_X,
            "BALL_Y": BALL_Y,
            "DX": DX,
            "DY": DY,
            "SCORE_P": SCORE_P,
            "SCORE_A": SCORE_A,
            "AI_TICK": AI_TICK,
            "OLD_PLAYER_Y": OLD_PLAYER_Y,
            "OLD_AI_Y": OLD_AI_Y,
            "OLD_BALL_X": OLD_BALL_X,
            "OLD_BALL_Y": OLD_BALL_Y,
            "TICK": TICK,
        }
        self.fixups = []

    def label(self, name):
        self.labels[name] = BASE + len(self.code)

    def b(self, *values):
        self.code.extend(values)

    def abs16(self, op, value):
        self.b(op)
        self.fixups.append((len(self.code), value, "abs"))
        self.b(0, 0)

    def jr(self, op, label):
        self.b(op)
        self.fixups.append((len(self.code), label, "rel"))
        self.b(0)

    def call(self, label):
        self.abs16(0xCD, label)

    def jp(self, label):
        self.abs16(0xC3, label)

    def ld_hl(self, value):
        self.abs16(0x21, value)

    def ld_de(self, value):
        self.abs16(0x11, value)

    def ld_bc(self, value):
        self.abs16(0x01, value)

    def ld_sp(self, value):
        self.abs16(0x31, value)

    def ld_a_imm(self, value):
        self.b(0x3E, value)

    def ld_b_imm(self, value):
        self.b(0x06, value)

    def ld_c_imm(self, value):
        self.b(0x0E, value)

    def ld_d_imm(self, value):
        self.b(0x16, value)

    def ld_a_mem(self, value):
        self.abs16(0xFA, value)

    def ld_mem_a(self, value):
        self.abs16(0xEA, value)

    def ldh_a(self, reg):
        self.b(0xF0, reg)

    def ldh_mem(self, reg):
        self.b(0xE0, reg)

    def cp_imm(self, value):
        self.b(0xFE, value)

    def add_imm(self, value):
        self.b(0xC6, value)

    def and_imm(self, value):
        self.b(0xE6, value)

    def finish(self):
        for offset, name, kind in self.fixups:
            value = self.labels[name] if isinstance(name, str) else name
            if kind == "abs":
                self.code[offset] = value & 0xFF
                self.code[offset + 1] = (value >> 8) & 0xFF
            else:
                disp = value - (BASE + offset + 1)
                if not -128 <= disp <= 127:
                    raise ValueError(f"branch to {name} is out of range")
                self.code[offset] = disp & 0xFF


def game_code():
    a = Asm()

    a.label("start")
    a.b(0xF3)                         # DI
    a.ld_sp(0xFFFE)
    a.b(0xAF)                         # XOR A
    a.ld_mem_a(0xFF40)                # LCD off
    a.ld_hl(0x8000)
    a.ld_de("TILES")
    a.ld_bc(TILE_BYTES)

    a.label("copy_tiles")
    a.b(0x1A)                         # LD A,(DE)
    a.b(0x22)                         # LD (HL+),A
    a.b(0x13, 0x0B)                   # INC DE; DEC BC
    a.b(0x78, 0xB1)                   # LD A,B; OR C
    a.jr(0x20, "copy_tiles")          # JR NZ

    a.ld_hl(0x9800)
    a.ld_bc(0x0400)
    a.ld_d_imm(0)

    a.label("clear_map")
    a.b(0x7A)                         # LD A,D
    a.b(0x22)                         # LD (HL+),A
    a.b(0x0B)                         # DEC BC
    a.b(0x78, 0xB1)                   # LD A,B; OR C
    a.jr(0x20, "clear_map")

    a.ld_a_imm(0xE4)
    a.ld_mem_a(0xFF47)                # BGP
    a.b(0xAF)
    a.ld_mem_a(0xFF42)                # SCY
    a.ld_mem_a(0xFF43)                # SCX
    a.ld_a_imm(0x91)
    a.ld_mem_a(0xFF40)                # LCD on, BG on, 0x8000 tiles

    a.ld_a_imm(7)
    a.ld_mem_a(PLAYER_Y)
    a.ld_mem_a(AI_Y)
    a.ld_a_imm(10)
    a.ld_mem_a(BALL_X)
    a.ld_a_imm(9)
    a.ld_mem_a(BALL_Y)
    a.ld_a_imm(1)
    a.ld_mem_a(DX)
    a.ld_mem_a(DY)
    a.b(0xAF)                         # XOR A
    a.ld_mem_a(SCORE_P)
    a.ld_mem_a(SCORE_A)
    a.ld_mem_a(AI_TICK)
    a.ld_mem_a(TICK)

    a.ld_a_mem(PLAYER_Y)
    a.ld_mem_a(OLD_PLAYER_Y)
    a.ld_a_mem(AI_Y)
    a.ld_mem_a(OLD_AI_Y)
    a.ld_a_mem(BALL_X)
    a.ld_mem_a(OLD_BALL_X)
    a.ld_a_mem(BALL_Y)
    a.ld_mem_a(OLD_BALL_Y)

    a.call("draw_objects")
    a.jp("loop")

    a.label("loop")
    a.call("wait_vblank")
    a.ld_a_mem(TICK)
    a.b(0x3C)                         # INC A
    a.ld_mem_a(TICK)

    # Pong moves in whole 8-pixel tiles, so pace the simulation instead of
    # running it at 60 tiles per second.  Input still gets checked every other
    # frame; the ball crosses the board in about two seconds.
    a.and_imm(1)
    a.jr(0x20, "skip_input")
    a.call("input")
    a.label("skip_input")

    a.ld_a_mem(TICK)
    a.and_imm(3)
    a.jr(0x20, "skip_ai")
    a.call("update_ai")
    a.label("skip_ai")

    a.ld_a_mem(TICK)
    a.and_imm(7)
    a.jr(0x20, "skip_ball")
    a.call("update_ball")
    a.label("skip_ball")

    a.call("draw_objects")
    a.jp("loop")

    a.label("wait_vblank")
    a.ldh_a(0x44)
    a.cp_imm(144)
    a.jr(0x20, "wait_vblank")
    a.label("wait_end")
    a.ldh_a(0x44)
    a.cp_imm(144)
    a.jr(0x28, "wait_end")
    a.b(0xC9)                         # RET

    # Read directions from P1.  The d-pad is active low in bits 0-3.
    a.label("input")
    a.ld_a_imm(0x20)
    a.ldh_mem(0x00)
    a.ldh_a(0x00)
    a.b(0x47)                         # LD B,A
    a.and_imm(0x04)                   # Up
    a.jr(0x20, "input_not_up")
    a.ld_a_mem(PLAYER_Y)
    a.cp_imm(2)
    a.jr(0x38, "input_not_up")
    a.b(0x3D)                         # DEC A
    a.ld_mem_a(PLAYER_Y)
    a.label("input_not_up")
    a.b(0x78)                         # LD A,B
    a.and_imm(0x08)                   # Down
    a.jr(0x20, "input_done")
    a.ld_a_mem(PLAYER_Y)
    a.cp_imm(13)
    a.jr(0x30, "input_done")
    a.b(0x3C)                         # INC A
    a.ld_mem_a(PLAYER_Y)
    a.label("input_done")
    a.b(0xC9)

    # AI moves every other frame and only chases once the ball is on its half.
    a.label("update_ai")
    a.ld_a_mem(AI_TICK)
    a.b(0x3C)                         # INC A
    a.ld_mem_a(AI_TICK)
    a.and_imm(1)
    a.jr(0x20, "ai_done")
    a.ld_a_mem(BALL_X)
    a.cp_imm(10)
    a.jr(0x38, "ai_center")
    a.ld_a_mem(BALL_Y)
    a.jr(0x18, "ai_target")
    a.label("ai_center")
    a.ld_a_imm(7)
    a.label("ai_target")
    a.b(0x47)                         # LD B,A = target
    a.ld_a_mem(AI_Y)
    a.b(0x4F)                         # LD C,A = ai
    a.b(0x79, 0xC6, 2)                # LD A,C; ADD A,2
    a.b(0xB8)                         # CP B
    a.jr(0x38, "ai_down")
    a.b(0x78, 0xB9)                   # LD A,B; CP C
    a.jr(0x38, "ai_up")
    a.label("ai_done")
    a.b(0xC9)
    a.label("ai_down")
    a.b(0x79, 0xFE, 13)               # LD A,C; CP 13
    a.jr(0x30, "ai_done")
    a.b(0x3C)
    a.ld_mem_a(AI_Y)
    a.b(0xC9)
    a.label("ai_up")
    a.b(0x79, 0xFE, 2)                # LD A,C; CP 2
    a.jr(0x38, "ai_done")
    a.b(0x3D)
    a.ld_mem_a(AI_Y)
    a.b(0xC9)

    a.label("update_ball")
    a.ld_a_mem(BALL_X)
    a.b(0x47)                         # LD B,A
    a.ld_a_mem(DX)
    a.b(0x80)                         # ADD A,B
    a.ld_mem_a(BALL_X)
    a.ld_a_mem(BALL_Y)
    a.b(0x47)
    a.ld_a_mem(DY)
    a.b(0x80)
    a.ld_mem_a(BALL_Y)

    a.ld_a_mem(BALL_Y)
    a.cp_imm(1)
    a.jr(0x30, "ball_not_top")
    a.ld_a_imm(1)
    a.ld_mem_a(BALL_Y)
    a.call("flip_dy")
    a.label("ball_not_top")
    a.ld_a_mem(BALL_Y)
    a.cp_imm(17)
    a.jr(0x38, "ball_not_bottom")
    a.ld_a_imm(16)
    a.ld_mem_a(BALL_Y)
    a.call("flip_dy")
    a.label("ball_not_bottom")

    a.ld_a_mem(BALL_X)
    a.cp_imm(3)
    a.jr(0x30, "ball_check_right")
    a.ld_a_mem(DX)
    a.b(0xCB, 0x7F)                   # BIT 7,A
    a.jr(0x28, "ball_check_right")    # positive x velocity
    a.call("player_hit")
    a.jr(0x28, "ball_left_hit")
    a.call("score_ai")
    a.b(0xC9)
    a.label("ball_left_hit")
    a.ld_a_imm(2)
    a.ld_mem_a(BALL_X)
    a.ld_a_imm(1)
    a.ld_mem_a(DX)
    a.b(0xC9)

    a.label("ball_check_right")
    a.ld_a_mem(BALL_X)
    a.cp_imm(17)
    a.jr(0x38, "ball_done")
    a.ld_a_mem(DX)
    a.b(0xCB, 0x7F)                   # BIT 7,A
    a.jr(0x20, "ball_done")           # negative x velocity
    a.call("ai_hit")
    a.jr(0x28, "ball_right_hit")
    a.call("score_player")
    a.b(0xC9)
    a.label("ball_right_hit")
    a.ld_a_imm(17)
    a.ld_mem_a(BALL_X)
    a.ld_a_imm(0xFF)
    a.ld_mem_a(DX)
    a.label("ball_done")
    a.b(0xC9)

    a.label("player_hit")
    a.ld_a_mem(BALL_Y)
    a.b(0x47)                         # LD B,A
    a.ld_a_mem(PLAYER_Y)
    a.b(0x4F)                         # LD C,A
    a.b(0x78, 0xB9)                   # LD A,B; CP C
    a.jr(0x38, "player_hit_miss")
    a.b(0x79, 0xC6, 3)                # LD A,C; ADD A,3
    a.b(0xB8)                         # CP B
    a.jr(0x38, "player_hit_miss")
    a.b(0xAF)                         # XOR A -> Z set
    a.b(0xC9)
    a.label("player_hit_miss")
    a.ld_a_imm(1)
    a.b(0xB7)                         # OR A -> Z clear
    a.b(0xC9)

    a.label("ai_hit")
    a.ld_a_mem(BALL_Y)
    a.b(0x47)
    a.ld_a_mem(AI_Y)
    a.b(0x4F)
    a.b(0x78, 0xB9)
    a.jr(0x38, "ai_hit_miss")
    a.b(0x79, 0xC6, 3)
    a.b(0xB8)
    a.jr(0x38, "ai_hit_miss")
    a.b(0xAF)
    a.b(0xC9)
    a.label("ai_hit_miss")
    a.ld_a_imm(1)
    a.b(0xB7)
    a.b(0xC9)

    a.label("flip_dy")
    a.ld_a_mem(DY)
    a.b(0x2F, 0x3C)                   # CPL; INC A
    a.ld_mem_a(DY)
    a.b(0xC9)

    a.label("score_player")
    a.ld_a_mem(SCORE_P)
    a.b(0x3C)
    a.cp_imm(10)
    a.jr(0x38, "score_player_store")
    a.b(0xAF)
    a.label("score_player_store")
    a.ld_mem_a(SCORE_P)
    a.call("draw_scores")
    a.ld_a_imm(10)
    a.ld_mem_a(BALL_X)
    a.ld_a_imm(9)
    a.ld_mem_a(BALL_Y)
    a.ld_a_imm(1)
    a.ld_mem_a(DX)
    a.ld_mem_a(DY)
    a.b(0xC9)

    a.label("score_ai")
    a.ld_a_mem(SCORE_A)
    a.b(0x3C)
    a.cp_imm(10)
    a.jr(0x38, "score_ai_store")
    a.b(0xAF)
    a.label("score_ai_store")
    a.ld_mem_a(SCORE_A)
    a.call("draw_scores")
    a.ld_a_imm(10)
    a.ld_mem_a(BALL_X)
    a.ld_a_imm(9)
    a.ld_mem_a(BALL_Y)
    a.ld_a_imm(0xFF)
    a.ld_mem_a(DX)
    a.ld_a_imm(1)
    a.ld_mem_a(DY)
    a.b(0xC9)

    # Clear old object cells, then redraw scores and the three objects.
    a.label("draw_objects")
    a.ld_b_imm(1)
    a.ld_a_mem(OLD_PLAYER_Y)
    a.b(0x4F)                         # LD C,A
    a.ld_d_imm(0)
    a.call("draw_paddle")
    a.ld_b_imm(18)
    a.ld_a_mem(OLD_AI_Y)
    a.b(0x4F)
    a.ld_d_imm(0)
    a.call("draw_paddle")
    a.ld_a_mem(OLD_BALL_X)
    a.b(0x47)
    a.ld_a_mem(OLD_BALL_Y)
    a.b(0x4F)
    a.ld_d_imm(0)
    a.call("draw_cell")

    a.call("draw_scores")

    a.ld_b_imm(1)
    a.ld_a_mem(PLAYER_Y)
    a.b(0x4F)
    a.ld_d_imm(1)
    a.call("draw_paddle")
    a.ld_b_imm(18)
    a.ld_a_mem(AI_Y)
    a.b(0x4F)
    a.ld_d_imm(1)
    a.call("draw_paddle")
    a.ld_a_mem(BALL_X)
    a.b(0x47)
    a.ld_a_mem(BALL_Y)
    a.b(0x4F)
    a.ld_d_imm(2)
    a.call("draw_cell")

    a.ld_a_mem(PLAYER_Y)
    a.ld_mem_a(OLD_PLAYER_Y)
    a.ld_a_mem(AI_Y)
    a.ld_mem_a(OLD_AI_Y)
    a.ld_a_mem(BALL_X)
    a.ld_mem_a(OLD_BALL_X)
    a.ld_a_mem(BALL_Y)
    a.ld_mem_a(OLD_BALL_Y)
    a.b(0xC9)

    a.label("draw_scores")
    a.ld_b_imm(4)
    a.ld_c_imm(0)
    a.ld_a_mem(SCORE_P)
    a.add_imm(3)
    a.b(0x57)                         # LD D,A
    a.call("draw_cell")
    a.ld_b_imm(15)
    a.ld_c_imm(0)
    a.ld_a_mem(SCORE_A)
    a.add_imm(3)
    a.b(0x57)
    a.call("draw_cell")
    a.b(0xC9)

    a.label("draw_paddle")
    # C is the top row and must stay intact; E is the four-row counter.
    a.b(0x1E, 4)                      # LD E,4
    a.label("draw_paddle_loop")
    a.call("draw_cell")
    a.b(0x0C)                         # INC C (next row)
    a.b(0x1D)                         # DEC E
    a.jr(0x20, "draw_paddle_loop")
    a.b(0xC9)

    # Draw an 8x8 tile at map column B, row C.  D is the tile number.
    a.label("draw_cell")
    a.b(0x79)                         # LD A,C
    a.b(0x6F, 0x26, 0)                # LD L,A; LD H,0
    a.b(0x29, 0x29, 0x29, 0x29, 0x29) # ADD HL,HL x5 = *32
    a.b(0x78, 0x85)                   # LD A,B; ADD A,L
    a.b(0x6F)                         # LD L,A
    a.b(0x7C, 0xCE, 0)                # LD A,H; ADC A,0
    a.b(0xC6, 0x98)                   # ADD A,0x98
    a.b(0x67)                         # LD H,A
    a.b(0x7A, 0x77)                   # LD A,D; LD (HL),A
    a.b(0xC9)

    a.label("TILES")
    a.finish()
    return bytes(a.code)


def tiles():
    data = bytearray()

    # 0: blank
    data += bytes(16)

    # 1: paddle (color 2)
    for _ in range(8):
        data += bytes([0x00, 0xFF])

    # 2: ball (color 3)
    ball = [0x18, 0x3C, 0x7E, 0xFF, 0xFF, 0x7E, 0x3C, 0x18]
    for row in ball:
        data += bytes([row, row])

    digits = [
        [0x3C, 0x66, 0x6E, 0x76, 0x66, 0x66, 0x3C, 0x00],
        [0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00],
        [0x3C, 0x66, 0x06, 0x0C, 0x30, 0x60, 0x7E, 0x00],
        [0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00],
        [0x06, 0x0E, 0x1E, 0x66, 0x7F, 0x06, 0x06, 0x00],
        [0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00],
        [0x3C, 0x66, 0x60, 0x7C, 0x66, 0x66, 0x3C, 0x00],
        [0x7E, 0x66, 0x0C, 0x18, 0x18, 0x18, 0x18, 0x00],
        [0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00],
        [0x3C, 0x66, 0x66, 0x3E, 0x06, 0x66, 0x3C, 0x00],
    ]
    for digit in digits:                  # tiles 3-12
        for row in digit:
            data += bytes([0x00, row])
    assert len(data) == TILE_BYTES
    return bytes(data)


def build():
    code = game_code()
    rom = bytearray(0x8000)
    rom[0x100:0x103] = bytes.fromhex("C35001")  # JP 0x0150
    rom[0x134:0x13C] = b"PONG-GB!"              # exactly 8 bytes
    rom[0x147] = 0                              # ROM only
    rom[0x148] = 0                              # 32 KB
    rom[0x149] = 0                              # no cartridge RAM
    rom[0x150:0x150 + len(code)] = code
    tile_at = 0x150 + len(code)
    rom[tile_at:tile_at + TILE_BYTES] = tiles()
    assert tile_at + TILE_BYTES < 0x8000
    return bytes(rom)


if __name__ == "__main__":
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "Examples", "tgameboy-pong.gb")
    data = build()
    with open(out, "wb") as fh:
        fh.write(data)
    print(f"wrote {out}: {len(data)} bytes, {len(game_code())} bytes of code")
