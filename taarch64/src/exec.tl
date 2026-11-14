# exec.tl -- AArch64 instruction decoder and interpreter.
#
# One function per encoding group, dispatched by masks in step(). The subset is
# the scalar integer A64 that `gcc -O2` emits for freestanding C, plus the
# 128-bit load/store pairs it uses to copy small blocks. Anything outside the
# subset stops with the instruction word and program counter, which is what
# keeps "runs correctly" and "refuses loudly" the only two possible outcomes.

# ---------------------------------------------------------------- bit helpers

fn bf(v: int, lo: int, n: int) -> int {
  return (v >> lo) & maskw(n)
}

# Highest set bit, or -1 when the value is zero.
fn hsb(v: int) -> int {
  let i = 63
  while i >= 0 {
    if (v >> i) & 1 { return i }
    i = i - 1
  }
  return -1
}

fn ror(v: int, n: int, w: int) -> int {
  let m = maskw(w)
  let x = v & m
  let k = n & (w - 1)
  if k == 0 { return x }
  if w >= 64 {
    return ((x >> k) & maskw(64 - k)) | (x << (64 - k))
  }
  return ((x >> k) | (x << (w - k))) & m
}

fn lsr(v: int, n: int, w: int) -> int {
  let k = n & (w - 1)
  if k == 0 { return v & maskw(w) }
  if w >= 64 { return (v >> k) & maskw(64 - k) }
  return (v & maskw(w)) >> k
}

fn asr(v: int, n: int, w: int) -> int {
  let k = n & (w - 1)
  if w >= 64 { return v >> k }
  return (sx(v & maskw(w), w) >> k) & maskw(w)
}

fn lsl(v: int, n: int, w: int) -> int {
  let k = n & (w - 1)
  return (v << k) & maskw(w)
}

# Shift type field: 0 LSL, 1 LSR, 2 ASR, 3 ROR.
fn shf(v: int, typ: int, amt: int, w: int) -> int {
  if typ == 0 { return lsl(v, amt, w) }
  if typ == 1 { return lsr(v, amt, w) }
  if typ == 2 { return asr(v, amt, w) }
  return ror(v, amt, w)
}

fn ult(a: int, b: int) -> int {
  if (a < 0) != (b < 0) { return a < 0 }
  return a < b
}

# ---------------------------------------------------------------- flags

fn addf(a: int, b: int, cin: int, w: int) -> int {
  let m = maskw(w)
  let x = a & m
  let y = b & m
  let s = (x + y + cin) & m
  let sh = w - 1
  CF = ((x & y) | ((x | y) & (~s))) >> sh & 1
  VF = ((x ^ s) & (y ^ s)) >> sh & 1
  NF = (s >> sh) & 1
  ZF = s == 0
  return s
}

fn subf(a: int, b: int, cin: int, w: int) -> int {
  let m = maskw(w)
  let x = a & m
  let y = b & m
  let bin = 1 - (cin & 1)
  let s = (x - y - bin) & m
  let sh = w - 1
  let na = (~x) & m
  let borrow = ((na & y) | ((na | y) & (0 - bin))) >> sh & 1
  CF = 1 - borrow
  VF = ((x ^ y) & (x ^ s)) >> sh & 1
  NF = (s >> sh) & 1
  ZF = s == 0
  return s
}

fn cond_ok(c: int) -> int {
  if c == 0 { return ZF }
  if c == 1 { return ZF == 0 }
  if c == 2 { return CF }
  if c == 3 { return CF == 0 }
  if c == 4 { return NF }
  if c == 5 { return NF == 0 }
  if c == 6 { return VF }
  if c == 7 { return VF == 0 }
  if c == 8 { return CF == 1 && ZF == 0 }
  if c == 9 { return CF == 0 || ZF == 1 }
  if c == 10 { return NF == VF }
  if c == 11 { return NF != VF }
  if c == 12 { return ZF == 0 && NF == VF }
  if c == 13 { return ZF == 1 || NF != VF }
  return 1
}

