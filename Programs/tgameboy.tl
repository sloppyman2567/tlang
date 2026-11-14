# tgameboy -- a DMG (original Game Boy) emulator, starting with the CPU.
#
#   tgameboy ROM [steps]
#
# The ROM is loaded at 0x0000 and execution starts at 0x0100 with the
# post-boot register state, so no Nintendo boot ROM is needed. This first
# slice implements the SM83 CPU, the DMG memory map, and MBC1 banking. It
# prints the 32 bytes at 0xC000 after running, which makes CPU tests easy.
#
# Not implemented yet: PPU timing/rendering, timer interrupts, audio, CGB.
# HALT stops the core until an interrupt is pending.

let ROM = alloc(0x200000)
let VRAM = alloc(0x2000)
let CRAM = alloc(0x2000)
let WRAM = alloc(0x2000)
let OAM = alloc(0xA0)
let IO = alloc(0x80)
let HRAM = alloc(0x7F)
let FRAME = alloc(160 * 144)
let TEXTROW = newbuf(161)
let PPU_DOT = 0
let QUIT = 0

let XBUF = newbuf(32768)
let XREPLY = newbuf(32768)
let XEV = newbuf(32)
let XAUTH = newbuf(64)
let XAUTHLEN = 0
let XFD = -1
let XROOT = 0
let XVISUAL = 0
let XDEPTH = 24
let XWIN = 0
let XGCS = [0, 0, 0, 0]
let COLORS = [0x0F380F, 0x306230, 0x8BAC0F, 0x9BBC0F]
let XWM_NAME = 0
let XWM_CLASS = 0
let XWM_PROTOCOLS = 0
let XWM_DELETE = 0

let ROMSIZE = 0
let MBC1 = 0
let RAMEN = 0
let BANK1 = 1
let BANK2 = 0
let MODE = 0
let IE = 0
let IF = 0
let IME = 0
let HALTED = 0
let DIV = 0
let LY = 0
let PAD = 0

let A = 0
let F = 0
let B = 0
let C = 0
let D = 0
let E = 0
let H = 0
let L = 0
let SP = 0
let PC = 0

# Flag bits: Z N H C.
let HEX = "0123456789abcdef"

fn hl() -> int {
  return (H << 8) | L
}

fn set_hl(v: int) {
  H = (v >> 8) & 0xFF
  L = v & 0xFF
}

fn rr_get(i: int) -> int {
  if i == 0 { return (B << 8) | C }
  if i == 1 { return (D << 8) | E }
  if i == 2 { return hl() }
  return SP
}

fn rr_set(i: int, v: int) {
  v = v & 0xFFFF
  if i == 0 {
    B = (v >> 8) & 0xFF
    C = v & 0xFF
  } else if i == 1 {
    D = (v >> 8) & 0xFF
    E = v & 0xFF
  } else if i == 2 {
    set_hl(v)
  } else {
    SP = v
  }
}

fn r_get(i: int) -> int {
  if i == 0 { return B }
  if i == 1 { return C }
  if i == 2 { return D }
  if i == 3 { return E }
  if i == 4 { return H }
  if i == 5 { return L }
  if i == 6 { return bus_read(hl()) }
  return A
}

fn r_set(i: int, v: int) {
  v = v & 0xFF
  if i == 0 { B = v }
  else if i == 1 { C = v }
  else if i == 2 { D = v }
  else if i == 3 { E = v }
  else if i == 4 { H = v }
  else if i == 5 { L = v }
  else if i == 6 { bus_write(hl(), v) }
  else { A = v }
}

fn cond(i: int) -> int {
  if i == 0 { if (F & 0x80) == 0 { return 1 } }
  else if i == 1 { if (F & 0x80) != 0 { return 1 } }
  else if i == 2 { if (F & 0x10) == 0 { return 1 } }
  else { if (F & 0x10) != 0 { return 1 } }
  return 0
}

fn fetch8() -> int {
  let v = bus_read(PC)
  PC = (PC + 1) & 0xFFFF
  return v
}

fn fetch16() -> int {
  let lo = fetch8()
  let hi = fetch8()
  return lo | (hi << 8)
}

fn fetch_signed() -> int {
  let v = fetch8()
  if v >= 128 { return v - 256 }
  return v
}

fn push(v: int) {
  SP = (SP - 1) & 0xFFFF
  bus_write(SP, (v >> 8) & 0xFF)
  SP = (SP - 1) & 0xFFFF
  bus_write(SP, v & 0xFF)
}

fn pop() -> int {
  let lo = bus_read(SP)
  SP = (SP + 1) & 0xFFFF
  let hi = bus_read(SP)
  SP = (SP + 1) & 0xFFFF
  return lo | (hi << 8)
}

fn rom_read(addr: int) -> int {
  let at = 0
  if addr < 0x4000 {
    let bank = 0
    if MBC1 == 1 && MODE == 1 { bank = BANK2 << 5 }
    at = bank * 0x4000 + addr
  } else {
    let bank = BANK1 | (BANK2 << 5)
    if MBC1 == 0 { bank = 1 }
    if bank == 0 { bank = 1 }
    at = bank * 0x4000 + (addr - 0x4000)
  }
  if at < 0 { return 0xFF }
  if at >= ROMSIZE { return 0xFF }
  return ROM[at]
}

