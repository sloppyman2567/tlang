fn main() {
  let i = 0
  loop {
    i = i + 1
    if i == 2 { continue }
    if i == 5 { break }
    print_int(i)
  }
  print("\n")
}