# ---------------------------------------------------------------- diagnostics

fn bad(ins: int) {
  die("unsupported instruction 0x" + hex(ins) + " at pc 0x" + hex(AT))
}

fn unsup(what: str, ins: int) {
  die(what + " (0x" + hex(ins) + ") at pc 0x" + hex(AT))
}

# ---------------------------------------------------------------- loads/stores

# size: 0 byte, 1 half, 2 word, 3 double. opc: 0 store, 1 load zero-extend,
# 2 load sign-extend, 3 prefetch.
fn ldst(size: int, opc: int, rt: int, addr: int) {
  if opc == 0 {
    if size == 0 { wr8(addr, xget(rt)) }
    else if size == 1 { wr16(addr, xget(rt)) }
    else if size == 2 { wr32(addr, xget(rt)) }
    else { wr64(addr, xget(rt)) }
    return
  }
  if opc == 1 {
    if size == 0 { xset(rt, rd8(addr)) }
    else if size == 1 { xset(rt, rd16(addr)) }
    else if size == 2 { xset(rt, rd32(addr)) }
    else { xset(rt, rd64(addr)) }
    return
  }
  if opc == 2 {
    if size == 0 { xset(rt, sx(rd8(addr), 8)) }
    else if size == 1 { xset(rt, sx(rd16(addr), 16)) }
    else if size == 2 { xset(rt, sx(rd32(addr), 32)) }
    else { die("invalid sign-extending load at pc 0x" + hex(AT)) }
    return
  }
  # opc == 3 is PRFM, a hint with no architectural effect.
}

# ---------------------------------------------------------------- branches

fn do_b(ins: int) {
  let link = bf(ins, 31, 1)
  let off = sx(bf(ins, 0, 26), 26) << 2
  let target = PC - 4 + off
  if link == 1 { X[30] = PC }
  PC = target
}

fn do_bcond(ins: int) {
  let cond = bf(ins, 0, 4)
  let off = sx(bf(ins, 5, 19), 19) << 2
  if cond_ok(cond) == 1 { PC = PC - 4 + off }
}

fn do_cbz(ins: int) {
  let is64 = bf(ins, 31, 1)
  let op = bf(ins, 24, 1)
  let rt = bf(ins, 0, 5)
  let off = sx(bf(ins, 5, 19), 19) << 2
  let v = xget(rt)
  if is64 == 0 { v = v & M32 }
  let zero = v == 0
  if (op == 0 && zero) || (op == 1 && zero == 0) { PC = PC - 4 + off }
}

fn do_tbz(ins: int) {
  let op = bf(ins, 24, 1)
  let bit = (bf(ins, 31, 1) << 5) | bf(ins, 19, 5)
  let rt = bf(ins, 0, 5)
  let off = sx(bf(ins, 5, 14), 14) << 2
  let set = (xget(rt) >> bit) & 1
  if (op == 0 && set == 0) || (op == 1 && set == 1) { PC = PC - 4 + off }
}

fn do_br(ins: int) {
  let opc = bf(ins, 21, 4)
  let rn = bf(ins, 5, 5)
  if opc == 0 { PC = xget(rn); return }        # BR
  if opc == 1 { X[30] = PC; PC = xget(rn); return }  # BLR
  if opc == 2 { PC = xget(rn); return }        # RET
  unsup("unsupported branch-register form", ins)
}

# ---------------------------------------------------------------- system

