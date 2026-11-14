fn main() {
  let s = "hello"
  print_int(len(s))
  print(" ")
  print_int(s[0])
  print(" ")
  print_int(s[4])
  print("\n")
  let t = slice("hello world", 6, 5)
  print(t + "!\n")
  t[0] = 87
  print(t + "\n")
  print_int(str_eq(s, "hello"))
  print_int(str_eq(s, "hellp"))
  print("\n")
  print_int(int("  -42"))
  print(" ")
  print_int(int("7abc"))
  print(" ")
  print(str(1234) + "x\n")
  print("n=" + 7 + "," + -3 + "\n")
}