fn io_read(reg: int) -> int {
  if reg == 0x00 {
    let sel = IO[0] & 0x30
    let down = 0
    if (sel & 0x10) == 0 { down = down | (PAD & 0x0F) }
    if (sel & 0x20) == 0 { down = down | ((PAD >> 4) & 0x0F) }
    return 0xC0 | sel | ((down ^ 0x0F) & 0x0F)
  }
  if reg == 0x04 { return DIV }
  if reg == 0x0F { return IF | 0xE0 }
  if reg == 0x44 { return LY }
  return IO[reg]
}

fn bus_read(addr: int) -> int {
  addr = addr & 0xFFFF
  if addr < 0x8000 { return rom_read(addr) }
  if addr < 0xA000 { return VRAM[addr - 0x8000] }
  if addr < 0xC000 {
    if RAMEN == 1 { return CRAM[addr - 0xA000] }
    return 0xFF
  }
  if addr < 0xE000 { return WRAM[addr - 0xC000] }
  if addr < 0xFE00 { return WRAM[addr - 0xE000] }
  if addr < 0xFEA0 { return OAM[addr - 0xFE00] }
  if addr < 0xFF00 { return 0xFF }
  if addr < 0xFF80 { return io_read(addr - 0xFF00) }
  if addr < 0xFFFF { return HRAM[addr - 0xFF80] }
  return IE
}

fn bus_write(addr: int, v: int) {
  addr = addr & 0xFFFF
  v = v & 0xFF
  if addr < 0x2000 {
    if (v & 0x0F) == 0x0A { RAMEN = 1 } else { RAMEN = 0 }
  } else if addr < 0x4000 {
    BANK1 = v & 0x1F
    if BANK1 == 0 { BANK1 = 1 }
  } else if addr < 0x6000 {
    BANK2 = v & 3
  } else if addr < 0x8000 {
    MODE = v & 1
  } else if addr < 0xA000 {
    VRAM[addr - 0x8000] = v
  } else if addr < 0xC000 {
    if RAMEN == 1 { CRAM[addr - 0xA000] = v }
  } else if addr < 0xE000 {
    WRAM[addr - 0xC000] = v
  } else if addr < 0xFE00 {
    WRAM[addr - 0xE000] = v
  } else if addr < 0xFEA0 {
    OAM[addr - 0xFE00] = v
  } else if addr < 0xFF00 {
    return
  } else if addr < 0xFF80 {
    let reg = addr - 0xFF00
    if reg == 0x00 {
      IO[0] = v & 0x30
    } else if reg == 0x04 {
      DIV = 0
    } else if reg == 0x0F {
      IF = v & 0x1F
    } else if reg == 0x46 {
      let src = v << 8
      let i = 0
      while i < 160 {
        OAM[i] = bus_read(src + i)
        i++
      }
    } else {
      IO[reg] = v
    }
  } else if addr < 0xFFFF {
    HRAM[addr - 0xFF80] = v
  } else {
    IE = v
  }
}

fn set_inc(v: int) -> int {
  let r = (v + 1) & 0xFF
  F = F & 0x10
  if r == 0 { F = F | 0x80 }
  if (v & 0x0F) == 0x0F { F = F | 0x20 }
  return r
}

fn set_dec(v: int) -> int {
  let r = (v - 1) & 0xFF
  F = (F & 0x10) | 0x40
  if r == 0 { F = F | 0x80 }
  if (v & 0x0F) == 0 { F = F | 0x20 }
  return r
}

fn add_a(v: int, with_carry: int) -> int {
  let c = 0
  if with_carry == 1 && (F & 0x10) != 0 { c = 1 }
  let sum = A + v + c
  F = 0
  if (sum & 0xFF) == 0 { F = F | 0x80 }
  if ((A & 0x0F) + (v & 0x0F) + c) > 0x0F { F = F | 0x20 }
  if sum > 0xFF { F = F | 0x10 }
  A = sum & 0xFF
  return A
}

fn sub_a(v: int, with_carry: int) -> int {
  let c = 0
  if with_carry == 1 && (F & 0x10) != 0 { c = 1 }
  let sub = v + c
  let res = A - sub
  F = 0x40
  if (res & 0xFF) == 0 { F = F | 0x80 }
  if (A & 0x0F) < ((v & 0x0F) + c) { F = F | 0x20 }
  if A < sub { F = F | 0x10 }
  A = res & 0xFF
  return A
}

fn alu(op: int, v: int) {
  if op == 0 {
    add_a(v, 0)
  } else if op == 1 {
    add_a(v, 1)
  } else if op == 2 {
    sub_a(v, 0)
  } else if op == 3 {
    sub_a(v, 1)
  } else if op == 4 {
    A = A & v
    F = 0x20
    if A == 0 { F = F | 0x80 }
  } else if op == 5 {
    A = A ^ v
    F = 0
    if A == 0 { F = 0x80 }
  } else if op == 6 {
    A = A | v
    F = 0
    if A == 0 { F = 0x80 }
  } else {
    let save = A
    sub_a(v, 0)
    A = save
  }
}

fn add_hl(rr: int) {
  let x = hl()
  let y = rr_get(rr)
  let sum = x + y
  F = F & 0x80
  if ((x & 0x0FFF) + (y & 0x0FFF)) > 0x0FFF { F = F | 0x20 }
  if sum > 0xFFFF { F = F | 0x10 }
  set_hl(sum & 0xFFFF)
}

