# tlang desktop: a window manager, six apps and a persistent filesystem.
#
# The desktop owns the screen: a gradient wallpaper, a column of round app
# icons, a taskbar with one button per app, and a table of windows drawn back
# to front.  Clicking a window raises it and gives it the keyboard; its title
# bar drags it, and only the band it left and entered is repainted.
#
# Apps:
#   terminal  the kernel runtime's 32x17 text grid, placed inside the window
#   editor    a text buffer over the filesystem, saved with Ctrl+S
#   files     the directory, click a name to edit it
#   system    the about panel, drawn entirely here
#   paint     a 96x64 indexed canvas, saved to TLFS with Ctrl+S
#   viewer    whatever canvas TLFS holds, at 1x to 4x
#
# Storage is TLFS on the primary slave disk (drive 1), reached through
# ata_read/ata_write: sector 0 is the superblock, sector 1 the directory of 16
# entries of 32 bytes (20-byte name, 4-byte size, 8 reserved), and entry i owns
# 16 sectors from LBA 2 + i*16.  The kernel image lives on the master disk and
# is never written, so a bug here can lose data but not the running system.
#
# There are no interrupts yet: the loop polls both PS/2 ports and the keyboard.
#
# Every visible change adds its rectangle to one damage union, and the loop
# copies that union to the screen once per frame with fb_present().  Nothing is
# ever visible half-updated, and a repaint costs the band it names.

let FBP = 0xfd000000            # where drawing goes; the back buffer after boot
let WIDTH = 1280
let HEIGHT = 1024
let PITCH = 5120                # 1280 pixels of 4 bytes
let TASKBAR_Y = 984

let CELL_W = 16                 # glyph cell at 2x
let CELL_H = 20
let TITLE_H = 36
let ROUND = 16

# App kinds.  A window's kind decides its default geometry, its title and what
# draw_window() paints inside the frame.
let K_TERM = 1
let K_EDIT = 2
let K_FILES = 3
let K_SYS = 4
let K_IMG = 5
let K_PAINT = 6

# Window table, parallel arrays because there are no struct arrays.  ORDER is
# back to front, so NORD-1 is the window on top and FOCUS.
let MAX_WIN = 6
let W_KIND = alloc(MAX_WIN)
let W_X = alloc(MAX_WIN)
let W_Y = alloc(MAX_WIN)
let W_W = alloc(MAX_WIN)
let W_H = alloc(MAX_WIN)
let W_ON = alloc(MAX_WIN)
let ORDER = alloc(MAX_WIN)
let NORD = 0
let FOCUS = -1

let DRAG = 0
let DRAG_WIN = -1
let GRAB_DX = 0
let GRAB_DY = 0
let SHIFT = 0
let CTRL = 0

# Terminal line being edited, and the filesystem scratch page.
let BUF = alloc(256)
let LINE_N = 0
let ROW_Q = "qwertyuiop"
let ROW_A = "asdfghjkl"
let ROW_Z = "zxcvbnm"
let ROW_N = "1234567890"
let ROW_NS = "!@#$%^&*()"

# Filesystem.
let MAX_FILES = 16
let SLOT_SECTORS = 16
let FS_DATA = 2
let FS_OK = 0                   # 0 until a superblock and directory read back
# The machine builtins take integer addresses and the compiler will not pass a
# buffer where an int is wanted, so the two buffers a disk transfer names keep
# their address beside them.  `| 0` is the one expression that yields it; the
# contents are still reached by indexing SBUF and DSEC.
let SBUF = alloc(512)           # one sector
let SBUF_A = SBUF | 0
let DSEC = alloc(512)           # the directory sector
let DSEC_A = DSEC | 0
let RB = alloc(8192)            # read buffer for cat
let RB_A = RB | 0
let NB = alloc(24)              # current file name
let NN = 0
let SB_BASE = 0                 # where the shell's text starts in BUF


# Editor.
let EB = alloc(8192)
let ELEN = 0
let ECUR = 0
let EDIRTY = 0
let ETOP = 0
let CXP = -1
let CYP = -1
let DS = alloc(24)              # digits for draw_int

# Artwork: a 96x64 canvas of palette indices.  The first 64 bytes of the buffer
# are the 16 colours, the rest is one byte per pixel, so the buffer is exactly
# what gets saved and what the viewer loads back: the file carries its palette
# and the runtime needs no table of its own.
let ART_W = 96
let ART_H = 64
let ART_PIX = 6144
let ART_LEN = 6208              # 64 bytes of palette plus the pixels
let ARTB = alloc(6208)
let ART_A = ARTB | 0
let VB = alloc(8192)            # the canvas the viewer loaded
let VB_A = VB | 0
let ACOL = 1                    # selected palette index
let PAINTING = 0
let VHAVE = 0

# Everything that crosses the disk is a byte stream, but an alloc'd buffer is an
# array of 8-byte elements: `buf[i]` stores eight bytes, so ata_write() of one
# 512-byte sector would carry only 64 of them and the directory would land with
# seven zero bytes between names.  The sector, directory, artwork and read
# buffers are therefore addressed as bytes through peek8/poke8.
fn dget(i: int) -> int { return peek8(DSEC_A + i) }
fn dput(i: int, v: int) { poke8(DSEC_A + i, v) }
fn sget(i: int) -> int { return peek8(SBUF_A + i) }
fn sput(i: int, v: int) { poke8(SBUF_A + i, v) }
fn aget(i: int) -> int { return peek8(ART_A + i) }
fn aput(i: int, v: int) { poke8(ART_A + i, v) }
fn vput(i: int, v: int) { poke8(VB_A + i, v) }
fn rget(i: int) -> int { return peek8(RB_A + i) }
fn rput(i: int, v: int) { poke8(RB_A + i, v) }

# Mouse state.  MX/MY are the pointer in pixels, MBTN remembers the last left
# button state so a press is one click, and PBG is the patch of screen under
# the pointer, saved so moving it does not smear.
let MX = 640
let MY = 512
let MMOVED = 0
let MBTN = 0
let MPKT = 0
let MBYTES = alloc(3)
let PCW = 20
let PBG = alloc(400)
let PDX = -1
let PDY = -1

# Damage union for the current frame.  DNONE is 1 while nothing has changed.
let DX0 = 0
let DX1 = 0
let DY0 = 0
let DY1 = 0
let DNONE = 1

# Damage rectangle for a repaint; windows test it with hits().
let BX0 = 0
let BX1 = 0
let BY0 = 0
let BY1 = 0

fn letter(c: int, shift: int) -> int {
  if shift == 1 && c >= 97 && c <= 122 { return c - 32 }
  return c
}

# Scancode set 1 -> ASCII, US layout.  0 means "not bound", and the caller
# drops it, so Ctrl, Alt, function keys, quote and backslash do nothing rather
# than print a wrong character.
fn key_char(sc: int, shift: int) -> int {
  if sc >= 16 && sc <= 25 { return letter(ROW_Q[sc - 16], shift) }   # q..p
  if sc >= 30 && sc <= 38 { return letter(ROW_A[sc - 30], shift) }   # a..l
  if sc >= 44 && sc <= 50 { return letter(ROW_Z[sc - 44], shift) }   # z..m
  if sc >= 2 && sc <= 11 {
    if shift == 1 { return ROW_NS[sc - 2] }
    return ROW_N[sc - 2]
  }
  if sc == 12 { if shift == 1 { return 95 } return 45 }    # _ -
  if sc == 13 { if shift == 1 { return 43 } return 61 }    # + =
  if sc == 26 { if shift == 1 { return 123 } return 91 }   # { [
  if sc == 27 { if shift == 1 { return 125 } return 93 }   # } ]
  if sc == 39 { if shift == 1 { return 58 } return 59 }    # : ;
  if sc == 51 { if shift == 1 { return 60 } return 44 }    # < ,
  if sc == 52 { if shift == 1 { return 62 } return 46 }    # > .
  if sc == 53 { if shift == 1 { return 63 } return 47 }    # ? /
  if sc == 57 { return 32 }                                # space
  return 0
}

# ---------------------------------------------------------------- colour
# Mix two 0x00RRGGBB colours, t = 0 for a and 255 for b.
fn mix(a: int, b: int, t: int) -> int {
  let r = (((a >> 16) & 255) * (255 - t) + ((b >> 16) & 255) * t) / 255
  let g = (((a >> 8) & 255) * (255 - t) + ((b >> 8) & 255) * t) / 255
  let bl = ((a & 255) * (255 - t) + (b & 255) * t) / 255
  return (r << 16) | (g << 8) | bl
}

fn blend_px(x: int, y: int, c: int, a: int) {
  if a <= 0 { return }
  if x < 0 || x >= WIDTH || y < 0 || y >= HEIGHT { return }
  let p = FBP + y * PITCH + x * 4
  if a >= 255 {
    poke32(p, c)
  } else {
    poke32(p, mix(peek32(p), c, a))
  }
}

