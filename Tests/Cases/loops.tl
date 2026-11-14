# for-loops and compound assignment.
fn main() {
  let sum = 0
  for i in 1..5 { sum += i }
  print_int(sum)
  print("\n")

  for i in 0..0 { print("never") }
  print("empty range ok\n")

  # continue must still advance the counter, or this never terminates
  let odds = 0
  for i in 0..10 {
    if i % 2 == 0 { continue }
    odds += 1
  }
  print_int(odds)
  print("\n")

  let early = 0
  for i in 0..100 {
    if i == 3 { break }
    early += i
  }
  print_int(early)
  print("\n")

  let nested = 0
  for i in 0..3 {
    for j in 0..2 { nested += i * 10 + j }
  }
  print_int(nested)
  print("\n")

  # the upper bound is evaluated once, before the loop
  let limit = 3
  let runs = 0
  for i in 0..limit {
    limit = 0
    runs += 1
  }
  print_int(runs)
  print("\n")

  let a = 17
  a -= 2
  a *= 3
  a /= 5
  a %= 4
  print_int(a)
  print("\n")
}
