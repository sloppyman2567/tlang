fn classify(n) {
  if n < 0 { return -1 }
  if n == 0 { return 0 }
  return 1
}

fn main() {
  let i = 0
  while i < 10 {
    i = i + 1
    if i % 2 == 0 { continue }
    if i > 7 { break }
    print_int(i)
  }
  print("\n")
  print_int(classify(-5))
  print_int(classify(0))
  print_int(classify(5))
  print("\n")
  let x = 1
  if x == 1 { let x = 2; print_int(x) }
  print_int(x)
  print("\n")
  i = 0
  while i < 3 {
    if i == 1 { print("one ") } else { print("other ") }
    i = i + 1
  }
  print("\n")
}
