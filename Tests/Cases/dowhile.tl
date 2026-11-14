fn main() {
  let i = 0
  do {
    print_int(i)
    i = i + 1
    if i == 2 { continue }
    if i == 4 { break }
  } while i < 5
  print("\n")

  let once = 0
  do {
    once = once + 1
  } while once < 0
  print_int(once)
  print("\n")
}