fn add_sp(e: int) -> int {
  let x = SP & 0xFF
  let y = e & 0xFF
  SP = (SP + e) & 0xFFFF
  F = 0
  if ((SP - e) & 0x0F) + (y & 0x0F) > 0x0F { F = F | 0x20 }
  if x + y > 0xFF { F = F | 0x10 }
  return SP
}

fn hl_sp(e: int) {
  let x = SP & 0xFF
  let y = e & 0xFF
  set_hl((SP + e) & 0xFFFF)
  F = 0
  if (SP & 0x0F) + (y & 0x0F) > 0x0F { F = F | 0x20 }
  if x + y > 0xFF { F = F | 0x10 }
}

fn daa() {
  let a = A
  let adjust = 0
  let carry = 0
  if (F & 0x10) != 0 { carry = 1 }
  if (F & 0x20) != 0 || (F & 0x40) == 0 && (a & 0x0F) > 9 {
    adjust = adjust | 0x06
  }
  if carry == 1 || (F & 0x40) == 0 && a > 0x99 {
    adjust = adjust | 0x60
    carry = 1
  }
  if (F & 0x40) != 0 {
    a = (a - adjust) & 0xFF
  } else {
    a = (a + adjust) & 0xFF
  }
  A = a
  F = F & 0x40
  if a == 0 { F = F | 0x80 }
  if carry == 1 { F = F | 0x10 }
}

fn rlca() {
  let c = (A >> 7) & 1
  A = ((A << 1) | c) & 0xFF
  F = 0
  if c == 1 { F = 0x10 }
}

fn rrca() {
  let c = A & 1
  A = ((A >> 1) | (c << 7)) & 0xFF
  F = 0
  if c == 1 { F = 0x10 }
}

fn rla() {
  let c = (A >> 7) & 1
  let old = 0
  if (F & 0x10) != 0 { old = 1 }
  A = ((A << 1) | old) & 0xFF
  F = 0
  if c == 1 { F = 0x10 }
}

fn rra() {
  let c = A & 1
  let old = 0
  if (F & 0x10) != 0 { old = 1 }
  A = ((A >> 1) | (old << 7)) & 0xFF
  F = 0
  if c == 1 { F = 0x10 }
}

fn cb_op(op: int) -> int {
  let x = (op >> 6) & 3
  let y = (op >> 3) & 7
  let z = op & 7
  let v = r_get(z)
  if x == 0 {
    let r = 0
    let c = 0
    if y == 0 {
      c = (v >> 7) & 1
      r = ((v << 1) | c) & 0xFF
    } else if y == 1 {
      c = v & 1
      r = ((v >> 1) | (c << 7)) & 0xFF
    } else if y == 2 {
      c = (v >> 7) & 1
      let old = 0
      if (F & 0x10) != 0 { old = 1 }
      r = ((v << 1) | old) & 0xFF
    } else if y == 3 {
      c = v & 1
      let old = 0
      if (F & 0x10) != 0 { old = 1 }
      r = ((v >> 1) | (old << 7)) & 0xFF
    } else if y == 4 {
      c = (v >> 7) & 1
      r = (v << 1) & 0xFF
    } else if y == 5 {
      c = v & 1
      r = (v >> 1) | (v & 0x80)
    } else if y == 6 {
      r = ((v << 4) | (v >> 4)) & 0xFF
    } else {
      c = v & 1
      r = v >> 1
    }
    F = 0
    if r == 0 { F = F | 0x80 }
    if c == 1 { F = F | 0x10 }
    r_set(z, r)
  } else if x == 1 {
    F = F & 0x10
    F = F | 0x20
    if (v & (1 << y)) == 0 { F = F | 0x80 }
  } else if x == 2 {
    r_set(z, v & (0xFF ^ (1 << y)))
  } else {
    r_set(z, v | (1 << y))
  }
  if z == 6 { return 16 }
  return 8
}

