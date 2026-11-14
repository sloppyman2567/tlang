struct P { x, y }

fn main() {
  let a = alloc(0)
  let i = 0
  while i < 100 {
    a = append(a, i * i)
    i = i + 1
  }
  print_int(len(a))
  print(" ")
  print_int(a[0])
  print(" ")
  print_int(a[99])
  print("\n")

  let b = [10, 20, 30]
  print_int(len(b))
  b = append(b, 40)
  print(" ")
  print_int(len(b))
  print(" ")
  print_int(b[0] + b[1] + b[2] + b[3])
  print("\n")

  let c = alloc(2)
  c[0] = 7
  c[1] = 8
  c = append(c, 9)
  print_int(len(c))
  print(" ")
  print_int(c[0] + c[1] + c[2])
  print("\n")

  let names = alloc(0, str)
  names = append(names, "alpha")
  names = append(names, "beta")
  print_int(len(names))
  print(" ")
  print(names[0])
  print(" ")
  print(names[1])
  print("\n")

  let ps = alloc(0, P)
  ps = append(ps, P(1, 2))
  ps = append(ps, P(3, 4))
  print_int(len(ps))
  print(" ")
  print_int(ps[1].y)
  print("\n")

  a[5] = 77
  print_int(a[5])
  print(" ")
  print_int(len(a))
  print("\n")
}
