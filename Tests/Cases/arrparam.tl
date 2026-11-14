struct P { x, y }
struct B { nums: int[], names: str[] }

fn total(a: int[]) -> int {
  let s = 0
  for i in 0..len(a) {
    s = s + a[i]
  }
  return s
}

fn add(a: int[], x: int) -> int[] {
  return append(a, x)
}

fn make() -> int[] {
  return alloc(0)
}

fn join(a: str[]) -> str {
  let out = ""
  for i in 0..len(a) {
    out = out + a[i]
  }
  return out
}

fn sum_pairs(a: P[]) -> int {
  let s = 0
  for i in 0..len(a) {
    s = s + a[i].x + a[i].y
  }
  return s
}

fn main() {
  let a = make()
  a = append(a, 1)
  a = append(a, 2)
  a = add(a, 3)
  print_int(len(a))
  print(" ")
  print_int(total(a))
  print("\n")

  let names = alloc(0, str)
  names = append(names, "t")
  names = append(names, "l")
  names = append(names, "ang")
  print(join(names))
  print("\n")

  let ps = alloc(0, P)
  ps = append(ps, P(1, 2))
  ps = append(ps, P(3, 4))
  print_int(sum_pairs(ps))
  print("\n")

  let box = B(a, names)
  print_int(total(box.nums))
  print(" ")
  print_int(len(box.names))
  print("\n")
}
