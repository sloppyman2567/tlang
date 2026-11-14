import "twayland.tl"

# Opens a real Wayland window, draws a few rectangles, and moves the blue one
# with the arrow keys or WASD. Esc or q quits. It presents at most 120 frames
# and reports how many reached the compositor. With no compositor it says so
# and exits 0 so the build tests can run it anywhere.

fn main() {
  if tw_open(384, 216, "twayland") == 0 {
    print("twayland: no compositor\n")
    return
  }
  let x = 16
  let y = 96
  let frames = 0
  let keys = 0
  while frames < 120 && tw_running() == 1 {
    let e = tw_poll(1)
    while e > 0 {
      if e == 1 && TW_KEY_STATE == 1 {
        keys = keys + 1
        if TW_KEY == 1 || TW_KEY == 16 {
          frames = 120
        }
        if TW_KEY == 105 || TW_KEY == 30 { x = x - 8 }
        if TW_KEY == 106 || TW_KEY == 32 { x = x + 8 }
        if TW_KEY == 103 || TW_KEY == 17 { y = y - 8 }
        if TW_KEY == 108 || TW_KEY == 31 { y = y + 8 }
      }
      e = tw_poll(0)
    }
    tw_clear(0x101820)
    tw_rect(16, 16, 64, 64, 0x40c060)
    tw_rect(96, 16, 64, 64, 0xc06040)
    tw_rect(x, y, 48, 24, 0x4040c0)
    tw_present()
    frames = frames + 1
  }
  print("twayland: ")
  print_int(TW_W)
  print("x")
  print_int(TW_H)
  print(", frames ")
  print_int(TW_FRAMES)
  print(", released ")
  print_int(TW_RELEASES)
  print(", keys ")
  print_int(keys)
  print("\n")
}
