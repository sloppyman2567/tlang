struct Pair { a, b }
struct Box { p: Pair, tag }

fn main() {
  let p = Pair(10, 32)
  print_int(p.a + p.b)
  print("\n")
  p.a = 1
  print_int(p.a)
  print("\n")
  let b = Box(Pair(2, 3), 99)
  let inner = b.p
  print_int(inner.b + b.tag)
  print("\n")
  let arr = alloc(3, Pair)
  arr[0] = Pair(5, 6)
  arr[1] = Pair(7, 8)
  print_int(arr[0].a + arr[1].b)
  print("\n")
}
