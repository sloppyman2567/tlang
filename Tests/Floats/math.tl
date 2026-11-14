struct Point {
  x: float,
  y: float,
}

let seed = 1.5

fn average(a: float, b: float) -> float {
  return (a + b) / 2.0
}

fn main() {
  print_float(2.0 + 3.5)
  print("\n")
  print_float(7.5 - 2.0)
  print("\n")
  print_float(2.5 * 4.0)
  print("\n")
  print_float(7.5 / 2.0)
  print("\n")
  print_float(fabs(-2.25))
  print("\n")
  print_float(sqrt(9.0))
  print("\n")

  print_int(1.5 < 2.0)
  print_int(2.0 <= 2.0)
  print_int(2.0 == 2.0)
  print_int(2.0 != 2.0)
  print_int(3.0 > 2.0)
  print_int(2.0 >= 3.0)
  print_int(0.0 / 0.0 == 0.0 / 0.0)
  print_int(0.0 / 0.0 != 0.0 / 0.0)
  print_int(0.0 / 0.0 >= 0.0)
  print("\n")

  print_float(1.0 / 0.0)
  print("\n")
  print_float(0.0 / 0.0)
  print("\n")

  print_int(int(3.9))
  print("\n")
  print_float(float(2))
  print("\n")

  let p = Point(1.25, 2.5)
  print_float(p.x + p.y)
  print("\n")

  let arr = alloc(3, float)
  arr[0] = 1.5
  arr[1] = 2.25
  arr[2] = 3.0
  print_float(arr[0] + arr[1] + arr[2])
  print("\n")

  print_float(average(1.0, 2.0))
  print("\n")
  print_float(seed)
  print("\n")

  let x = 1.0
  x += 0.5
  print_float(x)
  print("\n")

  let y = 1.0
  y++
  print_float(y)
  print("\n")
  y--
  print_float(y)
  print("\n")
}
