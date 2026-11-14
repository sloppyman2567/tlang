fn main() {
  let i = 0
  let sum = 0
  while i < 5 {
    i++
    sum += i
  }
  print_int(sum)
  print(" ")

  let j = 10
  j--
  j--
  print_int(j)
  print(" ")

  let k = 0
  ++k
  ++k
  --k
  print_int(k)
  print(" ")

  let n = 0
  for x in [3, 4, 5] {
    n++
  }
  print_int(n)
  print("\n")
}
