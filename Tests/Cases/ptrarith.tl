fn main() {
  let a = alloc(4)
  a[0] = 10
  a[1] = 20
  a[2] = 30
  let p = a + 1
  print_int(p[0])
  print("\n")
  let q = 2 + a
  print_int(q[0])
  print("\n")
  print_int(p - a)
  print("\n")
  p += 1
  print_int(p[0])
  print("\n")
  p--
  print_int(p[0])
  print("\n")
}
