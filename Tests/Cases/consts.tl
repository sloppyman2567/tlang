# A const is a name for an int or string literal: it has no storage and no
# startup store, and it can be used above its own declaration.
const LIMIT = 3
const TAG = "tag"
const NEG = -2

struct Pair { n: int, s: str }

fn later() -> int {
  return LAST
}

fn main() {
  print(TAG)
  print(" ")
  print_int(NEG)
  print(" ")
  print_int(later())
  print("\n")

  let i = 0
  while i < LIMIT {
    print_int(i)
    print(" ")
    i++
  }
  print("\n")

  let p = Pair(LIMIT * 2, TAG)
  print_int(p.n)
  print(" ")
  print(p.s)
  print("\n")

  if TAG == "tag" {
    print("same\n")
  }
  switch LIMIT {
    case 3 { print("three\n") }
    else { print("other\n") }
  }
}

const LAST = 9