fn step() -> int {
  if HALTED != 0 {
    if (IE & IF & 0x1F) != 0 {
      HALTED = 0
    } else {
      return 4
    }
  }
  if IME != 0 {
    let pending = IE & IF & 0x1F
    if pending != 0 {
      let bit = 0
      while bit < 5 {
        if (pending & (1 << bit)) != 0 {
          IF = IF & (0xFF ^ (1 << bit))
          IME = 0
          push(PC)
          PC = 0x40 + bit * 8
          return 20
        }
        bit++
      }
    }
  }

  let op = fetch8()

  if op == 0x00 { return 4 }
  if op == 0x76 { HALTED = 1; return 4 }

  # LD r,r' (0x40-0x7F, except HALT at 0x76).
  if op >= 0x40 && op <= 0x7F {
    let d = (op >> 3) & 7
    let s = op & 7
    r_set(d, r_get(s))
    if d == 6 || s == 6 { return 8 }
    return 4
  }

  # ALU A,r (0x80-0xBF).
  if op >= 0x80 && op <= 0xBF {
    let s = op & 7
    alu((op >> 3) & 7, r_get(s))
    if s == 6 { return 8 }
    return 4
  }

  if op == 0x01 || op == 0x11 || op == 0x21 || op == 0x31 {
    rr_set((op >> 4) & 3, fetch16())
    return 12
  }

  if op == 0x02 {
    bus_write((B << 8) | C, A)
    return 8
  }
  if op == 0x12 {
    bus_write((D << 8) | E, A)
    return 8
  }
  if op == 0x22 {
    bus_write(hl(), A)
    set_hl(hl() + 1)
    return 8
  }
  if op == 0x32 {
    bus_write(hl(), A)
    set_hl(hl() - 1)
    return 8
  }

  if op == 0x03 || op == 0x13 || op == 0x23 || op == 0x33 {
    let i = (op >> 4) & 3
    rr_set(i, rr_get(i) + 1)
    return 8
  }
  if op == 0x0B || op == 0x1B || op == 0x2B || op == 0x3B {
    let i = (op >> 4) & 3
    rr_set(i, rr_get(i) - 1)
    return 8
  }

  if op == 0x04 || op == 0x0C || op == 0x14 || op == 0x1C ||
     op == 0x24 || op == 0x2C || op == 0x34 || op == 0x3C {
    let i = (op >> 3) & 7
    r_set(i, set_inc(r_get(i)))
    if i == 6 { return 12 }
    return 4
  }
  if op == 0x05 || op == 0x0D || op == 0x15 || op == 0x1D ||
     op == 0x25 || op == 0x2D || op == 0x35 || op == 0x3D {
    let i = (op >> 3) & 7
    r_set(i, set_dec(r_get(i)))
    if i == 6 { return 12 }
    return 4
  }

  if op == 0x06 || op == 0x0E || op == 0x16 || op == 0x1E ||
     op == 0x26 || op == 0x2E || op == 0x36 || op == 0x3E {
    let i = (op >> 3) & 7
    r_set(i, fetch8())
    if i == 6 { return 12 }
    return 8
  }

  if op == 0x07 { rlca(); return 4 }
  if op == 0x0F { rrca(); return 4 }
  if op == 0x17 { rla(); return 4 }
  if op == 0x1F { rra(); return 4 }

  if op == 0x08 {
    let addr = fetch16()
    bus_write(addr, SP & 0xFF)
    bus_write(addr + 1, (SP >> 8) & 0xFF)
    return 20
  }

  if op == 0x09 || op == 0x19 || op == 0x29 || op == 0x39 {
    add_hl((op >> 4) & 3)
    return 8
  }

  if op == 0x0A { A = bus_read((B << 8) | C); return 8 }
  if op == 0x1A { A = bus_read((D << 8) | E); return 8 }
  if op == 0x2A {
    A = bus_read(hl())
    set_hl(hl() + 1)
    return 8
  }
  if op == 0x3A {
    A = bus_read(hl())
    set_hl(hl() - 1)
    return 8
  }

  if op == 0x10 {
    PC = (PC + 1) & 0xFFFF
    return 4
  }
  if op == 0x18 {
    let e = fetch_signed()
    PC = (PC + e) & 0xFFFF
    return 12
  }
  if op == 0x20 || op == 0x28 || op == 0x30 || op == 0x38 {
    let e = fetch_signed()
    if cond((op >> 3) & 3) == 1 {
      PC = (PC + e) & 0xFFFF
      return 12
    }
    return 8
  }

  if op == 0x27 { daa(); return 4 }
  if op == 0x2F { A = A ^ 0xFF; F = (F & 0x90) | 0x60; return 4 }
  if op == 0x37 { F = (F & 0x80) | 0x10; return 4 }
  if op == 0x3F {
    if (F & 0x10) != 0 {
      F = F & 0x90
    } else {
      F = (F & 0x90) | 0x10
    }
    return 4
  }

  if op == 0xC0 || op == 0xC8 || op == 0xD0 || op == 0xD8 {
    if cond((op >> 3) & 3) == 1 {
      PC = pop()
      return 20
    }
    return 8
  }
  if op == 0xC1 || op == 0xD1 || op == 0xE1 || op == 0xF1 {
    let i = (op >> 4) & 3
    let v = pop()
    if i == 3 {
      A = (v >> 8) & 0xFF
      F = v & 0xF0
    } else {
      rr_set(i, v)
    }
    return 12
  }
  if op == 0xC2 || op == 0xCA || op == 0xD2 || op == 0xDA {
    let addr = fetch16()
    if cond((op >> 3) & 3) == 1 {
      PC = addr
      return 16
    }
    return 12
  }
  if op == 0xC3 {
    PC = fetch16()
    return 16
  }
  if op == 0xC4 || op == 0xCC || op == 0xD4 || op == 0xDC {
    let addr = fetch16()
    if cond((op >> 3) & 3) == 1 {
      push(PC)
      PC = addr
      return 24
    }
    return 12
  }
  if op == 0xC5 || op == 0xD5 || op == 0xE5 || op == 0xF5 {
    let i = (op >> 4) & 3
    if i == 3 {
      push((A << 8) | F)
    } else {
      push(rr_get(i))
    }
    return 16
  }
  if op == 0xC6 || op == 0xCE || op == 0xD6 || op == 0xDE ||
     op == 0xE6 || op == 0xEE || op == 0xF6 || op == 0xFE {
    alu((op >> 3) & 7, fetch8())
    return 8
  }
  if op == 0xC7 || op == 0xCF || op == 0xD7 || op == 0xDF ||
     op == 0xE7 || op == 0xEF || op == 0xF7 || op == 0xFF {
    push(PC)
    PC = op & 0x38
    return 16
  }
  if op == 0xC9 {
    PC = pop()
    return 16
  }
  if op == 0xCB { return cb_op(fetch8()) }
  if op == 0xCD {
    let addr = fetch16()
    push(PC)
    PC = addr
    return 24
  }
  if op == 0xD9 {
    PC = pop()
    IME = 1
    return 16
  }

  if op == 0xE0 {
    bus_write(0xFF00 + fetch8(), A)
    return 12
  }
  if op == 0xE2 {
    bus_write(0xFF00 + C, A)
    return 8
  }
  if op == 0xE8 {
    add_sp(fetch_signed())
    return 16
  }
  if op == 0xE9 {
    PC = hl()
    return 4
  }
  if op == 0xEA {
    bus_write(fetch16(), A)
    return 16
  }
  if op == 0xF0 {
    A = bus_read(0xFF00 + fetch8())
    return 12
  }
  if op == 0xF2 {
    A = bus_read(0xFF00 + C)
    return 8
  }
  if op == 0xF3 { IME = 0; return 4 }
  if op == 0xF8 {
    hl_sp(fetch_signed())
    return 12
  }
  if op == 0xF9 {
    SP = hl()
    return 8
  }
  if op == 0xFA {
    A = bus_read(fetch16())
    return 16
  }
  if op == 0xFB {
    IME = 1
    return 4
  }

  return 4
}

