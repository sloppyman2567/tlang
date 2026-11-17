# tchip8 -- a CHIP-8 interpreter with a text framebuffer.
#
#   tchip8 ROM [cycles] [keys]
#
# ROM is loaded at 0x200. `cycles` defaults to 100000; the interpreter runs
# that many instructions, then prints the 64x32 display using '#' and '.'.
# `keys` is an optional decimal bitmask of held keys (bit 0 = key 0).
#
# CHIP-8 has no clock and no exit instruction, so time is instruction-counted:
# the delay and sound timers tick once every ten instructions. The display is
# rendered once at the end; a game that needs a frame per tick can be run in
# slices. FX0A (wait for key) uses the bitmask and halts when no key is held.
# FX55/FX65 leave I unchanged, and 8XY6/8XYE shift VX in place (the original
# CHIP-8 behaviour, not the SCHIP VY variant).

let MEM = alloc(4096)
let V = alloc(16)
let STACK = alloc(16)
let KEYS = alloc(16)
let DISP = alloc(2048)

let PC = 0x200
let I = 0
let SP = 0
let DT = 0
let ST = 0
let SEED = 0x1357
let TICKS = 0
let HALTED = 0

# X11 state. The protocol buffers are plain strings, so they can hold NULs.
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
let XGC = 0
let XGCB = 0
let XWM_NAME = 0
let XWM_CLASS = 0
let XWM_PROTOCOLS = 0
let XWM_DELETE = 0

# One reusable row: writing 64 bytes and one print per row beats 2048 syscalls.
let ROWS = slice("................................................................", 0, 64)

# The 4x5 hex digits as bytes.  A string literal is 80 bytes of assembler
# data; an int array literal would cost a store for every element.
let FONT = "\xf0\x90\x90\x90\xf0\x20\x60\x20\x20\x70\xf0\x10\xf0\x80\xf0\xf0\x10\xf0\x10\xf0\x90\x90\xf0\x10\x10\xf0\x80\xf0\x10\xf0\xf0\x80\xf0\x90\xf0\xf0\x10\x20\x40\x40\xf0\x90\xf0\x90\xf0\xf0\x90\xf0\x10\xf0\xf0\x90\xf0\x90\x90\xe0\x90\xe0\x90\xe0\xf0\x80\x80\x80\xf0\xe0\x90\x90\x90\xe0\xf0\x80\xf0\x80\xf0\xf0\x80\xf0\x80\x80"

fn load_font() {
  let i = 0
  while i < 80 {
    MEM[0x50 + i] = FONT[i]
    i++
  }
}

fn load_rom(path: str) -> int {
  # len() stops at the first NUL, and a ROM is full of them, so ask the file
  # for its real size and index that many bytes of the read_file buffer.
  let n = file_size(path)
  if n == 0 { return 0 }
  let rom = read_file(path)
  if n > 0xE00 { n = 0xE00 }
  let i = 0
  while i < n {
    MEM[0x200 + i] = rom[i] & 0xFF
    i++
  }
  return 1
}

fn set_keys(mask: int) {
  let i = 0
  while i < 16 {
    KEYS[i] = (mask >> i) & 1
    i++
  }
}

fn first_key() -> int {
  let i = 0
  while i < 16 {
    if KEYS[i] != 0 { return i }
    i++
  }
  return -1
}

fn rnd() -> int {
  SEED = (SEED * 1103515245 + 12345) & 0x7FFFFFFF
  return (SEED >> 16) & 0xFF
}

fn clear_display() {
  let i = 0
  while i < 2048 {
    DISP[i] = 0
    i++
  }
}

fn draw(x: int, y: int, h: int) {
  if h == 0 { h = 16 }
  V[0xF] = 0
  let row = 0
  while row < h {
    let sprite = MEM[I + row]
    let bit = 0
    while bit < 8 {
      if sprite & (0x80 >> bit) {
        let px = (x + bit) & 63
        let py = (y + row) & 31
        let at = py * 64 + px
        if DISP[at] == 1 {
          DISP[at] = 0
          V[0xF] = 1
        } else {
          DISP[at] = 1
        }
      }
      bit++
    }
    row++
  }
}

