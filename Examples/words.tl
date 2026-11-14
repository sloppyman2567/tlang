# Counts lines, words and bytes in a file: tcomp run Examples/words.tl FILE
fn main() {
  if argc() < 2 {
    print_err("usage: words <file>\n")
    exit(1)
  }
  let text = read_file(argv(1))
  let n = len(text)
  let i = 0
  let lines = 0
  let words = 0
  let inword = 0
  while i < n {
    let c = text[i]
    if c == 10 { lines = lines + 1 }
    if c == 32 || c == 10 || c == 9 {
      inword = 0
    } else {
      if inword == 0 {
        words = words + 1
        inword = 1
      }
    }
    i = i + 1
  }
  print("lines=" + lines + " words=" + words + " bytes=" + n + "\n")
}