fn do_system(ins: int) {
  if (ins & 0xFFFFF09F) == 0xD503309F { return }   # DSB / DMB / ISB
  if (ins & 0xFFFFF09F) == 0xD503201F { return }   # NOP, YIELD, WFE, WFI, SEV
  if (ins & 0xFFF00000) == 0xD5300000 {            # MRS
    let rt = bf(ins, 0, 5)
    if (ins & 0xFFFFFFE0) == 0xD53BD040 { xset(rt, 0); return }        # TPIDR_EL0
    if (ins & 0xFFFFFFE0) == 0xD53BE040 { xset(rt, TICKS); return }    # CNTVCT_EL0
    if (ins & 0xFFFFFFE0) == 0xD53BE000 { xset(rt, 1000000000); return } # CNTFRQ_EL0
    unsup("unsupported system register read", ins)
  }
  if (ins & 0xFFF00000) == 0xD5100000 {            # MSR
    if (ins & 0xFFFFFFE0) == 0xD51BD040 { return }  # TPIDR_EL0: ignored
    unsup("unsupported system register write", ins)
  }
  if (ins & 0xFFF00000) == 0xD5000000 { return }    # SYS / cache maintenance
  bad(ins)
}

# ---------------------------------------------------------------- immediates

fn do_adr(ins: int) {
  let page = bf(ins, 31, 1)
  let imm = (bf(ins, 5, 19) << 2) | bf(ins, 29, 2)
  let off = sx(imm, 21)
  let rt = bf(ins, 0, 5)
  if page == 0 { xset(rt, PC - 4 + off) }
  else { xset(rt, ((PC - 4) & ~4095) + (off << 12)) }
}

fn addsub_exec(ins: int, a: int, b: int, is64: int, setflags: int) -> int {
  let w = 64
  if is64 == 0 { w = 32 }
  let sub = bf(ins, 30, 1)
  let r = 0
  if setflags == 1 {
    if sub == 0 { r = addf(a, b, 0, w) } else { r = subf(a, b, 1, w) }
  } else {
    if sub == 0 { r = a + b } else { r = a - b }
    r = r & maskw(w)
  }
  return r
}

fn do_addsub_imm(ins: int) {
  let is64 = bf(ins, 31, 1)
  let setflags = bf(ins, 29, 1)
  let rn = bf(ins, 5, 5)
  let rd = bf(ins, 0, 5)
  let imm = bf(ins, 10, 12)
  if bf(ins, 22, 1) == 1 { imm = imm << 12 }
  let r = addsub_exec(ins, sp_get(rn), imm, is64, setflags)
  if setflags == 0 && rd == 31 { SP = r } else { xset(rd, r) }
}

# Decode the N:immr:imms logical-immediate bitmask (ARM ARM DecodeBitMasks).
fn dbitmask(immn: int, imms: int, immr: int, w: int) -> int {
  let len = hsb((immn << 6) | ((~imms) & 0x3F))
  if len < 0 { die("invalid logical immediate") }
  let size = 1 << len
  if size > w { die("invalid logical immediate for this register width") }
  let levels = size - 1
  let s = imms & levels
  let r = immr & levels
  if s == levels { die("invalid logical immediate") }
  let pat = ror((1 << (s + 1)) - 1, r, size)
  let outm = 0
  let shift = 0
  while shift < w {
    outm = (outm | (pat << shift)) & maskw(w)
    shift = shift + size
  }
  return outm
}

fn do_logical_imm(ins: int) {
  let is64 = bf(ins, 31, 1)
  let opc = bf(ins, 29, 2)
  let w = 64
  if is64 == 0 { w = 32 }
  let mask = dbitmask(bf(ins, 22, 1), bf(ins, 10, 6), bf(ins, 16, 6), w)
  let a = xget(bf(ins, 5, 5))
  let r = 0
  if opc == 0 { r = a & mask }
  else if opc == 1 { r = a | mask }
  else if opc == 2 { r = a ^ mask }
  else { r = a & mask }
  r = r & maskw(w)
  if opc == 3 {
    NF = (r >> (w - 1)) & 1
    ZF = r == 0
    CF = 0
    VF = 0
  }
  xset(bf(ins, 0, 5), r)
}

fn do_movewide(ins: int) {
  let is64 = bf(ins, 31, 1)
  let opc = bf(ins, 29, 2)
  let hw = bf(ins, 21, 2)
  let imm = bf(ins, 5, 16)
  let rd = bf(ins, 0, 5)
  let w = 64
  if is64 == 0 { w = 32 }
  let shift = hw * 16
  let v = (imm << shift) & maskw(w)
  if opc == 0 { v = (~v) & maskw(w) }             # MOVN
  else if opc == 3 { v = (xget(rd) & ~(0xFFFF << shift)) | v }  # MOVK
  else if opc != 2 { bad(ins) }                   # MOVZ
  xset(rd, v & maskw(w))
}