fn step() {
  if HALTED != 0 { return }
  # Fetch inline: a call per instruction costs more than the two loads it wraps.
  let op = (MEM[PC] << 8) | MEM[PC + 1]
  PC = PC + 2
  let x = (op >> 8) & 0xF

  switch op & 0xF000 {
    case 0x0000 {
      if op == 0x00E0 {
        clear_display()
      } else if op == 0x00EE {
        SP = SP - 1
        PC = STACK[SP]
      }
    }
    case 0x1000 { let nnn = op & 0x0FFF; PC = nnn }
    case 0x2000 {
      let nnn = op & 0x0FFF
      STACK[SP] = PC
      SP = SP + 1
      PC = nnn
    }
    case 0x3000 { let nn = op & 0xFF; if V[x] == nn { PC = PC + 2 } }
    case 0x4000 { let nn = op & 0xFF; if V[x] != nn { PC = PC + 2 } }
    case 0x5000 { let y = (op >> 4) & 0xF; if V[x] == V[y] { PC = PC + 2 } }
    case 0x6000 { let nn = op & 0xFF; V[x] = nn }
    case 0x7000 { let nn = op & 0xFF; V[x] = (V[x] + nn) & 0xFF }
    case 0x8000 {
      let y = (op >> 4) & 0xF
      let n = op & 0xF
      switch n {
        case 0x0 { V[x] = V[y] }
        case 0x1 { V[x] = V[x] | V[y] }
        case 0x2 { V[x] = V[x] & V[y] }
        case 0x3 { V[x] = V[x] ^ V[y] }
        case 0x4 {
          let sum = V[x] + V[y]
          if sum > 255 { V[0xF] = 1 } else { V[0xF] = 0 }
          V[x] = sum & 0xFF
        }
        case 0x5 {
          if V[x] >= V[y] { V[0xF] = 1 } else { V[0xF] = 0 }
          V[x] = (V[x] - V[y]) & 0xFF
        }
        case 0x6 {
          V[0xF] = V[x] & 1
          V[x] = V[x] >> 1
        }
        case 0x7 {
          if V[y] >= V[x] { V[0xF] = 1 } else { V[0xF] = 0 }
          V[x] = (V[y] - V[x]) & 0xFF
        }
        case 0xE {
          V[0xF] = (V[x] >> 7) & 1
          V[x] = (V[x] << 1) & 0xFF
        }
      }
    }
    case 0x9000 { let y = (op >> 4) & 0xF; if V[x] != V[y] { PC = PC + 2 } }
    case 0xA000 { I = op & 0x0FFF }
    case 0xB000 { PC = (op & 0x0FFF) + V[0] }
    case 0xC000 { let nn = op & 0xFF; V[x] = rnd() & nn }
    case 0xD000 {
      let y = (op >> 4) & 0xF
      let n = op & 0xF
      draw(V[x], V[y], n)
    }
    case 0xE000 {
      let nn = op & 0xFF
      if nn == 0x9E {
        if KEYS[x] != 0 { PC = PC + 2 }
      } else if nn == 0xA1 {
        if KEYS[x] == 0 { PC = PC + 2 }
      }
    }
    case 0xF000 {
      let nn = op & 0xFF
      if nn == 0x07 {
        V[x] = DT
      } else if nn == 0x0A {
        let key = first_key()
        if key < 0 { HALTED = 1 } else { V[x] = key }
      } else if nn == 0x15 {
        DT = V[x]
      } else if nn == 0x18 {
        ST = V[x]
      } else if nn == 0x1E {
        I = I + V[x]
      } else if nn == 0x29 {
        I = 0x50 + (V[x] & 0xF) * 5
      } else if nn == 0x33 {
        MEM[I] = V[x] / 100
        MEM[I + 1] = (V[x] / 10) % 10
        MEM[I + 2] = V[x] % 10
      } else if nn == 0x55 {
        let i = 0
        while i <= x {
          MEM[I + i] = V[i]
          i++
        }
      } else if nn == 0x65 {
        let i = 0
        while i <= x {
          V[i] = MEM[I + i]
          i++
        }
      }
    }
  }
}

fn run(cycles: int) {
  let i = 0
  while i < cycles {
    if HALTED != 0 { return }
    step()
    # Timer update inline: one fewer call per emulated instruction.
    TICKS = TICKS + 1
    if TICKS >= 10 {
      TICKS = 0
      if DT > 0 { DT = DT - 1 }
      if ST > 0 { ST = ST - 1 }
    }
    i++
  }
}

