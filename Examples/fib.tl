fn fib(n) {
  if n < 2 { return n }
  return fib(n - 1) + fib(n - 2)
}

fn main() {
  let i = 0
  while i <= 15 {
    print_int(fib(i))
    print(" ")
    i = i + 1
  }
  print("\n")
}
