struct P { x, y }

fn main() {
  let a = [10, 20, 30]
  let sum = 0
  for v in a {
    sum = sum + v
  }
  print_int(sum)
  print(" ")

  for v in "abc" {
    print_int(v)
    print(",")
  }
  print("\n")

  for v in a {
    if v == 20 { continue }
    if v == 30 { break }
    print_int(v)
  }
  print("\n")

  let ps = alloc(2, P)
  ps[0] = P(1, 2)
  ps[1] = P(3, 4)
  for p in ps {
    print_int(p.x + p.y)
    print(" ")
  }
  print("\n")

  let names = alloc(0, str)
  names = append(names, "a")
  names = append(names, "b")
  for n in names {
    print(n)
  }
  print("\n")

  for i in a {
    for j in a {
      print_int(i * j / 10)
      print(" ")
    }
  }
  print("\n")

  print(sum)
  print("\n")
}