# Fill one row between fractional bounds given in eighths.  The two boundary
# pixels are blended by the part of them the shape covers, which is what makes
# a circle look round instead of stepped.
fn span8(left: int, right: int, y: int, c: int) {
  if y < 0 || y >= HEIGHT { return }
  if left < 0 { left = 0 }
  if right > WIDTH * 8 { right = WIDTH * 8 }
  if left >= right { return }
  let lp = left >> 3
  let lo = left & 7
  let rp = right >> 3
  let ro = right & 7
  if lo != 0 {
    blend_px(lp, y, c, (8 - lo) * 255 / 8)
    lp = lp + 1
  }
  while lp < rp {
    poke32(FBP + y * PITCH + lp * 4, c)
    lp = lp + 1
  }
  if ro != 0 {
    blend_px(rp, y, c, ro * 255 / 8)
  }
}

# Integer square root, by Newton's method; every radius here arrives as eighths.
fn isqrt(n: int) -> int {
  if n < 2 { return n }
  let x = n
  let y = (x + 1) / 2
  while y < x {
    x = y
    y = (x + n / x) / 2
  }
  return x
}

fn disc(cx: int, cy: int, r: int, c: int) {
  let r8 = r * 8
  let j = 0 - r
  while j <= r {
    let dy = j * 8 + 4
    let inside = r8 * r8 - dy * dy
    if inside >= 0 {
      let f = isqrt(inside)
      span8(cx * 8 - f, cx * 8 + f, cy + j, c)
    }
    j = j + 1
  }
}

fn disc_grad(cx: int, cy: int, r: int, top: int, bottom: int) {
  let r8 = r * 8
  let j = 0 - r
  while j <= r {
    let dy = j * 8 + 4
    let inside = r8 * r8 - dy * dy
    if inside >= 0 {
      let f = isqrt(inside)
      let t = (j + r) * 255 / (2 * r)
      span8(cx * 8 - f, cx * 8 + f, cy + j, mix(top, bottom, t))
    }
    j = j + 1
  }
}

fn round_rect(x: int, y: int, w: int, h: int, r: int, c: int) {
  let r8 = r * 8
  let j = 0
  while j < h {
    let inset = 0
    if j < r {
      let dy = r8 - (j * 8 + 4)
      let s = r8 * r8 - dy * dy
      if s < 0 { s = 0 }
      inset = r8 - isqrt(s)
    } else if j >= h - r {
      let dy = r8 - ((h - 1 - j) * 8 + 4)
      let s = r8 * r8 - dy * dy
      if s < 0 { s = 0 }
      inset = r8 - isqrt(s)
    }
    span8(x * 8 + inset, (x + w) * 8 - inset, y + j, c)
    j = j + 1
  }
}

# ---------------------------------------------------------------- icons
# Every icon is drawn, not a bitmap: a rim, a gradient face and a glyph whose
# size follows the icon.
fn draw_terminal_icon(cx: int, cy: int, r: int) {
  disc(cx, cy, r, 0x05070c)
  disc_grad(cx, cy, r - 2, 0x63b0ff, 0x2b5cf0)
  let s = r / 3
  let i = 0
  while i < s {
    poke32(FBP + (cy - s + i) * PITCH + (cx - s - 1 + i) * 4, 0xffffff)
    poke32(FBP + (cy + i) * PITCH + (cx - s - 1 + i) * 4, 0xffffff)
    i = i + 1
  }
  fb_fill(cx, cy + s - 1, s + 1, 2, 0xffffff)
}

fn draw_editor_icon(cx: int, cy: int, r: int) {
  disc(cx, cy, r, 0x05070c)
  disc_grad(cx, cy, r - 2, 0x7ee0a8, 0x1f9d6b)
  let s = r / 2
  if s < 3 { s = 3 }
  fb_fill(cx - s, cy - s, s * 2, 3, 0xffffff)
  fb_fill(cx - s, cy - 3, s * 2 - s, 3, 0xffffff)
  fb_fill(cx - s, cy + s - 4, s * 2, 3, 0xffffff)
}

fn draw_files_icon(cx: int, cy: int, r: int) {
  disc(cx, cy, r, 0x05070c)
  disc_grad(cx, cy, r - 2, 0xffd479, 0xe0912c)
  let s = r / 2
  if s < 3 { s = 3 }
  fb_fill(cx - s, cy - s, s + 2, 4, 0xffffff)          # folder tab
  fb_fill(cx - s, cy - s + 4, s * 2, s + 2, 0xffffff)  # folder body
}

fn draw_system_icon(cx: int, cy: int, r: int) {
  disc(cx, cy, r, 0x05070c)
  disc_grad(cx, cy, r - 2, 0xb9a4ff, 0x6a3ff0)
  let s = r / 3
  if s < 3 { s = 3 }
  disc(cx, cy - s - 1, s / 2, 0xffffff)
  fb_fill(cx - s / 2, cy - s / 2, s + 1, s + s / 2, 0xffffff)
}

# A framed picture: a white mount, a sun and a horizon.
fn draw_viewer_icon(cx: int, cy: int, r: int) {
  disc(cx, cy, r, 0x05070c)
  disc_grad(cx, cy, r - 2, 0xffc0e0, 0xb03a7f)
  let s = r / 2
  if s < 3 { s = 3 }
  fb_fill(cx - s, cy - s, s * 2, s * 2, 0xffffff)
  fb_fill(cx - s + 1, cy - s + 1, s * 2 - 2, s * 2 - 2, 0xb03a7f)
  disc(cx + s / 2, cy - s / 2, s / 3, 0xffffff)
  fb_fill(cx - s + 1, cy + s - 3, s * 2 - 2, 2, 0xffffff)
}

# A palette: a white board with three dabs of paint.
fn draw_paint_icon(cx: int, cy: int, r: int) {
  disc(cx, cy, r, 0x05070c)
  disc_grad(cx, cy, r - 2, 0x8ce8d2, 0x137f6b)
  let s = r / 2
  if s < 3 { s = 3 }
  fb_fill(cx - s, cy - s, s * 2, s * 2, 0xffffff)
  disc(cx - s / 2, cy - s / 2, s / 4 + 1, 0xf2556b)
  disc(cx + s / 2, cy - s / 4, s / 4 + 1, 0xffd93d)
  disc(cx - s / 3, cy + s / 2, s / 4 + 1, 0x4d96ff)
}

# ---------------------------------------------------------------- desktop
# Two stops plus a violet glow gathered near the horizon, all in true colour.
fn sky_colour(y: int) -> int {
  let t = y * 255 / (TASKBAR_Y - 1)
  let base = mix(0x070912, 0x241c4a, t)
  return mix(base, 0x3a2c78, (t * t / 255) / 6)
}

# The labels and icons that sit on the wallpaper, split out so a partial
# repaint can put them back without repainting the whole sky.
fn draw_desktop_items() {
  fb_text(32, 32, 0xeef2f8, "tlang desktop 0.3")
  draw_terminal_icon(110, 130, 36)
  fb_text(46, 178, 0xc9d4e8, "terminal")
  draw_editor_icon(110, 280, 36)
  fb_text(58, 328, 0xc9d4e8, "editor")
  draw_files_icon(110, 430, 36)
  fb_text(62, 478, 0xc9d4e8, "files")
  draw_system_icon(110, 580, 36)
  fb_text(54, 628, 0xc9d4e8, "system")
  draw_paint_icon(110, 730, 36)
  fb_text(62, 778, 0xc9d4e8, "paint")
  draw_viewer_icon(110, 880, 36)
  fb_text(52, 928, 0xc9d4e8, "viewer")
}

fn draw_wallpaper() {
  let y = 0
  while y < TASKBAR_Y {
    fb_fill(0, y, WIDTH, 1, sky_colour(y))
    y = y + 1
  }
  draw_desktop_items()
}

fn taskbar_button(x: int, w: int, on: int, c: int) {
  let bg = 0x161c2a
  if on == 1 { bg = c }
  round_rect(x, 990, w, 28, 14, bg)
}

fn draw_taskbar() {
  fb_fill(0, TASKBAR_Y, WIDTH, HEIGHT - TASKBAR_Y, 0x0c0f17)
  fb_fill(0, TASKBAR_Y, WIDTH, 1, 0x232a3a)
  taskbar_button(24, 186, win_kind_at_kind(K_TERM) >= 0, 0x22304f)
  draw_terminal_icon(48, 1004, 11)
  fb_text(70, 996, 0xeef2f8, "TERMINAL")
  taskbar_button(222, 150, win_kind_at_kind(K_EDIT) >= 0, 0x1d4030)
  draw_editor_icon(246, 1004, 11)
  fb_text(268, 996, 0xeef2f8, "EDITOR")
  taskbar_button(384, 130, win_kind_at_kind(K_FILES) >= 0, 0x403520)
  draw_files_icon(408, 1004, 11)
  fb_text(430, 996, 0xeef2f8, "FILES")
  taskbar_button(526, 150, win_kind_at_kind(K_SYS) >= 0, 0x2a2450)
  draw_system_icon(550, 1004, 11)
  fb_text(572, 996, 0xeef2f8, "SYSTEM")
  taskbar_button(688, 140, win_kind_at_kind(K_PAINT) >= 0, 0x1f4640)
  draw_paint_icon(712, 1004, 11)
  fb_text(734, 996, 0xeef2f8, "PAINT")
  taskbar_button(840, 140, win_kind_at_kind(K_IMG) >= 0, 0x43204a)
  draw_viewer_icon(864, 1004, 11)
  fb_text(886, 996, 0xeef2f8, "VIEWER")
  fb_text(1208, 996, 0x7c879b, "0.3")
}

