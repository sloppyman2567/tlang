# twayland -- a minimal Wayland client as an importable module.
#
#   import "Modules/twayland.tl"
#
#   fn main() {
#     if tw_open(512, 256, "tw") == 0 { print("no compositor\n") return }
#     tw_clear(0x101820)
#     tw_rect(16, 16, 64, 64, 0x40c060)
#     tw_present()
#   }
#
# A window is an xdg_toplevel whose pixels live in a memfd handed to the
# compositor with SCM_RIGHTS; frames are written into the pool with fd_pwrite
# and presented with attach/damage/commit, double buffered so a frame is never
# written while the compositor still owns it. The window closes when the
# compositor sends xdg_toplevel.close.
#
# Input comes from wl_seat. tw_poll(ms) returns one event at a time: 0 on
# timeout, 1 for a key, 2 for pointer motion, 3 for a button, 4 for any other
# event and -1 once the window is closed. TW_KEY/TW_KEY_STATE, TW_MOUSE_X/Y and
# TW_BUTTON/TW_BUTTON_STATE carry that event's data, and the TW_*_EVENTS
# counters count everything seen. Key and button events read while tw_present
# waits for a buffer are queued, so no press is lost; motion is coalesced to
# the latest position. Keys are Linux evdev codes (q = 16, Esc = 1, arrows =
# 103-108).

# ---------------------------------------------------------------- wire format

let TW_FD = -1
let TW_W = 0
let TW_H = 0
let TW_STRIDE = 0
let TW_NID = 2          # next client object id; the display is 1
let TW_OUT = newbuf(4096)
let TW_OP = 0
let TW_HO = 0
let TW_HDR = newbuf(8)
let TW_PL = newbuf(4096)

let TW_REG = 0
let TW_COMP = 0
let TW_SHM = 0
let TW_WM = 0
let TW_SURF = 0
let TW_XSURF = 0
let TW_TOP = 0
let TW_POOL = 0
let TW_CB = 0
let TW_BUF0 = 0
let TW_BUF1 = 0
let TW_FDS = -1
let TW_CFG = 0
let TW_CONFIGURED = 0
let TW_GOT_CB = 0
let TW_CLOSED = 0
let TW_ERR = 0
let TW_FRAME = 0
let TW_FREE0 = 1
let TW_FREE1 = 1
let TW_PIX = ""
let TW_FRAMES = 0
let TW_RELEASES = 0

# ---------------------------------------------------------------------- input

let TW_SEAT = 0
let TW_KB = 0
let TW_PTR = 0
let TW_CAPS = 0
let TW_KEY = 0
let TW_KEY_STATE = 0
let TW_KEY_EVENTS = 0
let TW_MOUSE_X = 0
let TW_MOUSE_Y = 0
let TW_MOUSE_EVENTS = 0
let TW_BUTTON = 0
let TW_BUTTON_STATE = 0
let TW_BUTTON_EVENTS = 0

# Discrete events are queued because tw_present services the socket too;
# pointer motion is coalesced to the latest position instead of queued.
let TW_QK = alloc(64)
let TW_QA = alloc(64)
let TW_QB = alloc(64)
let TW_QH = 0
let TW_QT = 0
let TW_QN = 0
let TW_MOTION = 0

fn tw_slen(s: str) -> int {
  let i = 0
  while s[i] != 0 {
    i = i + 1
  }
  return i
}

fn tw_match(b: str, o: int, s: str) -> int {
  let n = tw_slen(s)
  let i = 0
  while i < n {
    if b[o + i] != s[i] {
      return 0
    }
    i = i + 1
  }
  return 1
}

fn tw_pad(n: int) -> int {
  return ((n + 3) / 4) * 4
}

fn tw_put32(v: int) {
  TW_OUT[TW_OP] = v & 255
  TW_OUT[TW_OP + 1] = (v >> 8) & 255
  TW_OUT[TW_OP + 2] = (v >> 16) & 255
  TW_OUT[TW_OP + 3] = (v >> 24) & 255
  TW_OP = TW_OP + 4
}

