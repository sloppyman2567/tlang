let g = 0

fn classify(s: str) -> int {
  switch s {
    case "zero" { return 0 }
    case "one", "two" { return 1 }
    case "" { return 9 }
    else { return 2 }
  }
}

fn main() {
  g++
  ++g
  print_int(g)

  let i = 0
  let seen = 0
  while i < 6 {
    i++
    switch i {
      case 1 { }
      case 3 { switch i + 1 { case 4 { seen += 100 } } }
      case 5 { g-- }
      case 6 { break }
      else { seen += 1 }
    }
    seen += 10
  }
  print(" ")
  print_int(seen)

  print(" ")
  print_int(classify("two"))
  print_int(classify(""))
  print_int(classify("zzz"))

  print(" ")
  let bytes = 0
  for b in "abc" {
    bytes += b
  }
  print_int(bytes)

  print(" ")
  let total = 0
  for x in [1, 2, 3] {
    switch x {
      case 1 { continue }
      case 2 { total += 2 }
      case 3 { total += 3 }
    }
    total += 100
  }
  print_int(total)
  print("\n")
}
