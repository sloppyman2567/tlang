fn classify(n: int) -> int {
  switch n {
    case 0 { return 10 }
    case 1, 2 { return 20 }
    case -1 { return 30 }
    else { return 40 }
  }
  return 0
}

fn main() {
  let i = 0
  while i < 5 {
    print_int(classify(i))
    print(" ")
    i++
  }
  print("\n")

  let calls = 0
  let sel = calls
  calls++
  switch sel {
    case 0 { print("zero\n") }
    else { print("other\n") }
  }
  print_int(calls)
  print("\n")

  switch "b" {
    case "a" { print("A\n") }
    case "b" { print("B\n") }
    else { print("?\n") }
  }

  let total = 0
  for x in [1, 2, 3, 4, 5] {
    switch x {
      case 1 { continue }
      case 2 { total += 10 }
      case 3 { break }
      else { total += 1 }
    }
    total += 100
  }
  print_int(total)
  print("\n")
}