# ---------------------------------------------------------------- windows
# The table.  A kind has at most one window, so opening an app twice raises the
# window that is already there.
fn win_kind_at_kind(kind: int) -> int {
  let i = 0
  while i < MAX_WIN {
    if W_ON[i] == 1 && W_KIND[i] == kind { return i }
    i = i + 1
  }
  return -1
}

fn win_slot() -> int {
  let i = 0
  while i < MAX_WIN {
    if W_ON[i] == 0 { return i }
    i = i + 1
  }
  return -1
}

fn order_find(i: int) -> int {
  let k = 0
  while k < NORD {
    if ORDER[k] == i { return k }
    k = k + 1
  }
  return -1
}

fn win_raise(i: int) {
  let k = order_find(i)
  if k < 0 { return }
  while k < NORD - 1 {
    ORDER[k] = ORDER[k + 1]
    k = k + 1
  }
  ORDER[NORD - 1] = i
  FOCUS = i
}

fn win_open(kind: int) -> int {
  let i = win_kind_at_kind(kind)
  if i >= 0 {
    win_raise(i)
    return i
  }
  i = win_slot()
  if i < 0 { return -1 }
  W_KIND[i] = kind
  W_ON[i] = 1
  if kind == K_TERM {
    W_X[i] = 420
    W_Y[i] = 150
    W_W[i] = 544
    W_H[i] = 400
  } else if kind == K_EDIT {
    W_X[i] = 300
    W_Y[i] = 120
    W_W[i] = 660
    W_H[i] = 470
  } else if kind == K_FILES {
    W_X[i] = 700
    W_Y[i] = 430
    W_W[i] = 400
    W_H[i] = 330
  } else if kind == K_IMG {
    W_X[i] = 560
    W_Y[i] = 180
    W_W[i] = 440
    W_H[i] = 340
  } else if kind == K_PAINT {
    W_X[i] = 620
    W_Y[i] = 110
    W_W[i] = 440
    W_H[i] = 400
  } else {
    W_X[i] = 820
    W_Y[i] = 520
    W_W[i] = 400
    W_H[i] = 240
  }
  ORDER[NORD] = i
  NORD = NORD + 1
  FOCUS = i
  return i
}

fn win_remove(i: int) {
  let k = order_find(i)
  if k >= 0 {
    while k < NORD - 1 {
      ORDER[k] = ORDER[k + 1]
      k = k + 1
    }
    NORD = NORD - 1
  }
  if W_KIND[i] == K_TERM { console_hide() }
  W_ON[i] = 0
  if FOCUS == i {
    if NORD > 0 { FOCUS = ORDER[NORD - 1] } else { FOCUS = -1 }
  }
}

fn win_title(kind: int) -> str {
  if kind == K_TERM { return "terminal" }
  if kind == K_EDIT { return "editor" }
  if kind == K_FILES { return "files" }
  if kind == K_PAINT { return "paint" }
  if kind == K_IMG { return "viewer" }
  return "system"
}

fn draw_title(x: int, y: int, w: int, focused: int) {
  let r8 = ROUND * 8
  let top = 0x2a3752
  let bot = 0x151d2c
  if focused == 1 {
    top = 0x44608a
    bot = 0x1d2a42
  }
  let j = 0
  while j < TITLE_H {
    let c = mix(top, bot, j * 255 / (TITLE_H - 1))
    let inset = 0
    if j < ROUND {
      let dy = r8 - (j * 8 + 4)
      let s = r8 * r8 - dy * dy
      if s < 0 { s = 0 }
      inset = r8 - isqrt(s)
    }
    span8((x + 3) * 8 + inset, (x + w - 3) * 8 - inset, y + 3 + j, c)
    j = j + 1
  }
}

fn draw_close(x: int, y: int, w: int) {
  let cx = x + w - 32
  let cy = y + 20
  disc(cx, cy, 13, 0x2b3448)
  disc_grad(cx, cy, 11, 0xf26b73, 0xc33a44)
  let i = 0
  while i < 11 {
    poke32(FBP + (cy - 5 + i) * PITCH + (cx - 5 + i) * 4, 0xffffff)
    poke32(FBP + (cy - 5 + i) * PITCH + (cx + 5 - i) * 4, 0xffffff)
    i = i + 1
  }
}

# Frame, title bar, title text and close button; the caller paints the client
# area inside.
fn draw_frame(x: int, y: int, w: int, h: int, title: str, focused: int) {
  round_rect(x + 10, y + 14, w, h, ROUND + 4, 0x03040a)    # drop shadow
  round_rect(x, y, w, h, ROUND, 0x2b3448)                  # frame
  draw_title(x, y, w, focused)
  round_rect(x + 4, y + TITLE_H + 4, w - 8, h - TITLE_H - 8, 12, 0x0d1119)
  fb_text(x + 24, y + 12, 0xeef2f8, title)
  draw_close(x, y, w)
}

# ---------------------------------------------------------------- apps
fn ed_cols(i: int) -> int {
  return (W_W[i] - 48) / CELL_W
}

fn ed_rows(i: int) -> int {
  let r = (W_H[i] - TITLE_H - 64) / CELL_H
  if r < 1 { return 1 }
  return r
}

fn draw_int(x: int, y: int, c: int, v: int) -> int {
  if v < 0 {
    fb_char(x, y, c, 45)
    x = x + CELL_W
    v = 0 - v
  }
  let n = 0
  if v == 0 {
    fb_char(x, y, c, 48)
    return x + CELL_W
  }
  while v > 0 {
    DS[n] = 48 + v % 10
    v = v / 10
    n = n + 1
  }
  let i = n - 1
  while i >= 0 {
    fb_char(x, y, c, DS[i])
    x = x + CELL_W
    i = i - 1
  }
  return x
}

# The editor shows the buffer a line at a time, scrolling by whole lines so the
# cursor is always visible.  Rendering is split into view rows so a keystroke
# repaints the rows it touched instead of the whole window.
fn draw_editor_rows(i: int, first: int, last: int) {
  let cols = ed_cols(i)
  let rows = ed_rows(i)
  let ox = W_X[i] + 24
  let oy = W_Y[i] + TITLE_H + 12
  CXP = -1
  CYP = -1
  let line = 0
  let col = 0
  let pos = 0
  while pos <= ELEN {
    let vr = line - ETOP
    if pos == ECUR && vr >= first && vr <= last && col < cols {
      CXP = ox + col * CELL_W
      CYP = oy + vr * CELL_H
    }
    if pos == ELEN { pos = ELEN + 1 } else {
      let c = EB[pos]
      if c == 10 {
        line = line + 1
        col = 0
      } else {
        if vr >= first && vr <= last && vr >= 0 && vr < rows && col < cols && c >= 32 {
          fb_char(ox + col * CELL_W, oy + vr * CELL_H, 0xdfe7f5, c)
        }
        col = col + 1
      }
      pos = pos + 1
    }
  }
  if CXP >= 0 && CYP >= 0 {
    fb_fill(CXP, CYP + 16, 10, 3, 0x6ea8ff)
  }
}

# name, byte count, and a word while there are unsaved edits.  The strip is
# cleared first: the count gains and loses digits as you type, and a repaint
# that only draws on top would leave the old ones behind.
fn draw_editor_status(i: int) {
  let x = W_X[i]
  let sy = W_Y[i] + W_H[i] - 34
  fb_fill(x + 12, sy - 8, W_W[i] - 24, CELL_H + 10, 0x0d1119)
  fb_fill(x + 12, sy - 10, W_W[i] - 24, 1, 0x1b2334)
  let sx = x + 24
  let k = 0
  while k < NN {
    fb_char(sx, sy, 0x9fb0c8, NB[k])
    sx = sx + CELL_W
    k = k + 1
  }
  sx = sx + CELL_W
  sx = draw_int(sx, sy, 0x6f7d94, ELEN)
  fb_text(sx + CELL_W, sy, 0x6f7d94, "bytes")
  if EDIRTY == 1 { fb_text(x + W_W[i] - 24 - 7 * CELL_W, sy, 0xffb86b, "unsaved") }
}

fn draw_editor(i: int) {
  let rows = ed_rows(i)
  let cols = ed_cols(i)
  fb_fill(W_X[i] + 24, W_Y[i] + TITLE_H + 12, cols * CELL_W, rows * CELL_H,
          0x0d1119)
  draw_editor_rows(i, 0, rows - 1)
  draw_editor_status(i)
}

# Clear and redraw view rows [first..last] plus the status line and the pointer.
# Only safe while the editor is on top; otherwise the band repaint runs, which
# puts back everything that covers it as well.
fn repaint_editor_rows(i: int, first: int, last: int) {
  if i < 0 { return }
  if order_find(i) != NORD - 1 {
    repaint_window(i)
    return
  }
  if first < 0 { first = 0 }
  let rows = ed_rows(i)
  if last > rows - 1 { last = rows - 1 }
  hide_pointer()
  let cols = ed_cols(i)
  let x = W_X[i] + 24
  let y = W_Y[i] + TITLE_H + 12
  let r = first
  while r <= last {
    fb_fill(x, y + r * CELL_H, cols * CELL_W, CELL_H, 0x0d1119)
    r = r + 1
  }
  draw_editor_rows(i, first, last)
  draw_editor_status(i)
  draw_pointer()
  damage(x, y + first * CELL_H, x + cols * CELL_W,
         y + (last + 1) * CELL_H)
  let sy = W_Y[i] + W_H[i] - 44
  damage(x, sy, x + W_W[i] - 12, sy + CELL_H + 10)
}

