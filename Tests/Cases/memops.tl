fn main() {
  let b = newbuf(8)
  st8(b, 0, 65)                       # A
  st8(b, 1, 66)                       # B
  st8(b, 2, 67)                       # C
  st8(b, 3, 68)                       # D
  st8(b, 4, 0)

  # Overlapping copy to the right: the forward direction would replicate bytes.
  memmove(str_offset(b, 2), b, 4)
  print(b)
  print("\n")

  # Overlapping copy to the left.
  memmove(b, str_offset(b, 2), 4)
  print(b)
  print("\n")

  # A negative result is a signed difference, not a zero-extended 32-bit one.
  print_int(memcmp("abc", "abd", 3))
  print(" ")
  print_int(memcmp("abc", "abc", 3))
  print(" ")
  print_int(memcmp("abd", "abc", 3))
  print(" ")
  print_int(memcmp("abc", "zzz", 0))
  print("\n")
}
