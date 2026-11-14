# Bitwise operators: & | ^ << >> ~, their compound forms, and C precedence.

fn shift_left(a: int, n: int) -> int {
  return a << n
}

fn main() {
  print_int(12 & 10)
  print(" ")
  print_int(12 | 3)
  print(" ")
  print_int(12 ^ 10)
  print(" ")
  print_int(1 << 10)
  print(" ")
  print_int(-8 >> 1)
  print(" ")
  print_int(~0)
  print(" ")
  print_int(~5)
  print("\n")

  # C precedence: << binds tighter than +, and == tighter than &.
  print_int(1 << 2 + 1)
  print(" ")
  print_int(1 + 2 << 3)
  print(" ")
  print_int(12 & 10 == 10)
  print(" ")
  print_int(6 | 9 & 3)
  print(" ")
  print_int(1 ^ 2 | 3)
  print("\n")

  # A variable shift count has to arrive in cl.
  print_int(shift_left(3, 4))
  print(" ")
  let n = 5
  print_int(1 << n)
  print(" ")
  print_int(1024 >> n)
  print("\n")

  # Literals in both bases.
  print_int(0xFF)
  print(" ")
  print_int(0b1010_1010)
  print(" ")
  print_int(0b1111 & 0x0F)
  print("\n")

  # Compound forms.
  let x = 0b1010
  x &= 0b1100
  x |= 1
  x ^= 0b111
  x <<= 2
  x >>= 1
  print_int(x)
  print("\n")

  # The flag-set idiom, which is what the operators are for.
  let flags = 0
  flags |= 4
  flags |= 1
  if flags & 4 { print("r ") }
  if flags & 2 { print("w ") }
  flags &= ~4
  if flags & 4 { print("still ") }
  print_int(flags)
  print("\n")

  # Wrap-around: 63 bits then back to the sign bit.
  print_int(1 << 62)
  print(" ")
  print_int((1 << 62) << 1)
  print(" ")
  print_int(-1 >> 63)
  print("\n")
}
