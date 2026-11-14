# tbox -- four of the tools I use every day, in one small binary.
#
#   tbox wc   [file...]                  lines, words, bytes
#   tbox head [-n N] [file...]           first N lines (default 10)
#   tbox tail [-n N] [file...]           last N lines
#   tbox grep [-i] [-n] [-c] [-v] PATTERN [file...]
#                                         -i ignore case   -n line numbers
#                                         -c count only    -v invert
#
# With no file argument the input is read from stdin. grep exits 0 when it
# matched something, 1 when it did not, 2 on a usage error -- the same contract
# as the real thing, because that is what shell scripts rely on.
#
# Everything below is written for the arena: input is slurped once per file and
# lines are printed by index, so the only allocations are the slices that are
# actually written to stdout.

let FILES = alloc(256, str)
let NFILES = 0
let FROM_STDIN = 0
let SHOW_NAME = 0

let PATTERN = ""
let IGNORE_CASE = 0
let NUMBER_LINES = 0
let COUNT_ONLY = 0
let INVERT = 0

let TOT_LINES = 0
let TOT_WORDS = 0
let TOT_BYTES = 0
let COUNT = 10

fn usage() {
  print("usage: tbox <tool> [options] [file...]\n")
  print("\n")
  print("  wc   [file...]        lines, words and bytes\n")
  print("  head [-n N] [file...] first N lines\n")
  print("  tail [-n N] [file...] last N lines\n")
  print("  grep [-i] [-n] [-c] [-v] PATTERN [file...]\n")
  print("\n")
  print("no file means standard input\n")
}

fn die(msg: str) {
  print_err("tbox: " + msg + "\n")
  exit(2)
}

# ---------------------------------------------------------------- text helpers

fn is_space(c: int) -> int {
  if c == 32 || c == 9 || c == 10 || c == 13 { return 1 }
  return 0
}

fn lower(c: int) -> int {
  if c >= 65 && c <= 90 { return c + 32 }
  return c
}

# slice() takes a length, not an end index; at line boundaries the end index
# is what you have, so this reads better (and cannot be got backwards).
fn text(s: str, from: int, to: int) -> str {
  return slice(s, from, to - from)
}

# len() is strlen: O(n) every time it is called, so the bound is hoisted out
# of the loop and passed in. Leaving `i < len(s)` here makes a whole scan
# quadratic, which is exactly the bug this comment exists to prevent.
fn line_end(s: str, from: int, total: int) -> int {
  let i = from
  while i < total && s[i] != 10 { i = i + 1 }
  return i
}

fn count_lines(s: str) -> int {
  if len(s) == 0 { return 0 }
  let n = 0
  for i in 0..len(s) {
    if s[i] == 10 { n = n + 1 }
  }
  if s[len(s) - 1] != 10 { n = n + 1 }
  return n
}

fn count_words(s: str) -> int {
  let n = 0
  let inside = 0
  for i in 0..len(s) {
    if is_space(s[i]) == 1 {
      inside = 0
    } else if inside == 0 {
      inside = 1
      n = n + 1
    }
  }
  return n
}

# Does `pat` start at `pos` in `s`? Both are byte strings, so this is a plain
# loop; `-i` folds ASCII case in both sides.
fn match_at(s: str, pos: int, pat: str) -> int {
  let n = len(pat)
  for k in 0..n {
    let a = s[pos + k]
    let b = pat[k]
    if IGNORE_CASE == 1 {
      a = lower(a)
      b = lower(b)
    }
    if a != b { return 0 }
  }
  return 1
}

# Is the line s[from..to] a hit? An empty pattern matches everything, which is
# how you search for blank lines.
fn line_hits(s: str, from: int, to: int) -> int {
  let found = 0
  let n = len(PATTERN)
  if n == 0 {
    found = 1
  } else {
    let i = from
    while i + n <= to {
      if match_at(s, i, PATTERN) == 1 {
        found = 1
        break
      }
      i = i + 1
    }
  }
  if INVERT == 1 { return 1 - found }
  return found
}

# ------------------------------------------------------------- argument parsing

# Fill FILES from argv[from..]; with none, read stdin instead of erroring.
fn inputs(from) {
  NFILES = 0
  for i in from..argc() {
    FILES[NFILES] = argv(i)
    NFILES = NFILES + 1
  }
  if NFILES == 0 {
    FILES[0] = "/dev/stdin"
    NFILES = 1
    FROM_STDIN = 1
  }
  if NFILES > 1 { SHOW_NAME = 1 }
}

fn name_of(k) -> str {
  if SHOW_NAME == 1 { return FILES[k] + ":" }
  return ""
}