fn tw_putstr(s: str) {
  let n = tw_slen(s)
  tw_put32(n + 1)
  let i = 0
  while i < n {
    TW_OUT[TW_OP + i] = s[i]
    i = i + 1
  }
  TW_OUT[TW_OP + n] = 0
  let total = tw_pad(n + 1)
  while i < total {
    TW_OUT[TW_OP + i] = 0
    i = i + 1
  }
  TW_OP = TW_OP + total
}

fn tw_begin(obj: int, op: int) {
  TW_OP = 0
  tw_put32(obj)
  tw_put32(0)
  TW_HO = op
}

# Header: object id, then the opcode in the high half of the next word and the
# message size in the low half. Sends the whole message, optionally carrying a
# descriptor (wl_shm.create_pool is the only message that does).
fn tw_end(pass: int) -> int {
  let n = TW_OP
  TW_OUT[4] = TW_HO & 255
  TW_OUT[5] = (TW_HO >> 8) & 255
  TW_OUT[6] = n & 255
  TW_OUT[7] = (n >> 8) & 255
  if pass >= 0 {
    return fd_send(TW_FD, TW_OUT, n, pass)
  }
  return fd_write(TW_FD, TW_OUT, n)
}

fn tw_flush() {
  tw_end(-1)
}

fn tw_rd32(b: str, o: int) -> int {
  return b[o] + (b[o + 1] << 8) + (b[o + 2] << 16) + (b[o + 3] << 24)
}

# wl_fixed_t is 24.8 fixed point; the wire value is signed 32-bit, so the high
# bit has to be unfolded before dividing.
fn tw_fixed(v: int) -> int {
  if v >= 2147483648 {
    v = v - 4294967296
  }
  return v / 256
}

fn tw_queue(kind: int, a: int, b: int) {
  if TW_QN >= 64 {
    return
  }
  TW_QK[TW_QT] = kind
  TW_QA[TW_QT] = a
  TW_QB[TW_QT] = b
  TW_QT = (TW_QT + 1) % 64
  TW_QN = TW_QN + 1
}

fn tw_take() -> int {
  let kind = TW_QK[TW_QH]
  if kind == 1 {
    TW_KEY = TW_QA[TW_QH]
    TW_KEY_STATE = TW_QB[TW_QH]
  }
  if kind == 3 {
    TW_BUTTON = TW_QA[TW_QH]
    TW_BUTTON_STATE = TW_QB[TW_QH]
  }
  TW_QH = (TW_QH + 1) % 64
  TW_QN = TW_QN - 1
  return kind
}

fn tw_new() -> int {
  let i = TW_NID
  TW_NID = TW_NID + 1
  return i
}

# ------------------------------------------------------------------ registry

fn tw_bind(name: int, iface: str, ver: int, id: int) {
  tw_begin(TW_REG, 0)
  tw_put32(name)
  tw_putstr(iface)
  tw_put32(ver)
  tw_put32(id)
  tw_flush()
}

# Bind by matching the interface name in the event payload, so a compositor
# that advertises extra globals costs us nothing. The trailing NUL is part of the
# match so "wl_shm" cannot also select a longer interface that starts the same
# way.
fn tw_global(name: int, b: str, o: int, ver: int) {
  if tw_match(b, o, "wl_shm") == 1 && b[o + 6] == 0 {
    TW_SHM = tw_new()
    tw_bind(name, "wl_shm", 1, TW_SHM)
    return
  }
  if tw_match(b, o, "wl_compositor") == 1 && b[o + 13] == 0 {
    let v = 4
    if ver < 4 {
      v = ver
    }
    TW_COMP = tw_new()
    tw_bind(name, "wl_compositor", v, TW_COMP)
    return
  }
  if tw_match(b, o, "xdg_wm_base") == 1 && b[o + 11] == 0 {
    TW_WM = tw_new()
    tw_bind(name, "xdg_wm_base", 1, TW_WM)
    return
  }
  if tw_match(b, o, "wl_seat") == 1 && b[o + 7] == 0 {
    # v4 is enough for keyboard and pointer, and it keeps wl_pointer before
    # the v5 frame event, which this module has no use for.
    let v = 4
    if ver < 4 {
      v = ver
    }
    TW_SEAT = tw_new()
    tw_bind(name, "wl_seat", v, TW_SEAT)
    return
  }
}

