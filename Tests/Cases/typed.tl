fn describe(name: str, n: int) -> str {
  if len(name) > 3 {
    return name + " is long"
  }
  return name + "=" + n
}

fn main() {
  print(describe("bob", 7) + "\n")
  print(describe("alice", 9) + "\n")
}