# The file being edited, next to the word "editor" in the title bar.
fn draw_editor_name(i: int) {
  if NN == 0 { return }
  let x = W_X[i] + 24 + 7 * CELL_W
  let k = 0
  while k < NN && k < 20 {
    fb_char(x, W_Y[i] + 12, 0x9fb0c8, NB[k])
    x = x + CELL_W
    k = k + 1
  }
}

fn draw_files(i: int) {
  let x = W_X[i] + 24
  let top = W_Y[i] + TITLE_H + 14
  fb_text(x, top, 0x6f7d94, "tlfs, disk 1")
  let y = top + 30
  let row = 0
  let n = 0
  while n < MAX_FILES {
    if fs_entry_used(n) == 1 && row < 8 {
      let py = y + row * 26
      let k = 0
      while k < 19 {
        let c = dget(n * 32 + k)
        if c != 0 { fb_char(x + k * CELL_W, py, 0xdfe7f5, c) }
        k = k + 1
      }
      row = row + 1
    }
    n = n + 1
  }
  if row == 0 { fb_text(x, y, 0x6f7d94, "(no files yet)") }
  fb_text(x, y + 8 * 26 + 2, 0x5d6a80, "click a name to edit")
}

fn draw_system(i: int) {
  let x = W_X[i]
  let y = W_Y[i]
  fb_text(x + 24, y + 56, 0xeef2f8, "tlang desktop 0.3")
  fb_text(x + 24, y + 88, 0xa9b4c8, "x86-64, no Linux")
  fb_text(x + 24, y + 116, 0xa9b4c8, "tcomp build, ring 0")
  fb_text(x + 24, y + 152, 0xa9b4c8, "video 1280x1024x32")
  fb_text(x + 24, y + 180, 0xa9b4c8, "files: TLFS on disk 1")
}

# ---------------------------------------------------------------- paint
# Sixteen colours, written into the buffer's header once.  The swatches, the
# blitter and a saved file therefore all read the same table.
fn art_colour(i: int) -> int {
  if i == 0 { return 0x0d1119 }
  if i == 1 { return 0xffffff }
  if i == 2 { return 0x1a1f2b }
  if i == 3 { return 0xf2556b }
  if i == 4 { return 0xff9f43 }
  if i == 5 { return 0xffd93d }
  if i == 6 { return 0x6bcb77 }
  if i == 7 { return 0x2ec4b6 }
  if i == 8 { return 0x4d96ff }
  if i == 9 { return 0x6a5acd }
  if i == 10 { return 0xb983ff }
  if i == 11 { return 0xff8fab }
  if i == 12 { return 0xc98b63 }
  if i == 13 { return 0x9aa5b1 }
  if i == 14 { return 0xffcf9e }
  return 0xeef2f8
}

fn art_init() {
  let i = 0
  while i < 16 {
    poke32(ART_A + i * 4, art_colour(i))
    i = i + 1
  }
  art_clear()
}

fn art_clear() {
  let k = 0
  while k < ART_PIX {
    aput(64 + k, 0)
    k = k + 1
  }
}

fn art_name() {
  NB[0] = 97
  NB[1] = 114
  NB[2] = 116
  NN = 3
}

# The saved file is the buffer as it stands, palette first, so a picture can be
# read back without knowing which colours this build uses.
fn art_save() {
  art_name()
  let r = fs_save(2, ART_LEN)
  if r == 0 {
    print("\n[saved] art\n")
    VHAVE = -1
  } else {
    print("\nsave failed: ")
    print(r)
    print("\n")
  }
}

fn art_ox(i: int) -> int { return W_X[i] + 24 }
fn art_oy(i: int) -> int { return W_Y[i] + TITLE_H + 12 }
fn art_sw(i: int) -> int { return art_oy(i) + ART_H * 4 + 16 }

fn draw_paint(i: int) {
  let ox = art_ox(i)
  let oy = art_oy(i)
  let sw = art_sw(i)
  fb_indexed(ox, oy, 4, ART_A, ART_W, ART_H)
  let k = 0
  while k < 16 {
    let sx = ox + k * 24
    fb_fill(sx, sw, 22, 22, peek32(ART_A + k * 4))
    if k == ACOL {
      fb_fill(sx, sw, 22, 2, 0xffffff)
      fb_fill(sx, sw + 20, 22, 2, 0xffffff)
    }
    k = k + 1
  }
  fb_text(ox, sw + 30, 0x6f7d94, "click a swatch, drag to draw, ctrl+s saves")
}

# One canvas pixel is four screen pixels, so a stroke fills that block instead
# of repainting the window.  When the paint window is not on top the band path
# runs, which puts back whatever covers it.
fn paint_at(i: int) {
  if i < 0 { return }
  let ox = art_ox(i)
  let oy = art_oy(i)
  let px = (MX - ox) / 4
  let py = (MY - oy) / 4
  if px < 0 || px >= ART_W || py < 0 || py >= ART_H { return }
  aput(64 + py * ART_W + px, ACOL)
  if order_find(i) != NORD - 1 {
    repaint_window(i)
    return
  }
  hide_pointer()
  fb_fill(ox + px * 4, oy + py * 4, 4, 4, peek32(ART_A + ACOL * 4))
  draw_pointer()
  damage(ox + px * 4, oy + py * 4, ox + px * 4 + 4, oy + py * 4 + 4)
}

fn paint_click(i: int) {
  let ox = art_ox(i)
  let sw = art_sw(i)
  if MY >= sw && MY < sw + 22 {
    let k = (MX - ox) / 24
    if MX >= ox && k >= 0 && k < 16 {
      ACOL = k
      repaint_window(i)
    }
    return
  }
  PAINTING = 1
  paint_at(i)
}

fn paint_key(sc: int) {
  let i = win_kind_at_kind(K_PAINT)
  if i < 0 { return }
  if CTRL == 1 && sc == 31 {
    art_save()
    return
  }
  if sc == 46 {
    art_clear()
    repaint_window(i)
  }
}

# ---------------------------------------------------------------- viewer
let VSCALE = 3

# The largest whole-pixel scale that still fits the client area.
fn viewer_fit(i: int) -> int {
  let aw = W_W[i] - 40
  let ah = W_H[i] - TITLE_H - 96
  let s = 4
  while s > 1 {
    if ART_W * s <= aw && ART_H * s <= ah { return s }
    s = s - 1
  }
  return 1
}

# Read the canvas back from TLFS.  VHAVE is 1 when the file is exactly one
# canvas; anything else means there is nothing to show yet.
fn viewer_load(i: int) {
  art_name()
  if fs_load(3) == ART_LEN {
    VHAVE = 1
  } else {
    VHAVE = 0
  }
  if i >= 0 { VSCALE = viewer_fit(i) }
}

fn draw_viewer(i: int) {
  let x = W_X[i]
  let y = W_Y[i]
  fb_fill(x + 4, y + TITLE_H + 4, W_W[i] - 8, W_H[i] - TITLE_H - 8, 0x0d1119)
  if VHAVE < 0 { viewer_load(i) }
  if VHAVE == 0 {
    fb_text(x + 24, y + TITLE_H + 28, 0xdfe7f5, "nothing saved yet")
    fb_text(x + 24, y + TITLE_H + 56, 0x6f7d94, "draw in paint, then ctrl+s")
    return
  }
  let s = VSCALE
  let m = viewer_fit(i)
  if s > m { s = m }
  let w = ART_W * s
  let h = ART_H * s
  let ix = x + (W_W[i] - w) / 2
  let iy = y + TITLE_H + 8 + (W_H[i] - TITLE_H - 96 - h) / 2
  if iy < y + TITLE_H + 8 { iy = y + TITLE_H + 8 }
  fb_indexed(ix, iy, s, VB_A, ART_W, ART_H)
  fb_text(x + 24, y + W_H[i] - 56, 0xdfe7f5, "art")
  let sx = draw_int(x + 24 + 4 * CELL_W, y + W_H[i] - 56, 0x6f7d94, s)
  fb_char(sx, y + W_H[i] - 56, 0x6f7d94, 120)
  fb_text(x + 24, y + W_H[i] - 32, 0x5d6a80, "saved canvas - click to zoom")
}

# Clicking the picture walks the scales that fit and starts again.
fn viewer_zoom(i: int) {
  let m = viewer_fit(i)
  VSCALE = VSCALE + 1
  if VSCALE > m { VSCALE = 1 }
  repaint_window(i)
}

fn viewer_key(sc: int) {
  let i = win_kind_at_kind(K_IMG)
  if i < 0 { return }
  let m = viewer_fit(i)
  if sc == 13 {
    if VSCALE >= m { return }
    VSCALE = VSCALE + 1
  } else if sc == 12 {
    if VSCALE <= 1 { return }
    VSCALE = VSCALE - 1
  } else {
    return
  }
  repaint_window(i)
}