# ----------------------------------------------------------------------- tools

fn wc_one(s: str, label: str) {
  let lines = count_lines(s)
  let words = count_words(s)
  let bytes = len(s)
  TOT_LINES = TOT_LINES + lines
  TOT_WORDS = TOT_WORDS + words
  TOT_BYTES = TOT_BYTES + bytes
  print_int(lines)
  print(" ")
  print_int(words)
  print(" ")
  print_int(bytes)
  if len(label) > 0 {
    print(" ")
    print(label)
  }
  print("\n")
}

fn run_wc(from) {
  inputs(from)
  for k in 0..NFILES {
    if FROM_STDIN == 1 {
      wc_one(read_file(FILES[k]), "")
    } else {
      wc_one(read_file(FILES[k]), FILES[k])
    }
  }
  if NFILES > 1 {
    print_int(TOT_LINES)
    print(" ")
    print_int(TOT_WORDS)
    print(" ")
    print_int(TOT_BYTES)
    print(" total\n")
  }
}

fn run_head(from, count) {
  inputs(from)
  for k in 0..NFILES {
    let s = read_file(FILES[k])
    let total = len(s)
    let start = 0
    let taken = 0
    while start < total && taken < count {
      let end = line_end(s, start, total)
      print(text(s, start, end))
      print("\n")
      start = end + 1
      taken = taken + 1
    }
  }
}

fn run_tail(from, count) {
  inputs(from)
  for k in 0..NFILES {
    let s = read_file(FILES[k])
    let bytes = len(s)
    let total = count_lines(s)
    let skip = 0
    if total > count { skip = total - count }
    let start = 0
    let seen = 0
    while start < bytes {
      let end = line_end(s, start, bytes)
      if seen >= skip {
        print(text(s, start, end))
        print("\n")
      }
      seen = seen + 1
      start = end + 1
    }
  }
}

fn grep_one(s: str, label: str) -> int {
  let hits = 0
  let number = 0
  let start = 0
  let total = len(s)
  while start < total {
    let end = line_end(s, start, total)
    number = number + 1
    if line_hits(s, start, end) == 1 {
      hits = hits + 1
      if COUNT_ONLY == 0 {
        print(label)
        if NUMBER_LINES == 1 {
          print_int(number)
          print(":")
        }
        print(text(s, start, end))
        print("\n")
      }
    }
    start = end + 1
  }
  return hits
}

fn run_grep(from) {
  # Flags first, then the pattern, then whatever is left is a file list.
  let i = from
  while i < argc() && len(argv(i)) > 0 && argv(i)[0] == 45 {
    let flag = argv(i)
    if flag == "--help" {
      usage()
      exit(0)
    }
    # Flags may be bundled (`grep -in`), so walk the characters after '-'.
    for j in 1..len(flag) {
      let c = flag[j]
      if c == 105 {
        IGNORE_CASE = 1
      } else if c == 110 {
        NUMBER_LINES = 1
      } else if c == 99 {
        COUNT_ONLY = 1
      } else if c == 118 {
        INVERT = 1
      } else if c == 104 {
        usage()
        exit(0)
      } else {
        die("unknown option -" + slice(flag, j, 1))
      }
    }
    i = i + 1
  }
  if i >= argc() { die("grep needs a pattern") }
  PATTERN = argv(i)
  i = i + 1

  inputs(i)
  let hits = 0
  for k in 0..NFILES {
    let n = grep_one(read_file(FILES[k]), name_of(k))
    hits = hits + n
    if COUNT_ONLY == 1 && NFILES > 1 {
      print(FILES[k])
      print(":")
      print_int(n)
      print("\n")
    }
  }
  if COUNT_ONLY == 1 {
    print_int(hits)
    print("\n")
  }
  if hits == 0 { exit(1) }
}

# `-n N` for head and tail: returns the new argument index.
fn count_flag(from) -> int {
  if from + 1 < argc() && argv(from) == "-n" {
    COUNT = int(argv(from + 1))
    if COUNT < 0 { COUNT = 0 }
    return from + 2
  }
  COUNT = 10
  return from
}

fn main() {
  if argc() < 2 {
    usage()
    exit(2)
  }
  let tool = argv(1)
  if tool == "grep" {
    run_grep(2)
    return
  }
  if tool == "wc" {
    run_wc(2)
    return
  }
  if tool == "head" {
    let at = count_flag(2)
    run_head(at, COUNT)
    return
  }
  if tool == "tail" {
    let at = count_flag(2)
    run_tail(at, COUNT)
    return
  }
  if tool == "-h" || tool == "--help" || tool == "help" {
    usage()
    return
  }
  die("no such tool '" + tool + "'")
}