fn tw_dispatch(obj: int, op: int, n: int) -> int {
  if obj == 1 {
    if op == 0 {
      TW_ERR = 1
      print("twayland: protocol error: ")
      let i = 8
      while i < n {
        if TW_PL[i] == 0 {
          i = n
        } else {
          print_char(TW_PL[i])
          i = i + 1
        }
      }
      print("\n")
      return -1
    }
    return 1
  }
  if obj == TW_REG {
    if op == 0 {
      let name = tw_rd32(TW_PL, 0)
      let sl = tw_rd32(TW_PL, 4)
      let ver = tw_rd32(TW_PL, 8 + tw_pad(sl))
      tw_global(name, TW_PL, 8, ver)
    }
    return 1
  }
  if obj == TW_XSURF {
    if op == 0 {
      TW_CFG = tw_rd32(TW_PL, 0)
      TW_CONFIGURED = 1
    }
    return 1
  }
  if obj == TW_TOP {
    if op == 1 {
      TW_CLOSED = 1
      return 0
    }
    return 1
  }
  if obj == TW_WM {
    if op == 0 {
      tw_begin(TW_WM, 3)
      tw_put32(tw_rd32(TW_PL, 0))
      tw_flush()
    }
    return 1
  }
  if obj == TW_CB {
    if op == 0 {
      TW_GOT_CB = 1
    }
    return 1
  }
  if obj == TW_SEAT {
    if op == 0 {
      TW_CAPS = tw_rd32(TW_PL, 0)
      if TW_CAPS & 1 && TW_PTR == 0 {
        TW_PTR = tw_new()
        tw_begin(TW_SEAT, 0)
        tw_put32(TW_PTR)
        tw_flush()
      }
      if TW_CAPS & 2 && TW_KB == 0 {
        TW_KB = tw_new()
        tw_begin(TW_SEAT, 1)
        tw_put32(TW_KB)
        tw_flush()
      }
    }
    return 1
  }
  if obj == TW_KB {
    # op 0 is keymap (format + size, with the xkb fd attached); the module maps
    # evdev codes itself, so the keymap is ignored and the fd is dropped. op 4
    # carries modifiers, which no caller has asked for.
    if op == 3 {
      tw_queue(1, tw_rd32(TW_PL, 8), tw_rd32(TW_PL, 12))
      TW_KEY_EVENTS = TW_KEY_EVENTS + 1
    }
    return 1
  }
  if obj == TW_PTR {
    if op == 0 {
      TW_MOUSE_X = tw_fixed(tw_rd32(TW_PL, 8))
      TW_MOUSE_Y = tw_fixed(tw_rd32(TW_PL, 12))
      TW_MOUSE_EVENTS = TW_MOUSE_EVENTS + 1
      TW_MOTION = 1
    }
    if op == 2 {
      TW_MOUSE_X = tw_fixed(tw_rd32(TW_PL, 4))
      TW_MOUSE_Y = tw_fixed(tw_rd32(TW_PL, 8))
      TW_MOUSE_EVENTS = TW_MOUSE_EVENTS + 1
      TW_MOTION = 1
    }
    if op == 3 {
      tw_queue(3, tw_rd32(TW_PL, 8), tw_rd32(TW_PL, 12))
      TW_BUTTON_EVENTS = TW_BUTTON_EVENTS + 1
    }
    return 1
  }
  if obj == TW_BUF0 {
    TW_FREE0 = 1
    TW_RELEASES = TW_RELEASES + 1
    return 1
  }
  if obj == TW_BUF1 {
    TW_FREE1 = 1
    TW_RELEASES = TW_RELEASES + 1
    return 1
  }
  return 1
}

# ------------------------------------------------------------------- socket

# /proc/self/environ reports a real size of 0, so it cannot be bounded by
# file_size(); the scan uses a fixed window and NUL-separated entries, the same
# way the X client reads its cookie path.
fn tw_env(key: str) -> str {
  let e = read_file("/proc/self/environ")
  let kl = tw_slen(key)
  let i = 0
  while i < 8192 {
    let j = 0
    let ok = 1
    while j < kl {
      if e[i + j] != key[j] {
        ok = 0
      }
      j = j + 1
    }
    if ok == 1 && e[i + kl] == 61 {
      let s = i + kl + 1
      let end = s
      while end < 8192 && e[end] != 0 {
        end = end + 1
      }
      return slice(e, s, end - s)
    }
    while i < 8192 && e[i] != 0 {
      i = i + 1
    }
    i = i + 1
  }
  return ""
}