fn draw_window(i: int) {
  let k = W_KIND[i]
  let f = 0
  if FOCUS == i { f = 1 }
  draw_frame(W_X[i], W_Y[i], W_W[i], W_H[i], win_title(k), f)
  if k == K_TERM {
    console_place(W_X[i] + 16, W_Y[i] + 48)
  } else if k == K_EDIT {
    draw_editor_name(i)
    draw_editor(i)
  } else if k == K_FILES {
    draw_files(i)
  } else if k == K_IMG {
    draw_viewer(i)
  } else if k == K_PAINT {
    draw_paint(i)
  } else {
    draw_system(i)
  }
}

# Everything is redrawn in one pass; the pointer's saved background is stale
# after that, so forget it and stamp the sprite again at the end.
fn redraw_desktop() {
  PDX = -1
  draw_wallpaper()
  draw_taskbar()
  let k = 0
  while k < NORD {
    draw_window(ORDER[k])
    k = k + 1
  }
  draw_pointer()
  damage(0, 0, WIDTH, HEIGHT)
}

# ---------------------------------------------------------------- damage
# A drag only repaints the band the window left and the band it entered.
# BX0..BY1 hold that band and windows ask hits() whether they sit on it.
# Rectangles are half-open, the same convention draw_window uses: [x, x+w).
fn hits(x: int, y: int, w: int, h: int) -> int {
  if x >= BX1 || x + w <= BX0 { return 0 }
  if y >= BY1 || y + h <= BY0 { return 0 }
  return 1
}

# Put the saved pixels back under the pointer, so a repaint can run beneath it.
fn hide_pointer() {
  if PDX < 0 { return }
  let i = 0
  while i < PCW {
    let j = 0
    while j < PCW {
      poke32(FBP + (PDY - 2 + i) * PITCH + (PDX - 2 + j) * 4, PBG[i * PCW + j])
      j = j + 1
    }
    i = i + 1
  }
  damage(PDX - 2, PDY - 2, PDX + PCW - 2, PDY + PCW - 2)
  PDX = -1
}

fn repaint_band(x0: int, y0: int, x1: int, y1: int) {
  if x0 < 0 { x0 = 0 }
  if y0 < 0 { y0 = 0 }
  if x1 > WIDTH { x1 = WIDTH }
  if y1 > TASKBAR_Y { y1 = TASKBAR_Y }
  if x0 >= x1 || y0 >= y1 { return }
  BX0 = x0
  BY0 = y0
  BX1 = x1
  BY1 = y1
  let y = y0
  while y < y1 {
    fb_fill(x0, y, x1 - x0, 1, sky_colour(y))
    y = y + 1
  }
  if x0 < 200 && y0 < 970 { draw_desktop_items() }
  # Only the band can be seen, so the runtime's fills and glyphs both stop at
  # its edges: a glyph painted past the band lands outside the window being
  # repainted, stays in the back buffer and reappears on a later frame.
  fb_clip(x0, y0, x1, y1)
  let k = 0
  while k < NORD {
    let i = ORDER[k]
    if W_ON[i] == 1 && hits(W_X[i], W_Y[i], W_W[i], W_H[i]) == 1 {
      draw_window(i)
    }
    k = k + 1
  }
  fb_clip(0, 0, WIDTH, HEIGHT)
  draw_pointer()
  damage(x0, y0, x1, y1)
}

fn repaint_window(i: int) {
  hide_pointer()
  repaint_band(W_X[i] - 24, W_Y[i] - 24,
               W_X[i] + W_W[i] + 24, W_Y[i] + W_H[i] + 24)
}

# Add a rectangle to this frame's damage union.  Drawing is composed in the
# back buffer, so nothing here reaches the screen; the loop copies the union
# once, with frame(), and a repaint cannot be seen half-erased.
fn damage(x0: int, y0: int, x1: int, y1: int) {
  if x0 < 0 { x0 = 0 }
  if y0 < 0 { y0 = 0 }
  if x1 > WIDTH { x1 = WIDTH }
  if y1 > HEIGHT { y1 = HEIGHT }
  if x0 >= x1 || y0 >= y1 { return }
  if DNONE == 1 {
    DX0 = x0
    DY0 = y0
    DX1 = x1
    DY1 = y1
    DNONE = 0
    return
  }
  if x0 < DX0 { DX0 = x0 }
  if y0 < DY0 { DY0 = y0 }
  if x1 > DX1 { DX1 = x1 }
  if y1 > DY1 { DY1 = y1 }
}

# Copy this frame's damage to the screen, once.
fn frame() {
  if DNONE == 1 { return }
  DNONE = 1
  fb_present(DX0, DY0, DX1, DY1)
}

# The runtime paints console cells as text arrives, but it does not know what
# covers them.  Flush the cells it touched: present them when the terminal is
# on top, and repaint their band through the z-order when it is not, so no
# glyph can land over a window above it.
fn term_flush() {
  let d = console_dirty()
  if d == 0 { return }
  let t = win_kind_at_kind(K_TERM)
  if t < 0 { return }
  d = d - 1
  let ox = W_X[t] + 16
  let oy = W_Y[t] + 48
  let x0 = ox + (d & 255) * CELL_W
  let y0 = oy + ((d >> 8) & 255) * CELL_H
  let x1 = ox + (((d >> 16) & 255) + 1) * CELL_W
  let y1 = oy + (((d >> 24) & 255) + 1) * CELL_H
  if order_find(t) == NORD - 1 {
    damage(x0, y0, x1, y1)
  } else {
    repaint_band(x0, y0, x1, y1)
  }
}

fn open_app(kind: int) {
  let i = win_open(kind)
  if kind == K_TERM {
    print("\n[terminal]\n")
    if i >= 0 { console_place(W_X[i] + 16, W_Y[i] + 48) }
  } else if kind == K_EDIT {
    print("\n[editor]\n")
  } else if kind == K_FILES {
    print("\n[files]\n")
  } else if kind == K_PAINT {
    print("\n[paint]\n")
  } else if kind == K_IMG {
    viewer_load(i)
    if VHAVE == 1 {
      print("\n[viewer] art\n")
    } else {
      print("\n[viewer] empty\n")
    }
  } else {
    print("\n[system]\n")
  }
  redraw_desktop()
}

fn close_app(i: int) {
  let k = W_KIND[i]
  win_remove(i)
  if k == K_TERM { print("\n[close]\n") }
  redraw_desktop()
}

# ---------------------------------------------------------------- mouse
# The cursor is a polygon of 16 row spans, drawn four times one pixel off in
# each direction in black and once in white: a smooth arrow with an outline.
fn pointer_shape(x: int, y: int, dx: int, dy: int, c: int) {
  let ox = x + dx
  let oy = y + dy
  span8((ox + 1) * 8, (ox + 3) * 8, oy + 0, c)
  span8((ox + 1) * 8, (ox + 6) * 8, oy + 1, c)
  span8((ox + 1) * 8, (ox + 9) * 8, oy + 2, c)
  span8((ox + 1) * 8, (ox + 11) * 8, oy + 3, c)
  span8((ox + 1) * 8, (ox + 12) * 8, oy + 4, c)
  span8((ox + 1) * 8, (ox + 13) * 8, oy + 5, c)
  span8((ox + 1) * 8, (ox + 14) * 8, oy + 6, c)
  span8((ox + 1) * 8, (ox + 14) * 8, oy + 7, c)
  span8((ox + 1) * 8, (ox + 13) * 8, oy + 8, c)
  span8((ox + 1) * 8, (ox + 11) * 8, oy + 9, c)
  span8((ox + 3) * 8, (ox + 10) * 8, oy + 10, c)
  span8((ox + 4) * 8, (ox + 10) * 8, oy + 11, c)
  span8((ox + 4) * 8, (ox + 9) * 8, oy + 12, c)
  span8((ox + 5) * 8, (ox + 9) * 8, oy + 13, c)
  span8((ox + 5) * 8, (ox + 8) * 8, oy + 14, c)
  span8((ox + 6) * 8, (ox + 8) * 8, oy + 15, c)
}

# Erase the old cursor by putting back the saved pixels, remember the patch
# under the new position, then stamp outline and fill.
fn draw_pointer() {
  if PDX >= 0 {
    # The erase has to reach the screen as well, or the last position keeps its
    # arrow while the new one is drawn next to it.
    damage(PDX - 2, PDY - 2, PDX + PCW - 2, PDY + PCW - 2)
    let i = 0
    while i < PCW {
      let j = 0
      while j < PCW {
        poke32(FBP + (PDY - 2 + i) * PITCH + (PDX - 2 + j) * 4,
               PBG[i * PCW + j])
        j = j + 1
      }
      i = i + 1
    }
  }
  let x = MX
  let y = MY
  if x < 2 { x = 2 }
  if y < 2 { y = 2 }
  if x > WIDTH - PCW { x = WIDTH - PCW }
  if y > HEIGHT - PCW { y = HEIGHT - PCW }
  PDX = x
  PDY = y
  damage(x - 2, y - 2, x + PCW - 2, y + PCW - 2)
  let r = 0
  while r < PCW {
    let c = 0
    while c < PCW {
      PBG[r * PCW + c] = peek32(FBP + (y - 2 + r) * PITCH + (x - 2 + c) * 4)
      c = c + 1
    }
    r = r + 1
  }
  pointer_shape(x, y, -1, 0, 0x000000)
  pointer_shape(x, y, 1, 0, 0x000000)
  pointer_shape(x, y, 0, -1, 0x000000)
  pointer_shape(x, y, 0, 1, 0x000000)
  pointer_shape(x, y, 0, 0, 0xffffff)
}

