fn main() {
  let i = 1
  while i <= 20 {
    if i % 15 == 0 { print("FizzBuzz\n") }
    else if i % 3 == 0 { print("Fizz\n") }
    else if i % 5 == 0 { print("Buzz\n") }
    else { print_int(i); print("\n") }
    i = i + 1
  }
}