fn render() {
  let y = 0
  while y < 32 {
    let x = 0
    while x < 64 {
      if DISP[y * 64 + x] == 1 {
        ROWS[x] = 35
      } else {
        ROWS[x] = 46
      }
      x++
    }
    print(ROWS)
    print("\n")
    y++
  }
}

# Clear and home the terminal before a frame so animation replaces the last
# one instead of scrolling. Only used when the caller asks for frame mode.
fn render_frame() {
  print("\e[2J\e[H")
  render()
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

# Read one variable from /proc/self/environ without libc's getenv.
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
    if ok == 1 {
      if e[i + kl] == 61 {
        let s = i + kl + 1
        let end = s
        while end < 4096 && e[end] != 0 { end++ }
        return slice(e, s, end - s)
      }
    }
    while i < 4096 && e[i] != 0 { i++ }
    i++
  }
  return ""
}

# Parse ~/.Xauthority (big-endian length fields) and keep display :0's cookie.
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

  # 12-byte setup header, then the auth name and the cookie, both padded.
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
  XGC = base + 2
  XGCB = base + 3
  return 1
}

# InternAtom + ChangeProperty are enough to give the window a title, a class,
# and the WM_DELETE_WINDOW close protocol. STRING and ATOM are predefined.
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

# ChangeProperty reads its payload from XBUF+24 and pads it to four bytes.
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

  if XWM_NAME != 0 {
    let name = "tchip8"
    let i = 0
    while i < len(name) {
      XBUF[24 + i] = name[i]
      i++
    }
    x_prop(XWM_NAME, 31, 8, len(name))
  }
  if XWM_CLASS != 0 {
    let cls = "tchip8"
    let i = 0
    while i < len(cls) {
      XBUF[24 + i] = cls[i]
      XBUF[31 + i] = cls[i]
      i++
    }
    XBUF[30] = 0
    XBUF[37] = 0
    x_prop(XWM_CLASS, 31, 8, 14)
  }
  if XWM_PROTOCOLS != 0 && XWM_DELETE != 0 {
    put32(XBUF, 24, XWM_DELETE)
    x_prop(XWM_PROTOCOLS, 4, 32, 1)
  }
}

fn x_create() {
  # CreateWindow: 512x256, black background, expose/key events.
  put8(XBUF, 0, 1)
  put8(XBUF, 1, XDEPTH)
  put16(XBUF, 2, 10)
  put32(XBUF, 4, XWIN)
  put32(XBUF, 8, XROOT)
  put16(XBUF, 12, 0)
  put16(XBUF, 14, 0)
  put16(XBUF, 16, 512)
  put16(XBUF, 18, 256)
  put16(XBUF, 20, 0)
  put16(XBUF, 22, 1)
  put32(XBUF, 24, XVISUAL)
  put32(XBUF, 28, 0x802)
  put32(XBUF, 32, 0)
  put32(XBUF, 36, 0x28003)
  fd_write(XFD, XBUF, 40)

  # CreateGC: green foreground, black background.
  put8(XBUF, 0, 55)
  put8(XBUF, 1, 0)
  put16(XBUF, 2, 6)
  put32(XBUF, 4, XGC)
  put32(XBUF, 8, XWIN)
  put32(XBUF, 12, 12)
  put32(XBUF, 16, 0x00FF66)
  put32(XBUF, 20, 0)
  fd_write(XFD, XBUF, 24)

  # A second GC with a black foreground clears the frame.
  put8(XBUF, 0, 55)
  put8(XBUF, 1, 0)
  put16(XBUF, 2, 6)
  put32(XBUF, 4, XGCB)
  put32(XBUF, 8, XWIN)
  put32(XBUF, 12, 12)
  put32(XBUF, 16, 0)
  put32(XBUF, 20, 0)
  fd_write(XFD, XBUF, 24)

  x_wm()

  # MapWindow.
  put8(XBUF, 0, 8)
  put8(XBUF, 1, 0)
  put16(XBUF, 2, 2)
  put32(XBUF, 4, XWIN)
  fd_write(XFD, XBUF, 8)
}