fn do_bitfield(ins: int) {
  let is64 = bf(ins, 31, 1)
  let opc = bf(ins, 29, 2)
  let immr = bf(ins, 16, 6)
  let imms = bf(ins, 10, 6)
  let rn = bf(ins, 5, 5)
  let rd = bf(ins, 0, 5)
  let w = 64
  if is64 == 0 { w = 32 }
  if w == 32 { immr = immr & 31; imms = imms & 31 }
  let src = xget(rn) & maskw(w)
  let r = 0
  if opc == 0 {                                   # SBFM
    if imms >= immr {
      r = sx(lsr(src, immr, w), imms - immr + 1)
    } else {
      r = (sx(src & maskw(imms + 1), imms + 1) << (w - immr)) & maskw(w)
    }
  } else if opc == 1 {                            # BFM
    if imms >= immr {
      let width = imms - immr + 1
      let field = maskw(width) << immr
      r = (xget(rd) & ~field) | ((src & maskw(width)) << immr)
    } else {
      let width = imms + 1
      let pos = w - immr
      let field = maskw(width) << pos
      r = (xget(rd) & ~field) | ((src & maskw(width)) << pos)
    }
  } else if opc == 2 {                            # UBFM
    if imms >= immr {
      r = lsr(src, immr, w) & maskw(imms - immr + 1)
    } else {
      r = (src & maskw(imms + 1)) << (w - immr)
    }
  } else {
    bad(ins)
  }
  xset(rd, r & maskw(w))
}

fn do_extract(ins: int) {
  let is64 = bf(ins, 31, 1)
  let w = 64
  if is64 == 0 { w = 32 }
  let lsb = bf(ins, 10, 6)
  if w == 32 { lsb = lsb & 31 }
  let a = xget(bf(ins, 5, 5))
  let b = xget(bf(ins, 16, 5))
  let r = 0
  if lsb == 0 { r = a } else { r = lsr(a, lsb, w) | (b << (w - lsb)) }
  xset(bf(ins, 0, 5), r & maskw(w))
}

# ---------------------------------------------------------------- registers

fn do_logical_reg(ins: int) {
  let is64 = bf(ins, 31, 1)
  let opc = bf(ins, 29, 2)
  let w = 64
  if is64 == 0 { w = 32 }
  let b = shf(xget(bf(ins, 16, 5)), bf(ins, 22, 2), bf(ins, 10, 6), w)
  if bf(ins, 21, 1) == 1 { b = (~b) & maskw(w) }
  let a = xget(bf(ins, 5, 5))
  let r = 0
  if opc == 0 { r = a & b }
  else if opc == 1 { r = a | b }
  else if opc == 2 { r = a ^ b }
  else { r = a & b }
  r = r & maskw(w)
  if opc == 3 {
    NF = (r >> (w - 1)) & 1
    ZF = r == 0
    CF = 0
    VF = 0
  }
  xset(bf(ins, 0, 5), r)
}

fn do_addsub_shift(ins: int) {
  let is64 = bf(ins, 31, 1)
  let w = 64
  if is64 == 0 { w = 32 }
  let b = shf(xget(bf(ins, 16, 5)), bf(ins, 22, 2), bf(ins, 10, 6), w)
  let r = addsub_exec(ins, xget(bf(ins, 5, 5)), b, is64, bf(ins, 29, 1))
  xset(bf(ins, 0, 5), r)
}

