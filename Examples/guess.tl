# Reads stdin; try: printf '50\n25\n12\n' | tcomp run Examples/guess.tl
fn main() {
  let secret = 42
  print("guess my number (1-100)\n")
  let guess = 0
  while guess != secret {
    print("> ")
    guess = int(input())
    if guess < secret { print("higher\n") }
    if guess > secret { print("lower\n") }
  }
  print("got it\n")
}
