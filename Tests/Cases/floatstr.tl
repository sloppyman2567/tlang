# str() of a float prints six fractional digits, trims trailing zeros, and
# switches to exponent form once the integer part no longer fits in 64 bits.
fn value() {
  return 1.5
}

fn main() {
  print(str(1.5) + "\n")
  print(str(2.0) + "\n")
  print(str(-4.25) + "\n")
  print(str(0.0) + "\n")
  print(str(-0.0) + "\n")
  print(str(1.0 / 3.0) + "\n")
  print(str(sqrt(2.0)) + "\n")
  print(str(1e3) + "\n")
  print(str(2.5e-1) + "\n")
  print(str(1.0 / 0.0) + "\n")
  print(str(0.0 - 1.0 / 0.0) + "\n")
  print(str(fabs(0.0 / 0.0)) + "\n")
  print_int(len(str(3.14159)))
  print("\n")
  let f = 7.0 / 2.0
  print(str(f) + "|" + str(int(f)) + "\n")
  print(str(0.9999999) + "\n")
  print(str(-0.0000001) + "\n")
  print(str(9.3e12) + "\n")
  print(str(1e18) + "\n")
  print(str(1e19) + "\n")
  print(str(-1e19) + "\n")
  print_float(9.3e12)
  print("\n")
  print_float(1e19)
  print("\n")
  print(str(value()) + "\n")
}