# option 000 UXTB, 001 UXTH, 010 UXTW, 011 LSL/UXTX, 100 SXTB, 101 SXTH,
# 110 SXTW, 111 SXTX.
fn ext_reg(v: int, option: int, amt: int) -> int {
  let r = v
  if option == 0 { r = v & 0xFF }
  else if option == 1 { r = v & 0xFFFF }
  else if option == 2 { r = v & M32 }
  else if option == 4 { r = sx(v & 0xFF, 8) }
  else if option == 5 { r = sx(v & 0xFFFF, 16) }
  else if option == 6 { r = sx(v & M32, 32) }
  return r << amt
}

fn do_addsub_ext(ins: int) {
  if bf(ins, 22, 2) != 0 { bad(ins) }
  let is64 = bf(ins, 31, 1)
  let w = 64
  if is64 == 0 { w = 32 }
  let b = ext_reg(xget(bf(ins, 16, 5)), bf(ins, 13, 3), bf(ins, 10, 3))
  let setflags = bf(ins, 29, 1)
  let rd = bf(ins, 0, 5)
  let r = addsub_exec(ins, sp_get(bf(ins, 5, 5)), b, is64, setflags)
  if setflags == 0 && rd == 31 { SP = r } else { xset(rd, r) }
}

fn do_csel(ins: int) {
  let is64 = bf(ins, 31, 1)
  let w = 64
  if is64 == 0 { w = 32 }
  let op = bf(ins, 30, 1)
  let op2 = bf(ins, 10, 2)
  let n = xget(bf(ins, 5, 5)) & maskw(w)
  let m = xget(bf(ins, 16, 5)) & maskw(w)
  let r = 0
  if cond_ok(bf(ins, 12, 4)) == 1 {
    r = n
  } else if op == 0 && op2 == 0 {
    r = m                                   # CSEL
  } else if op == 0 && op2 == 1 {
    r = m + 1                               # CSINC
  } else if op == 1 && op2 == 0 {
    r = (~m) & maskw(w)                     # CSINV
  } else {
    r = (0 - m) & maskw(w)                  # CSNEG
  }
  xset(bf(ins, 0, 5), r & maskw(w))
}

fn do_ccmp(ins: int, immediate: int) {
  let is64 = bf(ins, 31, 1)
  let w = 64
  if is64 == 0 { w = 32 }
  let op = bf(ins, 30, 1)                   # 1 CCMP, 0 CCMN
  let rn = bf(ins, 5, 5)
  let nzcv = bf(ins, 0, 4)
  if cond_ok(bf(ins, 12, 4)) == 1 {
    let b = 0
    if immediate == 1 { b = bf(ins, 16, 5) } else { b = xget(bf(ins, 16, 5)) }
    if op == 1 { subf(xget(rn), b, 1, w) } else { addf(xget(rn), b, 0, w) }
  } else {
    NF = (nzcv >> 3) & 1
    ZF = (nzcv >> 2) & 1
    CF = (nzcv >> 1) & 1
    VF = nzcv & 1
  }
}

# ---------------------------------------------------------------- arithmetic

fn udiv(a: int, b: int, w: int) -> int {
  let m = maskw(w)
  let x = a & m
  let y = b & m
  if y == 0 { return 0 }
  if x >= 0 && y >= 0 { return x / y }
  let q = 0
  let r = 0
  let i = w - 1
  while i >= 0 {
    let top = (r >> (w - 1)) & 1
    r = ((r << 1) | ((x >> i) & 1)) & m
    if top == 1 || ult(r, y) == 0 {
      r = (r - y) & m
      q = q | (1 << i)
    }
    i = i - 1
  }
  return q
}

fn sdiv(a: int, b: int, w: int) -> int {
  if b == 0 { return 0 }
  if w == 32 {
    a = sx(a, 32)
    b = sx(b, 32)
  }
  let neg = 0
  if a < 0 { a = 0 - a; neg = neg ^ 1 }
  if b < 0 { b = 0 - b; neg = neg ^ 1 }
  let q = udiv(a, b, w)
  if neg == 1 { q = (0 - q) & maskw(w) }
  return q
}