fn tw_sock_path() -> str {
  let disp = tw_env("WAYLAND_DISPLAY")
  if str_eq(disp, "") == 1 {
    disp = "wayland-0"
  }
  if disp[0] == 47 {
    return disp
  }
  let rt = tw_env("XDG_RUNTIME_DIR")
  if str_eq(rt, "") == 1 {
    return ""
  }
  return rt + "/" + disp
}

# --------------------------------------------------------------------- setup

fn tw_make_buffer(id: int, off: int) {
  tw_begin(TW_POOL, 0)
  tw_put32(id)
  tw_put32(off)
  tw_put32(TW_W)
  tw_put32(TW_H)
  tw_put32(TW_STRIDE)
  tw_put32(1)
  tw_flush()
}

fn tw_pump(ms: int) -> int {
  if fd_poll(TW_FD, ms) == 0 {
    return 0
  }
  if fd_read(TW_FD, TW_HDR, 8) != 8 {
    return -1
  }
  let obj = tw_rd32(TW_HDR, 0)
  let op = TW_HDR[4] + (TW_HDR[5] << 8)
  let sz = TW_HDR[6] + (TW_HDR[7] << 8)
  let body = sz - 8
  if body > 0 {
    if fd_read(TW_FD, TW_PL, body) != body {
      return -1
    }
  }
  return tw_dispatch(obj, op, body)
}

fn tw_open(w: int, h: int, title: str) -> int {
  TW_W = w
  TW_H = h
  TW_STRIDE = w * 4
  TW_FD = sock(tw_sock_path())
  if TW_FD < 0 {
    return 0
  }
  tw_begin(1, 1)
  TW_REG = tw_new()
  tw_put32(TW_REG)
  tw_flush()
  tw_begin(1, 0)
  TW_CB = tw_new()
  tw_put32(TW_CB)
  tw_flush()
  let guard = 0
  while TW_GOT_CB == 0 && guard < 200 {
    if tw_pump(200) < 0 {
      return 0
    }
    guard = guard + 1
  }
  if TW_COMP == 0 {
    return 0
  }
  if TW_SHM == 0 {
    return 0
  }
  if TW_WM == 0 {
    return 0
  }

  TW_FDS = shm(TW_STRIDE * TW_H * 2)
  if TW_FDS < 0 {
    return 0
  }
  tw_begin(TW_SHM, 0)
  TW_POOL = tw_new()
  tw_put32(TW_POOL)
  tw_put32(TW_STRIDE * TW_H * 2)
  tw_end(TW_FDS)

  tw_begin(TW_COMP, 0)
  TW_SURF = tw_new()
  tw_put32(TW_SURF)
  tw_flush()
  tw_begin(TW_WM, 2)
  TW_XSURF = tw_new()
  tw_put32(TW_XSURF)
  tw_put32(TW_SURF)
  tw_flush()
  tw_begin(TW_XSURF, 1)
  TW_TOP = tw_new()
  tw_put32(TW_TOP)
  tw_flush()
  tw_begin(TW_TOP, 2)
  tw_putstr(title)
  tw_flush()
  tw_begin(TW_TOP, 3)
  tw_putstr("twayland")
  tw_flush()

  TW_BUF0 = tw_new()
  tw_make_buffer(TW_BUF0, 0)
  TW_BUF1 = tw_new()
  tw_make_buffer(TW_BUF1, TW_STRIDE * TW_H)
  TW_PIX = newbuf(TW_STRIDE * TW_H)

  tw_begin(TW_SURF, 6)
  tw_flush()
  guard = 0
  while TW_CONFIGURED == 0 && guard < 200 {
    if tw_pump(200) < 0 {
      return 0
    }
    guard = guard + 1
  }
  if TW_CONFIGURED == 0 {
    return 0
  }
  tw_begin(TW_XSURF, 4)
  tw_put32(TW_CFG)
  tw_flush()
  tw_begin(TW_XSURF, 3)
  tw_put32(0)
  tw_put32(0)
  tw_put32(TW_W)
  tw_put32(TW_H)
  tw_flush()
  return 1
}

