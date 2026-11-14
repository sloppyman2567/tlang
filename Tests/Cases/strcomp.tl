# Ordering two strings compares their contents, not their pointers.
fn main() {
  let apple = "apple"
  let banana = "banana"
  let same = "apple"

  print_int(apple < banana)
  print(" ")
  print_int(apple > banana)
  print(" ")
  print_int(apple <= same)
  print(" ")
  print_int(apple >= same)
  print(" ")
  print_int(apple == same)
  print(" ")
  print_int(apple != banana)
  print(" ")
  print_int("app" < "apple")
  print(" ")
  print_int("" < "a")
  print(" ")
  print_int("a" < "")
  print(" ")
  print_int("Z" < "a")
  print(" ")
  print_int("abc" > "abd")
  print(" ")
  let hi = newbuf(2)
  hi[0] = 200
  hi[1] = 0
  print_int(hi > "a")
  if apple < banana { print(" lt\n") } else { print(" ge\n") }
}