fn do_dp2(ins: int) {
  let is64 = bf(ins, 31, 1)
  let w = 64
  if is64 == 0 { w = 32 }
  let op = bf(ins, 10, 6)
  let a = xget(bf(ins, 5, 5))
  let b = xget(bf(ins, 16, 5))
  let r = 0
  if op == 2 { r = udiv(a, b, w) }
  else if op == 3 { r = sdiv(a, b, w) }
  else if op == 8 { r = lsl(a, b, w) }
  else if op == 9 { r = lsr(a, b, w) }
  else if op == 10 { r = asr(a, b, w) }
  else if op == 11 { r = ror(a, b, w) }
  else { bad(ins) }
  xset(bf(ins, 0, 5), r & maskw(w))
}

fn rbit(v: int, w: int) -> int {
  let r = 0
  let i = 0
  while i < w {
    r = (r << 1) | ((v >> i) & 1)
    i = i + 1
  }
  return r
}

fn rev_bytes(v: int, n: int) -> int {
  let r = 0
  let i = 0
  while i < n {
    r = (r << 8) | ((v >> (8 * i)) & 0xFF)
    i = i + 1
  }
  return r
}

fn rev16(v: int, w: int) -> int {
  let r = 0
  let i = 0
  while i < w {
    let lane = (v >> i) & 0xFFFF
    r = r | (rev_bytes(lane, 2) << i)
    i = i + 16
  }
  return r
}

fn rev32(v: int) -> int {
  let r = 0
  let i = 0
  while i < 64 {
    let lane = (v >> i) & M32
    r = r | (rev_bytes(lane, 4) << i)
    i = i + 32
  }
  return r
}

fn clz(v: int, w: int) -> int {
  let i = w - 1
  let c = 0
  while i >= 0 {
    if (v >> i) & 1 { return c }
    c = c + 1
    i = i - 1
  }
  return w
}

fn cls(v: int, w: int) -> int {
  let sign = (v >> (w - 1)) & 1
  let i = w - 2
  let c = 0
  while i >= 0 {
    if ((v >> i) & 1) != sign { return c }
    c = c + 1
    i = i - 1
  }
  return w - 1
}

fn do_dp1(ins: int) {
  let is64 = bf(ins, 31, 1)
  let w = 64
  if is64 == 0 { w = 32 }
  let op = bf(ins, 10, 6)
  let v = xget(bf(ins, 5, 5)) & maskw(w)
  let r = 0
  if op == 0 { r = rbit(v, w) }
  else if op == 1 { r = rev16(v, w) }
  else if op == 2 { r = rev32(v) }
  else if op == 3 { r = rev_bytes(v, w / 8) }
  else if op == 4 { r = clz(v, w) }
  else if op == 5 { r = cls(v, w) }
  else { bad(ins) }
  xset(bf(ins, 0, 5), r & maskw(w))
}

fn umulh(a: int, b: int) -> int {
  let a0 = a & M32
  let a1 = (a >> 32) & M32
  let b0 = b & M32
  let b1 = (b >> 32) & M32
  let p00 = a0 * b0
  let p01 = a0 * b1
  let p10 = a1 * b0
  let p11 = a1 * b1
  # p01*2^32 + p10*2^32 + p00 = (p11 lane) plus `mid` copies of 2^64.
  let low = (p01 & M32) + (p10 & M32) + ((p00 >> 32) & M32)
  let carry = low >> 32
  let mid = ((p01 >> 32) & M32) + ((p10 >> 32) & M32) + carry
  return p11 + mid
}

fn smulh(a: int, b: int) -> int {
  let h = umulh(a, b)
  if a < 0 { h = h - b }
  if b < 0 { h = h - a }
  return h
}