fn aux_wait() -> int {
  let i = 0
  while i < 100000 {
    if (inb(100) & 1) == 1 { return 1 }
    i = i + 1
  }
  return 0
}

# 0xD4 prefixes the next byte to the auxiliary device; every command answers
# 0xFA, which a missing mouse never sends.
fn mouse_cmd(c: int) -> int {
  outb(100, 212)
  outb(96, c)
  if aux_wait() == 0 { return 0 }
  if inb(96) == 250 { return 1 }
  return 0
}

fn mouse_init() -> int {
  let i = 0
  while i < 64 {
    if (inb(100) & 1) == 1 { inb(96) }
    i = i + 1
  }
  outb(100, 168)                # 0xa8: enable the auxiliary port
  outb(100, 32)                 # 0x20: read the controller config byte
  if aux_wait() == 0 { return 0 }
  let cfg = inb(96)
  cfg = cfg & 223               # 0xdf: clear "aux clock disabled"
  outb(100, 96)                 # 0x60: write it back
  outb(96, cfg)
  if mouse_cmd(246) == 0 { return 0 }   # 0xf6: set defaults
  if mouse_cmd(244) == 0 { return 0 }   # 0xf4: enable data reporting
  return 1
}

# One byte of a PS/2 packet; returns 1 when it completes a left-button press
# edge.  A packet is three bytes and its first byte has bit 3 set.
fn mouse_byte(b: int) -> int {
  if MPKT == 0 && (b & 8) == 0 { return 0 }
  MBYTES[MPKT] = b
  MPKT = MPKT + 1
  if MPKT < 3 { return 0 }
  MPKT = 0
  let flags = MBYTES[0]
  let dx = MBYTES[1]
  let dy = MBYTES[2]
  if (flags & 16) == 16 { dx = dx - 256 }
  if (flags & 32) == 32 { dy = dy - 256 }
  # Overflow bits mean the motion did not fit in a byte; the rest of the packet
  # is still good, so drop the delta and keep the button state.
  if (flags & 192) != 0 {
    dx = 0
    dy = 0
  }
  if dx != 0 || dy != 0 {
    MX = MX + dx
    MY = MY - dy
    if MX < 0 { MX = 0 }
    if MX > WIDTH - 1 { MX = WIDTH - 1 }
    if MY < 0 { MY = 0 }
    if MY > HEIGHT - 1 { MY = HEIGHT - 1 }
    MMOVED = 1
  }
  let left = flags & 1
  let clicked = 0
  if left == 1 && MBTN == 0 { clicked = 1 }
  MBTN = left
  return clicked
}

# Drain both PS/2 ports before repainting.  A polled controller that is read
# once per frame loses bytes while the screen is drawn, and a lost motion byte
# shifts every later packet: the pointer then trails the one you are aiming
# with, clicks land on the window underneath, and keys arrive swapped.  So
#  every pending byte is consumed first, and the screen is painted once after.
#
# A packet whose remaining bytes never arrive lost a byte on the way in, so
# the next packet's flag byte is taken for a motion byte and every later packet
# is shifted: the pointer jumps and a click lands where it was aimed a frame
# ago.  The bytes of one packet arrive back to back, so a gap mid-packet means
# a lost byte, and dropping the partial packet resynchronises on the next one.
fn mouse_idle_reset() {
  if MPKT == 0 { return }
  let i = 0
  while i < 4000 {
    if (inb(100) & 1) == 1 { return }
    i = i + 1
  }
  MPKT = 0
}

fn pump_input() {
  let n = 0
  while n < 96 {
    let st = inb(100)
    if (st & 1) != 1 {
      mouse_idle_reset()
      return
    }
    if (st & 32) == 32 {
      if mouse_byte(inb(96)) == 1 {
        handle_click()
      }
    } else {
      handle_key(inb(96))
    }
    n = n + 1
  }
  mouse_idle_reset()
}

# ---------------------------------------------------------------- clicks
fn in_round(cx: int, cy: int, r: int) -> int {
  let dx = MX - cx
  let dy = MY - cy
  if dx * dx + dy * dy <= r * r { return 1 }
  return 0
}

fn in_title_bar(x: int, y: int, w: int) -> int {
  if MY < y || MY >= y + TITLE_H { return 0 }
  if MX < x || MX >= x + w - 60 { return 0 }
  return 1
}

fn open_editor_for() {
  let i = win_open(K_EDIT)
  if NN == 0 { name_default() }
  let n = fs_load(0)
  if n < 0 {
    ELEN = 0
    EDIRTY = 1
    print("[new] ")
  } else {
    ELEN = n
    EDIRTY = 0
    print("[edit] ")
  }
  ECUR = ELEN
  ETOP = 0
  print_name()
  print(" ")
  print(ELEN)
  print("\n")
  editor_fix_scroll()
  if i >= 0 { repaint_window(i) }
}

fn files_click(i: int) {
  let y0 = W_Y[i] + TITLE_H + 44
  if MY < y0 { return }
  let row = (MY - y0) / 26
  let seen = 0
  let n = 0
  while n < MAX_FILES {
    if fs_entry_used(n) == 1 {
      if seen == row {
        let k = 0
        while k < 20 && dget(n * 32 + k) != 0 {
          NB[k] = dget(n * 32 + k)
          k = k + 1
        }
        NN = k
        if NN > 0 {
          open_editor_for()
        }
        return
      }
      seen = seen + 1
    }
    n = n + 1
  }
}

# Topmost window first: its close button, then its title bar, then its client.
fn click_window() -> int {
  let k = NORD - 1
  while k >= 0 {
    let i = ORDER[k]
    if W_ON[i] == 1 {
      let x = W_X[i]
      let y = W_Y[i]
      let w = W_W[i]
      let h = W_H[i]
      # Containment first: a window only reacts to a point inside it, so the
      # close circle of a window the pointer is next to cannot fire.
      if MX >= x && MX < x + w && MY >= y && MY < y + h {
        if in_round(x + w - 32, y + 20, 16) == 1 {
          close_app(i)
          return 1
        }
        if FOCUS != i {
          win_raise(i)
          redraw_desktop()
        } else {
          win_raise(i)
        }
        if in_title_bar(x, y, w) == 1 {
          DRAG = 1
          DRAG_WIN = i
          GRAB_DX = MX - x
          GRAB_DY = MY - y
        } else if W_KIND[i] == K_FILES {
          files_click(i)
        } else if W_KIND[i] == K_IMG {
          viewer_zoom(i)
        } else if W_KIND[i] == K_PAINT {
          paint_click(i)
        }
        return 1
      }
    }
    k = k - 1
  }
  return 0
}

fn handle_click() {
  if click_window() == 1 { return }
  if in_round(110, 130, 46) == 1 {
    open_app(K_TERM)
    return
  }
  if in_round(110, 280, 46) == 1 {
    open_app(K_EDIT)
    return
  }
  if in_round(110, 430, 46) == 1 {
    open_app(K_FILES)
    return
  }
  if in_round(110, 580, 46) == 1 {
    open_app(K_SYS)
    return
  }
  if in_round(110, 730, 46) == 1 {
    open_app(K_PAINT)
    return
  }
  if in_round(110, 880, 46) == 1 {
    open_app(K_IMG)
    return
  }
  if MY >= 990 && MY < 1018 {
    if MX >= 24 && MX < 210 {
      open_app(K_TERM)
    } else if MX >= 222 && MX < 372 {
      open_app(K_EDIT)
    } else if MX >= 384 && MX < 514 {
      open_app(K_FILES)
    } else if MX >= 526 && MX < 676 {
      open_app(K_SYS)
    } else if MX >= 688 && MX < 828 {
      open_app(K_PAINT)
    } else if MX >= 840 && MX < 980 {
      open_app(K_IMG)
    }
  }
}

# Drag the grabbed window by the point that was grabbed, and keep it on the
# desktop above the taskbar.
fn drag_window() {
  let i = DRAG_WIN
  if i < 0 {
    DRAG = 0
    return
  }
  if W_ON[i] == 0 {
    DRAG = 0
    return
  }
  let ox = W_X[i]
  let oy = W_Y[i]
  let w = W_W[i]
  let h = W_H[i]
  let nx = MX - GRAB_DX
  let ny = MY - GRAB_DY
  if nx < 4 { nx = 4 }
  if ny < 4 { ny = 4 }
  if nx > WIDTH - w - 4 { nx = WIDTH - w - 4 }
  if ny > TASKBAR_Y - h - 4 { ny = TASKBAR_Y - h - 4 }
  if nx == ox && ny == oy { return }
  W_X[i] = nx
  W_Y[i] = ny
  let x0 = ox
  if nx < x0 { x0 = nx }
  let y0 = oy
  if ny < y0 { y0 = ny }
  let x1 = ox
  if nx > x1 { x1 = nx }
  let y1 = oy
  if ny > y1 { y1 = ny }
  hide_pointer()
  repaint_band(x0 - 24, y0 - 24, x1 + w + 24, y1 + h + 24)
}

