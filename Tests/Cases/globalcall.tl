# A global initializer may call a function that main never calls.
fn helper() -> int {
  return 7
}

let START = helper()

fn main() {
  print_int(START)
  print("\n")
}
