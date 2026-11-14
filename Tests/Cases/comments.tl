/* leading
   comment */
fn main() {
  let x = 1 /* inline */
  x = x + 1
  x = x + 1 /* trailing
  comment on two lines */
  print_int(x)
  print(" ")
  // line comment
  # hash comment
  let s = "/* not a comment */"
  print(s)
  print("\n")
}