# ---------------------------------------------------------------- filesystem
# TLFS: a superblock, a 16-entry directory and fixed 16-sector slots.  The
# whole directory fits in one sector, so a save is two writes: the data sectors
# and then the directory entry that makes them visible.
fn name_default() {
  let s = "untitled"
  let i = 0
  while i < len(s) {
    NB[i] = s[i]
    i = i + 1
  }
  NN = len(s)
}

fn name_take(from: int, n: int) {
  let i = 0
  while i < n && i < 19 {
    NB[i] = BUF[from + i]
    i = i + 1
  }
  NN = i
}

fn print_name() {
  let i = 0
  while i < NN {
    print_char(NB[i])
    i = i + 1
  }
}

fn fs_name_eq(i: int) -> int {
  let k = 0
  while k < 20 {
    let a = dget(i * 32 + k)
    let b = 0
    if k < NN { b = NB[k] }
    if a != b { return 0 }
    k = k + 1
  }
  return 1
}

fn fs_entry_used(i: int) -> int {
  if dget(i * 32 + 20) != 0 { return 1 }
  if dget(i * 32 + 21) != 0 { return 1 }
  if dget(i * 32 + 22) != 0 { return 1 }
  if dget(i * 32 + 23) != 0 { return 1 }
  let k = 0
  while k < 20 {
    if dget(i * 32 + k) != 0 { return 1 }
    k = k + 1
  }
  return 0
}

fn dir_get_size(i: int) -> int {
  let n = dget(i * 32 + 20)
  n = n | (dget(i * 32 + 21) << 8)
  n = n | (dget(i * 32 + 22) << 16)
  n = n | (dget(i * 32 + 23) << 24)
  return n
}

fn dir_set_size(i: int, n: int) {
  dput(i * 32 + 20, n & 255)
  dput(i * 32 + 21, (n >> 8) & 255)
  dput(i * 32 + 22, (n >> 16) & 255)
  dput(i * 32 + 23, (n >> 24) & 255)
}

fn fs_count() -> int {
  let i = 0
  let n = 0
  while i < MAX_FILES {
    if fs_entry_used(i) == 1 { n = n + 1 }
    i = i + 1
  }
  return n
}

fn fs_format() {
  let i = 0
  while i < 512 {
    sput(i, 0)
    dput(i, 0)
    i = i + 1
  }
  sput(0, 84)                  # 'T'
  sput(1, 76)                  # 'L'
  sput(2, 70)                  # 'F'
  sput(3, 83)                  # 'S'
  sput(4, 1)                   # version
  if ata_write(0, 1, SBUF_A) < 0 || ata_write(1, 1, DSEC_A) < 0 {
    FS_OK = 0
    print("[fs] disk error\n")
    return
  }
  FS_OK = 1
  print("[fs] formatted\n")
}

# A missing or failing disk must not look like an empty one: formatting on a
# failed read destroys a directory that was fine, so the write result decides.
fn fs_init() {
  if ata_read(0, 1, SBUF_A) < 0 {
    FS_OK = 0
    print("[fs] disk error\n")
    return
  }
  if sget(0) != 84 || sget(1) != 76 || sget(2) != 70 || sget(3) != 83 {
    fs_format()
    return
  }
  if ata_read(1, 1, DSEC_A) < 0 {
    FS_OK = 0
    print("[fs] disk error\n")
    return
  }
  FS_OK = 1
  print("[fs] ")
  print(fs_count())
  print(" files\n")
}

fn fs_find() -> int {
  let i = 0
  while i < MAX_FILES {
    if fs_entry_used(i) == 1 && fs_name_eq(i) == 1 { return i }
    i = i + 1
  }
  return -1
}

# Save NB/NN from memory at src.  Returns 0, -1 for a file too large, -2 when
# every directory entry is taken.
fn fs_save(sel: int, n: int) -> int {
  if FS_OK == 0 { return -4 }
  if n > 8192 { return -1 }
  if n < 0 { n = 0 }
  let i = fs_find()
  if i < 0 {
    i = -1
    let k = 0
    while k < MAX_FILES {
      if fs_entry_used(k) == 0 && i < 0 { i = k }
      k = k + 1
    }
    if i < 0 { return -2 }
    let z = 0
    while z < 32 {
      dput(i * 32 + z, 0)
      z = z + 1
    }
  }
  return fs_store(i, sel, n)
}

# The data sectors go out first and the directory entry last, so the entry
# that makes them visible is never ahead of the bytes it points at: a machine
# that dies between the two still has the old size, not a torn file.
fn fs_store(i: int, sel: int, n: int) -> int {
  let base = FS_DATA + i * SLOT_SECTORS
  let done = 0
  let s = 0
  while done < n {
    let c = 0
    while c < 512 {
      let p = done + c
      if p < n {
        let b = 0
        if sel == 0 { b = EB[p] } else if sel == 2 { b = aget(p) } else { b = BUF[SB_BASE + p] }
        sput(c, b)
      } else {
        sput(c, 0)
      }
      c = c + 1
    }
    if ata_write(base + s, 1, SBUF_A) < 0 { return -5 }
    done = done + 512
    s = s + 1
  }
  let k = 0
  while k < 20 {
    if k < NN { dput(i * 32 + k, NB[k]) } else { dput(i * 32 + k, 0) }
    k = k + 1
  }
  dir_set_size(i, n)
  if ata_write(1, 1, DSEC_A) < 0 { return -5 }
  return 0
}

# The size comes back from a sector the kernel did not just write, so it is
# clamped before anything indexes with it: a corrupt entry used to read past
# the disk and past the buffer that receives the file.
fn fs_load(sel: int) -> int {
  if FS_OK == 0 { return -4 }
  let i = fs_find()
  if i < 0 { return -1 }
  let n = dir_get_size(i)
  if n < 0 { n = 0 }
  if n > 8192 { n = 8192 }
  let base = FS_DATA + i * SLOT_SECTORS
  let done = 0
  let s = 0
  while done < n {
    if ata_read(base + s, 1, SBUF_A) < 0 { return -5 }
    let c = 0
    while c < 512 && done + c < n {
      let v = sget(c)
      if sel == 0 {
        EB[done + c] = v
      } else if sel == 1 {
        rput(done + c, v)
      } else if sel == 2 {
        aput(done + c, v)
      } else {
        vput(done + c, v)
      }
      c = c + 1
    }
    done = done + 512
    s = s + 1
  }
  return n
}

fn fs_delete() -> int {
  let i = fs_find()
  if i < 0 { return -1 }
  let k = 0
  while k < 32 {
    dput(i * 32 + k, 0)
    k = k + 1
  }
  if ata_write(1, 1, DSEC_A) < 0 { return -5 }
  return 0
}

fn fs_list() {
  let n = fs_count()
  if n == 0 {
    print("files: none\n")
    return
  }
  print("files\n")
  let i = 0
  while i < MAX_FILES {
    if fs_entry_used(i) == 1 {
      print("  ")
      let k = 0
      while k < 20 && dget(i * 32 + k) != 0 {
        print_char(dget(i * 32 + k))
        k = k + 1
      }
      print("  ")
      print(dir_get_size(i))
      print("\n")
    }
    i = i + 1
  }
}

# ---------------------------------------------------------------- editor
fn editor_cursor_line() -> int {
  let i = 0
  let line = 0
  while i < ECUR {
    if EB[i] == 10 { line = line + 1 }
    i = i + 1
  }
  return line
}

fn editor_line_begin(target: int) -> int {
  if target <= 0 { return 0 }
  let i = 0
  let line = 0
  while i < ELEN {
    if EB[i] == 10 {
      line = line + 1
      if line == target { return i + 1 }
    }
    i = i + 1
  }
  return ELEN
}

fn editor_fix_scroll() {
  if FOCUS < 0 { return }
  if W_ON[FOCUS] == 0 { return }
  let rows = ed_rows(FOCUS)
  let line = editor_cursor_line()
  if line < ETOP { ETOP = line }
  if line >= ETOP + rows { ETOP = line - rows + 1 }
  if ETOP < 0 { ETOP = 0 }
}

fn editor_line_start() -> int {
  let i = 0
  let start = 0
  while i < ECUR {
    if EB[i] == 10 { start = i + 1 }
    i = i + 1
  }
  return start
}

fn editor_insert(c: int) {
  if ELEN >= 8192 { return }
  let i = ELEN
  while i > ECUR {
    EB[i] = EB[i - 1]
    i = i - 1
  }
  EB[ECUR] = c
  ECUR = ECUR + 1
  ELEN = ELEN + 1
  EDIRTY = 1
}

fn editor_back() {
  if ECUR == 0 { return }
  let i = ECUR
  while i < ELEN {
    EB[i - 1] = EB[i]
    i = i + 1
  }
  ECUR = ECUR - 1
  ELEN = ELEN - 1
  EDIRTY = 1
}

fn editor_left() {
  if ECUR > 0 { ECUR = ECUR - 1 }
}

fn editor_right() {
  if ECUR < ELEN { ECUR = ECUR + 1 }
}

