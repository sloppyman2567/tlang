# machine.tl -- guest address space and architectural state.
#
# The guest sees one flat, little-endian address space that starts at the
# conventional Linux link address for `-static -nostdlib` binaries. Guest
# pointers are therefore real addresses: the loader copies segments straight
# to `BASE + p_vaddr`, and no relocation or page table is involved.
#
# Memory is a single 16 MiB byte buffer. `.data`/`.bss` for the test programs
# live just above BASE, the heap grows up from the end of the image, and the
# stack is pinned in the last MiB of the address space.

let M32 = 0xFFFFFFFF

let BASE = 0x400000
let MEM_BYTES = 16 * 1024 * 1024
let MEM_TOP = BASE + MEM_BYTES
let MEM = newbuf(MEM_BYTES)

# 64-bit general-purpose registers. X[31] is never used: register 31 is XZR
# or SP depending on the instruction, so the accessors below decide.
let X = alloc(32)

# The 32 SIMD registers are only storage for the 128-bit load/store pairs that
# GCC uses to copy small blocks. No arithmetic reads them, so they are bytes in
# a buffer rather than interpreted values.
let Q = newbuf(32 * 16)

let SP = 0
let PC = 0
let AT = 0          # address of the instruction being executed, for diagnostics
let TICKS = 0       # instruction counter, exposed as CNTVCT_EL0
let NF = 0          # condition flags: negative, zero, carry, overflow
let ZF = 0
let CF = 0
let VF = 0
let BRK = 0         # program break, and the bump pointer for mmap
let HEAP_LIMIT = MEM_TOP - 0x100000
let STACK_TOP = MEM_TOP

fn maskw(w: int) -> int {
  if w >= 64 { return -1 }
  return (1 << w) - 1
}

fn sx(v: int, width: int) -> int {
  if width >= 64 { return v }
  let m = 1 << (width - 1)
  let x = v & maskw(width)
  if x & m { return x - (1 << width) }
  return x
}

fn hex(v: int) -> str {
  let i = 60
  let started = 0
  let out = ""
  while i >= 0 {
    let d = (v >> i) & 15
    if d != 0 || started == 1 || i == 0 {
      out = out + slice("0123456789abcdef", d, 1)
      started = 1
    }
    i = i - 4
  }
  return out
}

fn die(msg: str) {
  print_err("taarch64: " + msg + "\n")
  exit(2)
}

fn mem_fail(what: str, addr: int) {
  die(what + " at pc 0x" + hex(AT) + ", addr 0x" + hex(addr))
}

fn mem_ok(addr: int, n: int) -> int {
  if n < 0 { return 0 }
  if n > MEM_BYTES { return 0 }
  if addr < BASE { return 0 }
  if addr > MEM_TOP - n { return 0 }
  return 1
}

fn rd8(addr: int) -> int {
  if mem_ok(addr, 1) == 0 { mem_fail("load outside guest memory", addr) }
  return MEM[addr - BASE]
}

fn rd16(addr: int) -> int {
  if mem_ok(addr, 2) == 0 { mem_fail("load outside guest memory", addr) }
  let o = addr - BASE
  return MEM[o] | (MEM[o + 1] << 8)
}

fn rd32(addr: int) -> int {
  if mem_ok(addr, 4) == 0 { mem_fail("load outside guest memory", addr) }
  let o = addr - BASE
  return MEM[o] | (MEM[o + 1] << 8) | (MEM[o + 2] << 16) | (MEM[o + 3] << 24)
}

fn rd64(addr: int) -> int {
  if mem_ok(addr, 8) == 0 { mem_fail("load outside guest memory", addr) }
  let lo = rd32(addr)
  let hi = rd32(addr + 4)
  return lo | (hi << 32)
}

fn wr8(addr: int, v: int) {
  if mem_ok(addr, 1) == 0 { mem_fail("store outside guest memory", addr) }
  MEM[addr - BASE] = v & 0xFF
}

fn wr16(addr: int, v: int) {
  if mem_ok(addr, 2) == 0 { mem_fail("store outside guest memory", addr) }
  let o = addr - BASE
  MEM[o] = v & 0xFF
  MEM[o + 1] = (v >> 8) & 0xFF
}

fn wr32(addr: int, v: int) {
  if mem_ok(addr, 4) == 0 { mem_fail("store outside guest memory", addr) }
  let o = addr - BASE
  MEM[o] = v & 0xFF
  MEM[o + 1] = (v >> 8) & 0xFF
  MEM[o + 2] = (v >> 16) & 0xFF
  MEM[o + 3] = (v >> 24) & 0xFF
}

fn wr64(addr: int, v: int) {
  if mem_ok(addr, 8) == 0 { mem_fail("store outside guest memory", addr) }
  wr32(addr, v & M32)
  wr32(addr + 4, (v >> 32) & M32)
}

fn fetch32(addr: int) -> int {
  if mem_ok(addr, 4) == 0 { mem_fail("instruction fetch outside guest memory", addr) }
  let o = addr - BASE
  return MEM[o] | (MEM[o + 1] << 8) | (MEM[o + 2] << 16) | (MEM[o + 3] << 24)
}

# Register 31 reads as zero and discards writes in every data-processing
# instruction; the SP forms in exec.tl use sp_get/sp_set instead.
fn xget(r: int) -> int {
  if r == 31 { return 0 }
  return X[r]
}

fn xset(r: int, v: int) {
  if r != 31 { X[r] = v }
}

fn sp_get(r: int) -> int {
  if r == 31 { return SP }
  return X[r]
}

fn sp_set(r: int, v: int) {
  if r == 31 { SP = v } else { X[r] = v }
}

fn q_load(r: int, addr: int) {
  if mem_ok(addr, 16) == 0 { mem_fail("load outside guest memory", addr) }
  let i = 0
  while i < 16 {
    Q[r * 16 + i] = MEM[addr - BASE + i]
    i = i + 1
  }
}

fn q_store(r: int, addr: int) {
  if mem_ok(addr, 16) == 0 { mem_fail("store outside guest memory", addr) }
  let i = 0
  while i < 16 {
    MEM[addr - BASE + i] = Q[r * 16 + i]
    i = i + 1
  }
}