fn reset() {
  A = 0x01
  F = 0xB0
  B = 0
  C = 0x13
  D = 0
  E = 0xD8
  H = 0x01
  L = 0x4D
  SP = 0xFFFE
  PC = 0x0100
  IE = 0
  IF = 0
  IME = 0
  HALTED = 0
  DIV = 0
  LY = 0
  PAD = 0
  RAMEN = 0
  BANK1 = 1
  BANK2 = 0
  MODE = 0
  let i = 0
  while i < 0x80 {
    IO[i] = 0
    i++
  }
  IO[0x00] = 0xCF
  IO[0x40] = 0x91
  IO[0x47] = 0xFC
  IO[0x48] = 0xFF
  IO[0x49] = 0xFF
}

fn load_rom(path: str) -> int {
  let n = file_size(path)
  if n <= 0 { return 0 }
  if n > 0x200000 { n = 0x200000 }
  let data = read_file(path)
  let i = 0
  while i < n {
    ROM[i] = data[i]
    i++
  }
  ROMSIZE = n
  MBC1 = 0
  if n >= 0x150 {
    let t = ROM[0x147]
    if t >= 1 && t <= 3 { MBC1 = 1 }
  }
  return 1
}

fn run(steps: int) {
  let i = 0
  while i < steps {
    if HALTED != 0 { return }
    step()
    i++
  }
}

fn render_frame() {
  let lcdc = IO[0x40]
  if (lcdc & 0x01) == 0 {
    let i = 0
    while i < 160 * 144 {
      FRAME[i] = 0
      i++
    }
    return
  }
  let bgp = IO[0x47]
  let scx = IO[0x43]
  let scy = IO[0x42]
  let map = 0x9800
  if (lcdc & 0x08) != 0 { map = 0x9C00 }
  let y = 0
  while y < 144 {
    let map_y = (y + scy) & 0xFF
    let x = 0
    while x < 160 {
      let map_x = (x + scx) & 0xFF
      let tile = VRAM[(map - 0x8000) + ((map_y >> 3) * 32) + (map_x >> 3)]
      let addr = 0
      if (lcdc & 0x10) != 0 {
        addr = tile * 16
      } else {
        if tile >= 128 { tile = tile - 256 }
        addr = 0x1000 + tile * 16
      }
      let row = (map_y & 7) * 2
      let bit = 7 - (map_x & 7)
      let lo = VRAM[addr + row]
      let hi = VRAM[addr + row + 1]
      let color = ((lo >> bit) & 1) | (((hi >> bit) & 1) << 1)
      FRAME[y * 160 + x] = (bgp >> (color * 2)) & 3
      x++
    }
    y++
  }
}

fn ppu_tick(cycles: int) {
  if (IO[0x40] & 0x80) == 0 {
    LY = 0
    IO[0x44] = 0
    return
  }
  PPU_DOT = PPU_DOT + cycles
  while PPU_DOT >= 456 {
    PPU_DOT = PPU_DOT - 456
    LY = LY + 1
    if LY == 144 {
      IF = IF | 1
      render_frame()
      IO[0x41] = 1
    } else if LY > 153 {
      LY = 0
      IO[0x41] = 0
    }
  }
  IO[0x44] = LY
}

fn run_cycles(cycles: int) {
  let done = 0
  while done < cycles {
    if HALTED != 0 {
      ppu_tick(4)
      done = done + 4
      if (IE & IF & 0x1F) != 0 { HALTED = 0 }
    } else {
      let c = step()
      ppu_tick(c)
      done = done + c
    }
  }
}

fn render_text() {
  let y = 0
  while y < 144 {
    let x = 0
    while x < 160 {
      let s = FRAME[y * 160 + x]
      if s == 0 { TEXTROW[x] = 32 }
      else if s == 1 { TEXTROW[x] = 46 }
      else if s == 2 { TEXTROW[x] = 111 }
      else { TEXTROW[x] = 79 }
      x++
    }
    TEXTROW[160] = 0
    print(TEXTROW)
    print("\n")
    y++
  }
}