fn editor_up() {
  let line = editor_cursor_line()
  if line == 0 { return }
  let col = ECUR - editor_line_start()
  let start = editor_line_begin(line - 1)
  let end = editor_line_begin(line) - 1
  ECUR = start + col
  if ECUR > end { ECUR = end }
  if ECUR < start { ECUR = start }
}

fn editor_down() {
  let line = editor_cursor_line()
  let next = editor_line_begin(line + 1)
  if next >= ELEN { return }
  let col = ECUR - editor_line_start()
  let start = next
  let end = editor_line_begin(line + 2) - 1
  ECUR = start + col
  if ECUR > end { ECUR = end }
  if ECUR < start { ECUR = start }
}

fn editor_save() {
  if NN == 0 { name_default() }
  let r = fs_save(0, ELEN)
  if r == 0 {
    EDIRTY = 0
    print("[saved] ")
    print_name()
    print(" ")
    print(ELEN)
    print("\n")
  } else {
    print("[save failed] ")
    print(r)
    print("\n")
  }
}

fn editor_key(sc: int) {
  let i = FOCUS
  if i < 0 { return }
  let rows = ed_rows(i)
  let top0 = ETOP
  if CTRL == 1 {
    # a save prints into the terminal, so put the whole window back
    if sc == 31 {
      editor_save()
      repaint_window(i)
    }
    return
  }
  if sc == 224 { return }
  if sc == 28 {
    # Enter moves the rest of the line down: every row below the cursor changes
    editor_insert(10)
    editor_fix_scroll()
    if ETOP != top0 { repaint_editor_rows(i, 0, rows - 1) }
    else { repaint_editor_rows(i, editor_cursor_line() - ETOP, rows - 1) }
    return
  }
  if sc == 14 {
    if ECUR == 0 { return }
    let before = editor_cursor_line()
    editor_back()
    editor_fix_scroll()
    if ETOP != top0 { repaint_editor_rows(i, 0, rows - 1) }
    else {
      let first = before - ETOP
      if editor_cursor_line() - ETOP < first { first = editor_cursor_line() - ETOP }
      repaint_editor_rows(i, first, rows - 1)
    }
    return
  }
  if sc == 75 || sc == 77 || sc == 72 || sc == 80 {
    let was = editor_cursor_line() - ETOP
    if sc == 75 { editor_left() }
    else if sc == 77 { editor_right() }
    else if sc == 72 { editor_up() }
    else { editor_down() }
    editor_fix_scroll()
    if ETOP != top0 { repaint_editor_rows(i, 0, rows - 1) }
    else {
      let now = editor_cursor_line() - ETOP
      let first = was
      if now < first { first = now }
      let last = was
      if now > last { last = now }
      repaint_editor_rows(i, first, last)
    }
    return
  }
  let c = key_char(sc, SHIFT)
  if c == 0 { return }
  editor_insert(c)
  editor_fix_scroll()
  if ETOP != top0 { repaint_editor_rows(i, 0, rows - 1) }
  else {
    let row = editor_cursor_line() - ETOP
    repaint_editor_rows(i, row, row)
  }
}

# ---------------------------------------------------------------- terminal
fn line_eq(n: int, word: str) -> int {
  if n != len(word) { return 0 }
  for i in 0..n {
    if BUF[i] != word[i] { return 0 }
  }
  return 1
}

fn line_has_prefix(n: int, word: str) -> int {
  let m = len(word)
  if n < m { return 0 }
  for i in 0..m {
    if BUF[i] != word[i] { return 0 }
  }
  return 1
}

fn print_bytes(from: int, to: int) {
  let i = from
  while i < to {
    print_char(BUF[i])
    i = i + 1
  }
}

fn cmd_help() {
  print("commands\n")
  print("  help          this list\n")
  print("  about         this kernel\n")
  print("  echo TEXT     print TEXT back\n")
  print("  ls            list files\n")
  print("  cat NAME      print a file\n")
  print("  write N TEXT  save TEXT to N\n")
  print("  rm NAME       delete a file\n")
  print("  edit NAME     open it in the editor\n")
  print("  clear         blank the window\n")
  print("  ticks         rdtsc count\n")
  print("  halt          stop the machine\n")
}

fn cmd_about() {
  print("tlang desktop 0.3\n")
  print("x86-64, ring 0, no Linux.\n")
  print("video VBE 1280x1024x32.\n")
  print("fs TLFS on disk 1: 16 files,\n")
  print("8 KiB each, survives a reboot.\n")
  print("paint    draw, ctrl+s saves as art.\n")
  print("viewer   show the saved canvas.\n")
}

# Split "write NAME TEXT" into a name and a body; returns the body offset.
fn arg_start(from: int, n: int) -> int {
  let i = from
  while i < n && BUF[i] != 32 {
    i = i + 1
  }
  if i < n { i = i + 1 }
  return i
}

fn run_command(n: int) {
  if n == 0 {
    print("")
  } else if line_eq(n, "help") {
    cmd_help()
  } else if line_eq(n, "about") {
    cmd_about()
  } else if line_eq(n, "ls") {
    fs_list()
  } else if line_eq(n, "echo") {
    print("\n")
  } else if line_has_prefix(n, "echo ") {
    print_bytes(5, n)
    print("\n")
  } else if line_eq(n, "clear") {
    print_char(12)
  } else if line_eq(n, "ticks") {
    print(rdtsc())
    print("\n")
  } else if line_eq(n, "halt") {
    print("halt\n")
    outb(0xf4, 0x10)          # QEMU's isa-debug-exit, when a test provides it
    while 1 { hlt() }
  } else if line_has_prefix(n, "write ") {
    let body = arg_start(6, n)
    name_take(6, body - 7)
    if NN == 0 {
      print("usage: write NAME TEXT\n")
    } else {
      SB_BASE = body
      let r = fs_save(1, n - body)
      if r == 0 {
        print("[saved] ")
        print_name()
        print(" ")
        print(n - body)
        print("\n")
      } else {
        print("save failed: ")
        print(r)
        print("\n")
      }
    }
  } else if line_has_prefix(n, "cat ") {
    name_take(4, n - 4)
    let got = fs_load(1)
    if got < 0 {
      print("no such file: ")
      print_name()
      print("\n")
    } else {
      let i = 0
      while i < got {          print_char(rget(i))
          i = i + 1
        }
        if got == 0 || rget(got - 1) != 10 { print("\n") }
    }
  } else if line_has_prefix(n, "rm ") {
    name_take(3, n - 3)
    if fs_delete() == 0 {
      print("[removed] ")
      print_name()
      print("\n")
    } else {
      print("no such file: ")
      print_name()
      print("\n")
    }
  } else if line_has_prefix(n, "edit ") {
    name_take(5, n - 5)
    if NN == 0 { name_default() }
    open_editor_for()
  } else {
    print("unknown command: ")
    print_bytes(0, n)
    print("\n")
  }
}

fn term_key(sc: int) {
  if sc == 28 {
    print_char(10)
    run_command(LINE_N)
    LINE_N = 0
    print("tlang> ")
    return
  }
  if sc == 14 {
    if LINE_N > 0 {
      LINE_N = LINE_N - 1
      print_char(8)
    }
    return
  }
  if sc == 224 { return }
  let c = key_char(sc, SHIFT)
  if c != 0 && LINE_N < 255 {
    BUF[LINE_N] = c
    LINE_N = LINE_N + 1
    print_char(c)
  }
}

# Modifiers are tracked for every app; everything else goes to the focused one.
fn handle_key(sc: int) {
  if sc == 42 || sc == 54 {
    SHIFT = 1
    return
  }
  if sc == 170 || sc == 182 {
    SHIFT = 0
    return
  }
  if sc == 29 {
    CTRL = 1
    return
  }
  if sc == 157 {
    CTRL = 0
    return
  }
  if (sc & 128) != 0 { return }
  if FOCUS < 0 { return }
  if W_ON[FOCUS] == 0 { return }
  if W_KIND[FOCUS] == K_EDIT {
    editor_key(sc)
    return
  }
  if W_KIND[FOCUS] == K_IMG {
    viewer_key(sc)
    return
  }
  if W_KIND[FOCUS] == K_PAINT {
    paint_key(sc)
    return
  }
  if W_KIND[FOCUS] == K_TERM { term_key(sc) }
}

fn main() {
  FBP = fb_back()
  name_default()
  art_init()
  draw_wallpaper()
  draw_taskbar()
  let t = win_open(K_TERM)
  print("[terminal]\n")
  fs_init()
  if mouse_init() == 1 {
    print("mouse: ready\n")
  } else {
    print("mouse: absent\n")
  }
  draw_window(t)
  draw_pointer()
  damage(0, 0, WIDTH, HEIGHT)
  frame()
  print("tlang desktop 0.3\n")
  print("type help, or click an icon.\n")
  print("tlang> ")
  while 1 {
    if MBTN == 0 {
      DRAG = 0
      PAINTING = 0
    }
    pump_input()
    if MMOVED == 1 {
      if PAINTING == 1 && MBTN == 1 {
        paint_at(win_kind_at_kind(K_PAINT))
        draw_pointer()
      } else if DRAG == 1 {
        drag_window()
      } else {
        draw_pointer()
      }
      MMOVED = 0
    }
    term_flush()
    frame()
  }
}