fn x_draw() {
  # Clear the whole window with the black GC, then paint lit cells green.
  put8(XBUF, 0, 70)
  put8(XBUF, 1, 0)
  put16(XBUF, 2, 5)
  put32(XBUF, 4, XWIN)
  put32(XBUF, 8, XGCB)
  put16(XBUF, 12, 0)
  put16(XBUF, 14, 0)
  put16(XBUF, 16, 512)
  put16(XBUF, 18, 256)
  fd_write(XFD, XBUF, 20)

  put8(XBUF, 0, 70)
  put8(XBUF, 1, 0)
  put32(XBUF, 4, XWIN)
  put32(XBUF, 8, XGC)
  let off = 12
  let count = 0
  let y = 0
  while y < 32 {
    let x = 0
    while x < 64 {
      if DISP[y * 64 + x] == 1 {
        put16(XBUF, off, x * 8)
        put16(XBUF, off + 2, y * 8)
        put16(XBUF, off + 4, 8)
        put16(XBUF, off + 6, 8)
        off = off + 8
        count = count + 1
      }
      x++
    }
    y++
  }
  if count > 0 {
    put16(XBUF, 2, (12 + count * 8) / 4)
    fd_write(XFD, XBUF, 12 + count * 8)
  }
}

# Standard X keycodes for the CHIP-8 hex keypad.
fn key_index(code: int) -> int {
  if code == 10 { return 1 }
  if code == 11 { return 2 }
  if code == 12 { return 3 }
  if code == 13 { return 12 }
  if code == 24 { return 4 }
  if code == 25 { return 5 }
  if code == 26 { return 6 }
  if code == 27 { return 13 }
  if code == 38 { return 7 }
  if code == 39 { return 8 }
  if code == 40 { return 9 }
  if code == 41 { return 14 }
  if code == 52 { return 10 }
  if code == 53 { return 0 }
  if code == 54 { return 11 }
  if code == 55 { return 15 }
  if code == 19 { return 0 }
  return -1
}

fn x_event(ev: str) {
  let t = ev[0] & 0x7F
  if t == 2 {
    let k = key_index(ev[1])
    if k >= 0 { KEYS[k] = 1 }
  } else if t == 3 {
    let k = key_index(ev[1])
    if k >= 0 { KEYS[k] = 0 }
  } else if t == 12 {
    x_draw()
  } else if t == 17 {
    HALTED = 1
  } else if t == 33 {
    # A ClientMessage is only a close request if the WM sent WM_DELETE_WINDOW.
    if get32(ev, 8) == XWM_PROTOCOLS && get32(ev, 12) == XWM_DELETE {
      HALTED = 1
    }
  }
}

fn run_x11() -> int {
  if x_connect() == 0 { return 0 }
  x_create()
  x_draw()
  while HALTED == 0 {
    let rev = fd_poll(XFD, 0)
    while rev != 0 {
      let n = fd_read(XFD, XEV, 32)
      if n != 32 {
        HALTED = 1
        break
      }
      x_event(XEV)
      rev = fd_poll(XFD, 0)
    }
    if HALTED != 0 { break }
    run(8)
    x_draw()
    fd_poll(XFD, 16)
  }
  return 1
}

fn main() {
  if argc() < 2 {
    print("usage: tchip8 ROM [cycles] [keys] [frame]\n")
    print("       tchip8 ROM x11\n")
    print("\n")
    print("  cycles: instructions to run (default 100000)\n")
    print("  keys:   decimal bitmask of held keys, bit 0 = key 0\n")
    print("  frame:  redraw every N instructions (default: once at the end)\n")
    print("  x11:    open a 512x256 window with live keyboard input\n")
    exit(2)
  }
  load_font()
  if load_rom(argv(1)) == 0 {
    print_err("tchip8: cannot read ")
    print_err(argv(1))
    print_err("\n")
    exit(2)
  }
  if argc() > 2 && str_eq(argv(2), "x11") == 1 {
    set_keys(0)
    if run_x11() == 0 {
      print_err("tchip8: cannot open an X11 window\n")
      exit(2)
    }
    exit(0)
  }
  if argc() > 3 {
    set_keys(int(argv(3)))
  }
  let cycles = 100000
  if argc() > 2 {
    cycles = int(argv(2))
    if cycles <= 0 { cycles = 100000 }
  }
  let frame = 0
  if argc() > 4 {
    frame = int(argv(4))
  }
  if frame > 0 {
    let done = 0
    while done < cycles {
      let chunk = frame
      if done + chunk > cycles { chunk = cycles - done }
      run(chunk)
      render_frame()
      done = done + chunk
      if HALTED != 0 { break }
    }
  } else {
    run(cycles)
    render()
  }
}
