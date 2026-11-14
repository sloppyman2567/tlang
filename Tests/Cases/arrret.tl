# A function without a return annotation that returns an array literal carries
# the element type to the call site, so for-each, indexing and field access work.
let GREETING = "hi"

struct Point {
  x: int,
  y: int
}

fn nums() {
  return [1, 2, 3]
}

fn names() {
  return ["ann", "bob"]
}

fn halves() {
  return [0.5, 1.5]
}

fn points() {
  return [Point(1, 2), Point(3, 4)]
}

fn make(n: int) {
  let xs = [n, n + 1]
  return xs
}

fn origin() {
  return Point(7, 8)
}

fn greeting() {
  return GREETING
}

fn main() {
  let total = 0
  for v in nums() {
    total = total + v
  }
  print_int(total)
  print(" ")
  for s in names() {
    print(s)
    print(" ")
  }
  print("\n")
  for h in halves() {
    print_float(h)
    print(" ")
  }
  print("\n")
  for p in points() {
    print_int(p.x)
    print_int(p.y)
    print(" ")
  }
  print("\n")
  print_int(nums()[1])
  print(" ")
  print(names()[0])
  print(" ")
  print(str(halves()[1]))
  print("\n")
  for v in make(7) {
    print_int(v)
    print(" ")
  }
  print("\n")
  for v in [10, 20] {
    print_int(v)
    print(" ")
  }
  print("\n")
  print_int(len(nums()))
  print("\n")
  print_int(origin().x)
  print_int(origin().y)
  print("\n")
  print(greeting())
  print("\n")
}
