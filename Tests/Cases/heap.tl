fn main() {
  let a = alloc(4)
  let i = 0
  while i < 4 {
    a[i] = i * i
    i = i + 1
  }
  i = 0
  while i < 4 {
    print_int(a[i])
    print(" ")
    i = i + 1
  }
  print("\n")
}
