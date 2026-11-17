# Dense integer switches use a jump table; sparse and string ones keep the
# compare chain.  Both must agree on fallthrough to the else arm.
fn dense(n: int) -> int {
  switch n {
    case 100 { return 1 }
    case 101, 102 { return 2 }
    case 103 { return 3 }
    case 104 { return 4 }
    else { return -1 }
  }
}

fn sparse(n: int) -> int {
  switch n {
    case 1 { return 10 }
    case 1000 { return 20 }
    case 2000 { return 30 }
    case 3000 { return 40 }
    else { return -1 }
  }
}

fn strsw(s: str) -> int {
  switch s {
    case "a" { return 1 }
    case "b" { return 2 }
    case "c" { return 3 }
    case "d" { return 4 }
    else { return 0 }
  }
}

fn main() {
  print_int(dense(100))
  print_int(dense(102))
  print_int(dense(105))
  print_int(sparse(1000))
  print_int(strsw("c"))
  print("\n")
}
