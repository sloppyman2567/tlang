# `len()` in a loop condition. The optimizer hoists it out of any loop whose
# body cannot change the string; a loop that *does* change it must observe the
# new length, so that case must not be hoisted.

fn scan(s: str) -> int {
  let i = 0
  let sum = 0
  while i < len(s) {
    sum = sum + s[i]
    i = i + 1
  }
  return sum
}

fn main() {
  let s = "hello, world"
  let i = 0
  while i < len(s) {
    i = i + 1
  }
  print_int(i)
  print(" ")
  print_int(len(s))
  print("\n")

  print_int(scan(s))
  print("\n")

  # Nested: the inner loop's length is invariant in both loops.
  let total = 0
  for r in 0..3 {
    let j = 0
    while j < len(s) {
      total = total + 1
      j = j + 1
    }
  }
  print_int(total)
  print(" ")
  print_int(total / len(s))
  print("\n")

  # The string grows inside the loop, so the condition must see the growth.
  let g = "abc"
  let n = 0
  while n < 3 {
    g = g + "x"
    n = n + 1
  }
  print(g)
  print(" ")
  print_int(len(g))
  print("\n")

  # A length cached before the loop is still just a number.
  let m = len(s)
  let k = 0
  while k < m {
    if k == 5 { break }
    k = k + 1
  }
  print_int(k)
  print(" ")
  let empty = ""
  let e = 0
  while e < len(empty) {
    e = e + 100
  }
  print_int(e)
  print("\n")
}