fn do_dp3(ins: int) {
  let is64 = bf(ins, 31, 1)
  let w = 64
  if is64 == 0 { w = 32 }
  let op31 = bf(ins, 21, 3)
  let o0 = bf(ins, 15, 1)
  let a = xget(bf(ins, 5, 5))
  let b = xget(bf(ins, 16, 5))
  let acc = xget(bf(ins, 10, 5)) & maskw(w)
  let r = 0
  if op31 == 0 {                                  # MADD / MSUB
    let p = (a * b) & maskw(w)
    if o0 == 0 { r = acc + p } else { r = acc - p }
  } else if op31 == 1 {                           # SMADDL / SMSUBL
    let p = sx(a, 32) * sx(b, 32)
    if o0 == 0 { r = acc + p } else { r = acc - p }
  } else if op31 == 2 && o0 == 0 {                # SMULH
    r = smulh(a, b)
  } else if op31 == 5 {                           # UMADDL / UMSUBL
    let p = (a & M32) * (b & M32)
    if o0 == 0 { r = acc + p } else { r = acc - p }
  } else if op31 == 6 && o0 == 0 {                # UMULH
    r = umulh(a, b)
  } else {
    bad(ins)
  }
  xset(bf(ins, 0, 5), r & maskw(w))
}

# ---------------------------------------------------------------- load/store forms

fn do_ldst_uimm(ins: int) {
  let size = bf(ins, 30, 2)
  let opc = bf(ins, 22, 2)
  let rt = bf(ins, 0, 5)
  let vec = bf(ins, 26, 1)
  # A 128-bit vector access has size 0 but scales its immediate by 16.
  let scale = size
  if vec == 1 && size == 0 { scale = 4 }
  let addr = sp_get(bf(ins, 5, 5)) + (bf(ins, 10, 12) << scale)
  if vec == 1 {
    # opc 10 = 128-bit store (STR Q), 11 = 128-bit load (LDR Q).
    if size == 0 && opc == 3 { q_load(rt, addr); return }
    if size == 0 && opc == 2 { q_store(rt, addr); return }
    unsup("SIMD/FP load or store", ins)
  }
  ldst(size, opc, rt, addr)
}

fn do_ldst_unscaled(ins: int) {
  let size = bf(ins, 30, 2)
  let opc = bf(ins, 22, 2)
  let op2 = bf(ins, 10, 2)
  let rn = bf(ins, 5, 5)
  let rt = bf(ins, 0, 5)
  if bf(ins, 26, 1) == 1 { unsup("SIMD/FP load or store", ins) }
  let base = sp_get(rn)
  let off = sx(bf(ins, 12, 9), 9)
  let addr = base + off
  if op2 == 1 { addr = base }          # post-index accesses at the old base
  ldst(size, opc, rt, addr)
  if op2 == 1 || op2 == 3 { sp_set(rn, base + off) }
}

fn do_ldst_reg(ins: int) {
  let size = bf(ins, 30, 2)
  let opc = bf(ins, 22, 2)
  let rt = bf(ins, 0, 5)
  let vec = bf(ins, 26, 1)
  if vec == 1 { unsup("SIMD/FP load or store", ins) }
  let off = ext_reg(xget(bf(ins, 16, 5)), bf(ins, 13, 3), 0)
  if bf(ins, 12, 1) == 1 { off = off << size }
  ldst(size, opc, rt, sp_get(bf(ins, 5, 5)) + off)
}

fn do_ldlit(ins: int) {
  let opc = bf(ins, 31, 2)
  let rt = bf(ins, 0, 5)
  let addr = PC - 4 + (sx(bf(ins, 5, 19), 19) << 2)
  if opc == 0 { xset(rt, rd32(addr)) }
  else if opc == 1 { xset(rt, rd64(addr)) }
  else if opc == 2 { xset(rt, sx(rd32(addr), 32)) }
  # opc == 3 is PRFM.
}