fn hx8(v: int) {
  print(slice(HEX, (v >> 4) & 0x0F, 1))
  print(slice(HEX, v & 0x0F, 1))
}

fn hx16(v: int) {
  hx8((v >> 8) & 0xFF)
  hx8(v & 0xFF)
}

fn dump_regs() {
  print("PC=")
  hx16(PC)
  print(" SP=")
  hx16(SP)
  print(" AF=")
  hx16((A << 8) | F)
  print(" BC=")
  hx16((B << 8) | C)
  print(" DE=")
  hx16((D << 8) | E)
  print(" HL=")
  hx16(hl())
  print("\n")
}

fn dump_mem(addr: int, n: int) {
  let i = 0
  while i < n {
    if i > 0 { print(" ") }
    hx8(bus_read(addr + i))
    i++
  }
  print("\n")
}

fn put8(b: str, off: int, v: int) {
  b[off] = v & 0xFF
}

fn put16(b: str, off: int, v: int) {
  b[off] = v & 0xFF
  b[off + 1] = (v >> 8) & 0xFF
}

fn put32(b: str, off: int, v: int) {
  b[off] = v & 0xFF
  b[off + 1] = (v >> 8) & 0xFF
  b[off + 2] = (v >> 16) & 0xFF
  b[off + 3] = (v >> 24) & 0xFF
}

fn get16(b: str, off: int) -> int {
  return (b[off] & 0xFF) | ((b[off + 1] & 0xFF) << 8)
}

fn get16be(b: str, off: int) -> int {
  return ((b[off] & 0xFF) << 8) | (b[off + 1] & 0xFF)
}

fn get32(b: str, off: int) -> int {
  return (b[off] & 0xFF) | ((b[off + 1] & 0xFF) << 8) | ((b[off + 2] & 0xFF) << 16) | ((b[off + 3] & 0xFF) << 24)
}

fn put_str4(b: str, off: int, s: str) -> int {
  let i = 0
  while i < len(s) {
    b[off + i] = s[i]
    i++
  }
  let end = off + i
  while (end & 3) != 0 {
    b[end] = 0
    end++
  }
  return end
}

fn env_val(key: str) -> str {
  let e = read_file("/proc/self/environ")
  let kl = len(key)
  let i = 0
  while i < 4096 {
    let j = 0
    let ok = 1
    while j < kl {
      if e[i + j] != key[j] { ok = 0 }
      j++
    }
    if ok == 1 && e[i + kl] == 61 {
      let s = i + kl + 1
      let end = s
      while end < 4096 && e[end] != 0 { end++ }
      return slice(e, s, end - s)
    }
    while i < 4096 && e[i] != 0 { i++ }
    i++
  }
  return ""
}

fn x_auth(path: str) -> int {
  let n = file_size(path)
  if n < 4 { return 0 }
  let b = read_file(path)
  let o = 0
  while o + 2 <= n {
    o = o + 2
    let alen = get16be(b, o)
    o = o + 2
    o = o + alen
    let nlen = get16be(b, o)
    o = o + 2
    let num0 = o
    o = o + nlen
    let namelen = get16be(b, o)
    o = o + 2
    let name0 = o
    o = o + namelen
    let dlen = get16be(b, o)
    o = o + 2
    let data0 = o
    o = o + dlen
    if o > n { return 0 }
    if str_eq(slice(b, num0, nlen), "0") == 1 {
      if str_eq(slice(b, name0, namelen), "MIT-MAGIC-COOKIE-1") == 1 {
        let i = 0
        while i < dlen && i < 64 {
          XAUTH[i] = b[data0 + i]
          i++
        }
        XAUTHLEN = dlen
        return 1
      }
    }
  }
  return 0
}

fn x_connect() -> int {
  let xa = env_val("XAUTHORITY")
  if len(xa) == 0 {
    let home = env_val("HOME")
    if len(home) == 0 { home = "/root" }
    xa = home + "/.Xauthority"
  }
  if x_auth(xa) == 0 { return 0 }
  XFD = sock("/tmp/.X11-unix/X0")
  if XFD < 0 { return 0 }

  put8(XBUF, 0, 108)
  put8(XBUF, 1, 0)
  put16(XBUF, 2, 11)
  put16(XBUF, 4, 0)
  put16(XBUF, 6, 18)
  put16(XBUF, 8, XAUTHLEN)
  put16(XBUF, 10, 0)
  let off = put_str4(XBUF, 12, "MIT-MAGIC-COOKIE-1")
  let i = 0
  while i < XAUTHLEN {
    XBUF[off + i] = XAUTH[i]
    i++
  }
  off = off + XAUTHLEN
  while (off & 3) != 0 {
    XBUF[off] = 0
    off++
  }
  if fd_write(XFD, XBUF, off) != off { return 0 }

  if fd_read(XFD, XBUF, 8) != 8 { return 0 }
  if XBUF[0] != 1 { return 0 }
  let extra = get16(XBUF, 6) * 4
  if extra > 32760 { return 0 }
  if fd_read(XFD, XREPLY, extra) != extra { return 0 }

  let vendor = get16(XREPLY, 16)
  let vpad = (vendor + 3) & 0xFFFFFFFC
  let formats = XREPLY[21]
  let screen = 32 + vpad + formats * 8
  XROOT = get32(XREPLY, screen)
  XVISUAL = get32(XREPLY, screen + 32)
  XDEPTH = XREPLY[screen + 38]
  let base = get32(XREPLY, 4)
  XWIN = base + 1
  XGCS[0] = base + 2
  XGCS[1] = base + 3
  XGCS[2] = base + 4
  XGCS[3] = base + 5
  return 1
}

