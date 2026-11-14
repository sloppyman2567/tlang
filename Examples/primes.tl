fn is_prime(n) {
  if n < 2 { return 0 }
  let d = 2
  while d * d <= n {
    if n % d == 0 { return 0 }
    d = d + 1
  }
  return 1
}

fn main() {
  let n = 2
  let found = 0
  while found < 20 {
    if is_prime(n) == 1 {
      print_int(n)
      print(" ")
      found = found + 1
    }
    n = n + 1
  }
  print("\n")
}