fn do_ldstp(ins: int) {
  let opc = bf(ins, 30, 2)
  let vec = bf(ins, 26, 1)
  let mode = bf(ins, 23, 2)
  let load = bf(ins, 22, 1)
  let rt2 = bf(ins, 10, 5)
  let rn = bf(ins, 5, 5)
  let rt = bf(ins, 0, 5)
  if mode == 0 { bad(ins) }
  let scale = 8
  if vec == 1 {
    if opc != 2 { unsup("SIMD/FP load or store pair", ins) }
    scale = 16
  } else if opc == 0 {
    scale = 4
  } else if opc != 2 {
    unsup("load/store pair size", ins)
  }
  let base = sp_get(rn)
  let off = sx(bf(ins, 15, 7), 7) * scale
  let addr = base + off
  if mode == 1 { addr = base }
  if load == 1 {
    if vec == 1 {
      q_load(rt, addr)
      q_load(rt2, addr + 16)
    } else if opc == 0 {
      xset(rt, rd32(addr))
      xset(rt2, rd32(addr + 4))
    } else {
      xset(rt, rd64(addr))
      xset(rt2, rd64(addr + 8))
    }
  } else {
    if vec == 1 {
      q_store(rt, addr)
      q_store(rt2, addr + 16)
    } else if opc == 0 {
      wr32(addr, xget(rt))
      wr32(addr + 4, xget(rt2))
    } else {
      wr64(addr, xget(rt))
      wr64(addr + 8, xget(rt2))
    }
  }
  if mode == 1 || mode == 3 { sp_set(rn, base + off) }
}

# ---------------------------------------------------------------- dispatch

fn step(ins: int) {
  if (ins & 0xFFE0001F) == 0xD4000001 { do_syscall(); return }   # SVC
  if (ins & 0x7C000000) == 0x14000000 { do_b(ins); return }      # B / BL
  if (ins & 0xFF000010) == 0x54000000 { do_bcond(ins); return }  # B.cond
  if (ins & 0x7E000000) == 0x34000000 { do_cbz(ins); return }    # CBZ / CBNZ
  if (ins & 0x7E000000) == 0x36000000 { do_tbz(ins); return }    # TBZ / TBNZ
  if (ins & 0xFE000000) == 0xD6000000 { do_br(ins); return }     # BR / BLR / RET
  if (ins & 0xFF800000) == 0xD5000000 { do_system(ins); return } # hints, MRS/MSR

  if (ins & 0x1F000000) == 0x10000000 { do_adr(ins); return }
  if (ins & 0x1F000000) == 0x11000000 { do_addsub_imm(ins); return }
  if (ins & 0x1F800000) == 0x12000000 { do_logical_imm(ins); return }
  if (ins & 0x1F800000) == 0x12800000 { do_movewide(ins); return }
  if (ins & 0x1F800000) == 0x13000000 { do_bitfield(ins); return }
  if (ins & 0x1F800000) == 0x13800000 { do_extract(ins); return }

  if (ins & 0x1F000000) == 0x0A000000 { do_logical_reg(ins); return }
  if (ins & 0x1F200000) == 0x0B000000 { do_addsub_shift(ins); return }
  if (ins & 0x1F200000) == 0x0B200000 { do_addsub_ext(ins); return }
  if (ins & 0x1FE00000) == 0x1A800000 { do_csel(ins); return }
  if (ins & 0x1FE00800) == 0x1A400800 { do_ccmp(ins, 1); return }
  if (ins & 0x1FE00800) == 0x1A400000 { do_ccmp(ins, 0); return }
  if (ins & 0x1FE00000) == 0x1AC00000 { do_dp2(ins); return }
  if (ins & 0x5FE00000) == 0x5AC00000 { do_dp1(ins); return }
  if (ins & 0x1F000000) == 0x1B000000 { do_dp3(ins); return }

  if (ins & 0x3B000000) == 0x18000000 { do_ldlit(ins); return }
  if (ins & 0x3A000000) == 0x28000000 { do_ldstp(ins); return }
  if (ins & 0x3B000000) == 0x39000000 { do_ldst_uimm(ins); return }
  if (ins & 0x3B200C00) == 0x38200800 { do_ldst_reg(ins); return }
  if (ins & 0x3B200000) == 0x38000000 { do_ldst_unscaled(ins); return }

  bad(ins)
}

fn run(entry: int) {
  PC = entry
  while 1 {
    AT = PC
    let ins = fetch32(PC)
    PC = PC + 4
    TICKS = TICKS + 1
    step(ins)
  }
}