fn x_atom(name: str) -> int {
  let n = len(name)
  put8(XBUF, 0, 16)
  put8(XBUF, 1, 0)
  put16(XBUF, 2, 2 + (n + 3) / 4)
  put16(XBUF, 4, n)
  put16(XBUF, 6, 0)
  let i = 0
  while i < n {
    XBUF[8 + i] = name[i]
    i++
  }
  let end = 8 + n
  while (end & 3) != 0 {
    XBUF[end] = 0
    end++
  }
  if fd_write(XFD, XBUF, end) != end { return 0 }
  if fd_read(XFD, XREPLY, 32) != 32 { return 0 }
  return get32(XREPLY, 8)
}

fn x_prop(prop: int, typ: int, fmt: int, n: int) {
  let bytes = n
  if fmt == 32 { bytes = n * 4 }
  put8(XBUF, 0, 18)
  put8(XBUF, 1, 0)
  put16(XBUF, 2, (24 + bytes + 3) / 4)
  put32(XBUF, 4, XWIN)
  put32(XBUF, 8, prop)
  put32(XBUF, 12, typ)
  put8(XBUF, 16, fmt)
  put8(XBUF, 17, 0)
  put8(XBUF, 18, 0)
  put8(XBUF, 19, 0)
  put32(XBUF, 20, n)
  let end = 24 + bytes
  let total = (end + 3) & 0xFFFFFFFC
  while end < total {
    XBUF[end] = 0
    end++
  }
  fd_write(XFD, XBUF, total)
}

fn x_wm() {
  XWM_NAME = x_atom("WM_NAME")
  XWM_CLASS = x_atom("WM_CLASS")
  XWM_PROTOCOLS = x_atom("WM_PROTOCOLS")
  XWM_DELETE = x_atom("WM_DELETE_WINDOW")
  let name = "tgameboy"
  if XWM_NAME != 0 {
    let i = 0
    while i < len(name) {
      XBUF[24 + i] = name[i]
      i++
    }
    x_prop(XWM_NAME, 31, 8, len(name))
  }
  if XWM_CLASS != 0 {
    let n = len(name)
    let i = 0
    while i < n {
      XBUF[24 + i] = name[i]
      XBUF[24 + n + 1 + i] = name[i]
      i++
    }
    XBUF[24 + n] = 0
    XBUF[24 + n + 1 + n] = 0
    x_prop(XWM_CLASS, 31, 8, n * 2 + 2)
  }
  if XWM_PROTOCOLS != 0 && XWM_DELETE != 0 {
    put32(XBUF, 24, XWM_DELETE)
    x_prop(XWM_PROTOCOLS, 4, 32, 1)
  }
}

fn x_create() {
  put8(XBUF, 0, 1)
  put8(XBUF, 1, XDEPTH)
  put16(XBUF, 2, 10)
  put32(XBUF, 4, XWIN)
  put32(XBUF, 8, XROOT)
  put16(XBUF, 12, 0)
  put16(XBUF, 14, 0)
  put16(XBUF, 16, 480)
  put16(XBUF, 18, 432)
  put16(XBUF, 20, 0)
  put16(XBUF, 22, 1)
  put32(XBUF, 24, XVISUAL)
  put32(XBUF, 28, 0x802)
  put32(XBUF, 32, 0)
  put32(XBUF, 36, 0x28007)        # keys, clicks, exposure, structure
  fd_write(XFD, XBUF, 40)

  let i = 0
  while i < 4 {
    put8(XBUF, 0, 55)
    put8(XBUF, 1, 0)
    put16(XBUF, 2, 6)
    put32(XBUF, 4, XGCS[i])
    put32(XBUF, 8, XWIN)
    put32(XBUF, 12, 12)
    put32(XBUF, 16, COLORS[i])
    put32(XBUF, 20, 0)
    fd_write(XFD, XBUF, 24)
    i++
  }

  x_wm()

  put8(XBUF, 0, 8)
  put8(XBUF, 1, 0)
  put16(XBUF, 2, 2)
  put32(XBUF, 4, XWIN)
  fd_write(XFD, XBUF, 8)
  x_focus()
}

fn x_clear() {
  put8(XBUF, 0, 70)
  put8(XBUF, 1, 0)
  put16(XBUF, 2, 5)
  put32(XBUF, 4, XWIN)
  put32(XBUF, 8, XGCS[0])
  put16(XBUF, 12, 0)
  put16(XBUF, 14, 0)
  put16(XBUF, 16, 480)
  put16(XBUF, 18, 432)
  fd_write(XFD, XBUF, 20)
}

