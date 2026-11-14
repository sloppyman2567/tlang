let count = 0
let label = "n"

fn bump(by: int) -> int {
  count = count + by
  return count
}

fn main() {
  bump(2)
  bump(3)
  print(label + "=" + count + "\n")
}