# ------------------------------------------------------------------ drawing

fn tw_clear(c: int) {
  let r = (c >> 16) & 255
  let g = (c >> 8) & 255
  let b = c & 255
  let i = 0
  let n = TW_W * TW_H
  while i < n {
    let o = i * 4
    TW_PIX[o] = b
    TW_PIX[o + 1] = g
    TW_PIX[o + 2] = r
    TW_PIX[o + 3] = 0
    i = i + 1
  }
}

fn tw_pixel(x: int, y: int, c: int) {
  if x < 0 || x >= TW_W {
    return
  }
  if y < 0 || y >= TW_H {
    return
  }
  let o = y * TW_STRIDE + x * 4
  TW_PIX[o] = c & 255
  TW_PIX[o + 1] = (c >> 8) & 255
  TW_PIX[o + 2] = (c >> 16) & 255
  TW_PIX[o + 3] = 0
}

fn tw_rect(x: int, y: int, w: int, h: int, c: int) {
  let j = 0
  while j < h {
    let i = 0
    while i < w {
      tw_pixel(x + i, y + j, c)
      i = i + 1
    }
    j = j + 1
  }
}

# -------------------------------------------------------------------- frame

# Write the frame into the current buffer, wait for the compositor to release
# that buffer if it still owns it, then attach, damage and commit.
fn tw_present() -> int {
  if TW_CLOSED == 1 {
    return 0
  }
  let buf = TW_BUF0
  let off = 0
  if TW_FRAME == 1 {
    buf = TW_BUF1
    off = TW_STRIDE * TW_H
  }
  let guard = 0
  while guard < 200 {
    if TW_FRAME == 1 {
      if TW_FREE1 == 1 {
        guard = 200
      }
    } else {
      if TW_FREE0 == 1 {
        guard = 200
      }
    }
    if guard < 200 {
      if tw_pump(8) < 0 {
        return 0
      }
      guard = guard + 1
    }
  }
  if TW_CLOSED == 1 {
    return 0
  }
  if fd_pwrite(TW_FDS, off, TW_PIX, TW_STRIDE * TW_H) != TW_STRIDE * TW_H {
    return 0
  }
  tw_begin(TW_SURF, 1)
  tw_put32(buf)
  tw_put32(0)
  tw_put32(0)
  tw_flush()
  tw_begin(TW_SURF, 9)
  tw_put32(0)
  tw_put32(0)
  tw_put32(TW_W)
  tw_put32(TW_H)
  tw_flush()
  tw_begin(TW_SURF, 6)
  tw_flush()
  if TW_FRAME == 1 {
    TW_FREE1 = 0
    TW_FRAME = 0
  } else {
    TW_FREE0 = 0
    TW_FRAME = 1
  }
  TW_FRAMES = TW_FRAMES + 1
  return 1
}

# Return one event: 0 timeout, 1 key, 2 pointer motion, 3 button, 4 anything
# else, -1 closed or failed. Drain with `while tw_poll(0) > 0 { ... }`.
fn tw_poll(ms: int) -> int {
  if TW_QN > 0 {
    return tw_take()
  }
  if TW_MOTION == 1 {
    TW_MOTION = 0
    return 2
  }
  if tw_running() == 0 {
    return -1
  }
  let r = tw_pump(ms)
  if r <= 0 {
    return r
  }
  if TW_QN > 0 {
    return tw_take()
  }
  if TW_MOTION == 1 {
    TW_MOTION = 0
    return 2
  }
  return 4
}

# Service events without drawing, so a caller can keep a window alive.
fn tw_idle(ms: int) -> int {
  if tw_pump(ms) < 0 {
    return 0
  }
  if tw_running() == 0 {
    return 0
  }
  return 1
}

fn tw_running() -> int {
  if TW_CLOSED == 1 {
    return 0
  }
  if TW_ERR == 1 {
    return 0
  }
  return 1
}