fn x_row(shade: int, y: int) {
  put8(XBUF, 0, 70)
  put8(XBUF, 1, 0)
  put32(XBUF, 4, XWIN)
  put32(XBUF, 8, XGCS[shade])
  let off = 12
  let count = 0
  let x = 0
  while x < 160 {
    if FRAME[y * 160 + x] == shade {
      let start = x
      while x < 160 && FRAME[y * 160 + x] == shade { x++ }
      put16(XBUF, off, start * 3)
      put16(XBUF, off + 2, y * 3)
      put16(XBUF, off + 4, (x - start) * 3)
      put16(XBUF, off + 6, 3)
      off = off + 8
      count = count + 1
    } else {
      x++
    }
  }
  if count > 0 {
    put16(XBUF, 2, (12 + count * 8) / 4)
    fd_write(XFD, XBUF, 12 + count * 8)
  }
}

fn x_draw() {
  x_clear()
  let s = 1
  while s < 4 {
    let y = 0
    while y < 144 {
      x_row(s, y)
      y++
    }
    s++
  }
}

fn pad_key(code: int, pressed: int) {
  let bit = 0
  if code == 113 || code == 38 { bit = 0x02 }      # Left / A
  else if code == 114 || code == 40 { bit = 0x01 }  # Right / D
  else if code == 111 || code == 25 { bit = 0x04 }  # Up / W
  else if code == 116 || code == 39 { bit = 0x08 }  # Down / S
  else if code == 52 || code == 65 { bit = 0x10 }   # A / Space
  else if code == 53 { bit = 0x20 }                 # B
  else if code == 22 { bit = 0x40 }                 # Select
  else if code == 36 { bit = 0x80 }                 # Start
  if bit != 0 {
    if pressed == 1 {
      PAD = PAD | bit
    } else {
      PAD = PAD & (0xFF ^ bit)
    }
  }
}

fn x_focus() {
  put8(XBUF, 0, 42)               # SetInputFocus
  put8(XBUF, 1, 2)                # RevertToParent
  put16(XBUF, 2, 2)
  put32(XBUF, 4, XWIN)
  fd_write(XFD, XBUF, 8)
}

fn x_event(ev: str) {
  let t = ev[0] & 0x7F
  if t == 2 {
    pad_key(ev[1], 1)
  } else if t == 3 {
    pad_key(ev[1], 0)
  } else if t == 4 {
    x_focus()
  } else if t == 19 {
    x_focus()
  } else if t == 12 {
    x_draw()
  } else if t == 17 {
    QUIT = 1
  } else if t == 33 {
    if get32(ev, 8) == XWM_PROTOCOLS && get32(ev, 12) == XWM_DELETE {
      QUIT = 1
    }
  }
}

fn run_x11() -> int {
  if x_connect() == 0 { return 0 }
  x_create()
  render_frame()
  x_draw()
  while QUIT == 0 {
    let rev = fd_poll(XFD, 0)
    while rev != 0 {
      let n = fd_read(XFD, XEV, 32)
      if n != 32 { QUIT = 1; break }
      x_event(XEV)
      rev = fd_poll(XFD, 0)
    }
    if QUIT != 0 { break }
    run_cycles(70224)
    x_draw()
    fd_poll(XFD, 16)
  }
  return 1
}

fn main() {
  if argc() < 2 {
    print("usage: tgameboy ROM [steps]\n")
    print("       tgameboy ROM [steps] regs\n")
    print("       tgameboy ROM frame [cycles]\n")
    print("       tgameboy ROM keys MASK [steps]\n")
    print("       tgameboy ROM x11\n")
    print("\n")
    print("  steps: instructions to run (default 100000)\n")
    print("  regs:  also print PC/SP/AF/BC/DE/HL\n")
    print("  frame: print the 160x144 background after one PPU frame\n")
    print("  keys:  run with held joypad bits (tests): Right=1, Left=2,\n")
    print("         Up=4, Down=8, A=16, B=32, Select=64, Start=128\n")
    print("  x11:   open a 3x (480x432) native window\n")
    print("\n")
    print("  keys:  arrows/WASD d-pad, Z/Space A, X B, Enter Start, Backspace Select\n")
    print("\n")
    print("The next 32 bytes at 0xC000 are always printed.\n")
    exit(2)
  }
  if load_rom(argv(1)) == 0 {
    print_err("tgameboy: cannot read ")
    print_err(argv(1))
    print_err("\n")
    exit(2)
  }
  reset()
  if argc() > 2 && str_eq(argv(2), "keys") == 1 {
    if argc() > 3 { PAD = int(argv(3)) & 0xFF }
    let steps = 100000
    if argc() > 4 {
      steps = int(argv(4))
      if steps <= 0 { steps = 100000 }
    }
    run(steps)
    dump_mem(0xC000, 32)
    exit(0)
  }
  if argc() > 2 && str_eq(argv(2), "x11") == 1 {
    if run_x11() == 0 {
      print_err("tgameboy: cannot open an X11 window\n")
      exit(2)
    }
    exit(0)
  }
  if argc() > 2 && str_eq(argv(2), "frame") == 1 {
    let cycles = 70224
    if argc() > 3 {
      cycles = int(argv(3))
      if cycles <= 0 { cycles = 70224 }
    }
    run_cycles(cycles)
    render_frame()
    render_text()
    exit(0)
  }
  let steps = 100000
  if argc() > 2 {
    steps = int(argv(2))
    if steps <= 0 { steps = 100000 }
  }
  run(steps)
  if argc() > 3 && str_eq(argv(3), "regs") == 1 { dump_regs() }
  dump_mem(0xC000, 32)
}
