# \xNN writes one byte by value, which is how a table lives in the literal
# instead of in code.  Hex digits are case-insensitive, and \x00 ends the
# string like \0 does: a string's length is the run up to the first zero.
fn main() {
  let s = "\x41\x42\x00\xff"
  print_int(len(s))
  print(" ")
  print(s)
  print("\n")
  print_int(s[0])
  print(" ")
  print_int(s[1])
  print("\n")
  print_int('\x4a')
  print(" ")
  print_int('\x7a')
  print("\n")

  # A byte table: the 4x5 digit '0' of a CHIP-8 font, five bytes.
  let glyph = "\xf0\x90\x90\x90\xf0"
  let i = 0
  while i < len(glyph) {
    print_int(glyph[i])
    print(" ")
    i++
  }
  print("\n")
}
