import "../../Modules/twayland.tl"

# Protocol test program: waits for the three input events the fake compositor
# sends, then prints everything the module recorded.

fn main() {
  if tw_open(64, 48, "twtest") == 0 {
    print("open failed\n")
    return
  }
  let got = 0
  let tries = 0
  while got != 7 && tries < 40 {
    let e = tw_poll(100)
    if e < 0 {
      tries = 40
    }
    if e == 1 && TW_KEY == 16 && TW_KEY_STATE == 1 { got = got | 1 }
    if e == 2 && TW_MOUSE_X == 10 && TW_MOUSE_Y == 20 { got = got | 2 }
    if e == 3 && TW_BUTTON == 272 && TW_BUTTON_STATE == 1 { got = got | 4 }
    tries = tries + 1
  }
  print("caps ")
  print_int(TW_CAPS)
  print(" key ")
  print_int(TW_KEY)
  print(" ")
  print_int(TW_KEY_STATE)
  print(" motion ")
  print_int(TW_MOUSE_X)
  print(" ")
  print_int(TW_MOUSE_Y)
  print(" button ")
  print_int(TW_BUTTON)
  print(" ")
  print_int(TW_BUTTON_STATE)
  print(" got ")
  print_int(got)
  print("\n")
}
