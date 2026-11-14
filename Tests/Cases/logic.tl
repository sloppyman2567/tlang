# `&&`/`||` branch on the truth of a comparison, which is the case that
# exercises compare-into-branch fusion in both directions.
fn classify(a, b) -> str {
  if a < b || a == 0 {
    return "less-or-zero"
  }
  if a > b && b != 0 {
    return "greater"
  }
  return "equal"
}

fn main() {
  print(classify(1, 2))
  print(" ")
  print(classify(3, 2))
  print(" ")
  print(classify(0, 9))
  print(" ")
  print(classify(5, 5))
  print("\n")

  negation()

  let i = 0
  let hits = 0
  while i < 20 {
    i = i + 1
    if i % 3 == 0 || i == 7 {
      hits = hits + 1
    }
  }
  print_int(hits)
  print("\n")
}

fn negation() {
  let zero = 0
  let five = 5
  if !zero { print("a") }
  if !five { print("B") } else { print("b") }
  if !(five == 5) { print("C") } else { print("c") }
  print("\n")
}
