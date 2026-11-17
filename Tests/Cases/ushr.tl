# >>> is a logical shift: unlike >>, it does not sign-extend a negative value.
fn main() {
  print_int(-1 >>> 60)
  print("\n")
  print_int(-8 >>> 1)
  print("\n")
  print_int(-1 >> 1)
  print("\n")
  let x = -1
  x >>>= 60
  print_int(x)
  print("\n")
  let n = 64
  print_int(1 >>> n)
  print("\n")
}
