# tjson -- a JSON processor: validate, pretty-print, and query.
#
#   tjson fmt [--compact] [file]        re-print the document
#   tjson get PATH [file]               print one value, decoded
#   tjson keys PATH [file]              list an object's keys
#
# PATH is jq-flavoured: `.users[2].name`, `.tags[0]`, or `.` for the root.
#
# JSON is a tree, and tlang has no tagged unions, so the tree lives in five
# parallel arrays indexed by an int instead of a pointer: KIND says what a node
# is, VAL holds its text, and FIRST/COUNT point into a shared child-index array.
# Children end up contiguous because each container collects the indices it
# parsed on a stack and appends them in one run when it closes.
#
# Two deliberate choices:
#
# * Numbers keep their original text, so `fmt` re-prints `1.50` and `1e9`
#   exactly as written instead of rounding them through an int.
# * Strings are stored *raw* (still containing their backslash escapes) and are
#   decoded only when a value is printed with `get`. `fmt` therefore reproduces
#   the input byte for byte, and escapes that tlang strings cannot hold (such as
#   \b, \f, and \uXXXX) survive formatting instead of being mangled.

let K_NULL = 0
let K_BOOL = 1
let K_NUM = 2
let K_STR = 3
let K_ARR = 4
let K_OBJ = 5

let MAX_NODES = 50000
let MAX_LINKS = 200000

# len() is strlen, so the input length is cached once: calling it inside the
# character loops below would make parsing quadratic in the file size.
let SRC = ""
let SRC_LEN = 0
let POS = 0
let DEPTH = 0

let KIND = alloc(50000)
let VAL = alloc(50000, str)
let FIRST = alloc(50000)
let COUNT = alloc(50000)
let NNODE = 0

let LINKS = alloc(200000)
let NLINK = 0

# child indices collected by the container currently open
let STK = alloc(50000)
let NSTK = 0

let COMPACT = 0

# ------------------------------------------------------------------ diagnostics

fn fail(msg: str) {
  print_err("tjson: ")
  print_err(msg)
  print_err(" at byte ")
  print_err(str(POS))       # str(), not print_int(): both must go to stderr
  print_err("\n")
  exit(2)
}

fn ok_here() -> int {
  if POS < SRC_LEN { return 1 }
  return 0
}

# ---------------------------------------------------------------------- nodes

fn add_node(kind: int, val: str, first: int, count: int) -> int {
  if NNODE >= MAX_NODES { fail("document has too many values") }
  KIND[NNODE] = kind
  VAL[NNODE] = val
  FIRST[NNODE] = first
  COUNT[NNODE] = count
  NNODE = NNODE + 1
  return NNODE - 1
}

fn add_text(kind: int, val: str) -> int {
  return add_node(kind, val, 0, 0)
}

# An object stores keys and values alternately, so it has half as many pairs as
# it has child slots; an array has one element per slot.
fn pairs(obj: int) -> int {
  return COUNT[obj] / 2
}

fn close_container(kind: int, mark: int) -> int {
  let count = NSTK - mark
  let first = NLINK
  for i in 0..count {
    LINKS[NLINK] = STK[mark + i]
    NLINK = NLINK + 1
  }
  NSTK = mark
  return add_node(kind, "", first, count)
}

# --------------------------------------------------------------------- parsing

fn is_ws(c: int) -> int {
  if c == 32 || c == 9 || c == 10 || c == 13 { return 1 }
  return 0
}

fn is_digit(c: int) -> int {
  if c >= 48 && c <= 57 { return 1 }
  return 0
}

fn skip_ws() {
  while ok_here() == 1 && is_ws(SRC[POS]) == 1 { POS = POS + 1 }
}

fn parse_string() -> int {
  if SRC[POS] != 34 { fail("expected a string") }
  POS = POS + 1
  let start = POS
  while ok_here() == 1 && SRC[POS] != 34 {
    if SRC[POS] == 92 { POS = POS + 1 }
    POS = POS + 1
  }
  if ok_here() == 0 { fail("unterminated string") }
  let span = POS - start
  POS = POS + 1
  return add_text(K_STR, slice(SRC, start, span))
}

fn parse_number() -> int {
  let start = POS
  if ok_here() == 1 && SRC[POS] == 45 { POS = POS + 1 }
  let digits = 0
  while ok_here() == 1 && is_digit(SRC[POS]) == 1 {
    digits = digits + 1
    POS = POS + 1
  }
  if digits == 0 { fail("malformed number") }
  if ok_here() == 1 && SRC[POS] == 46 {
    POS = POS + 1
    while ok_here() == 1 && is_digit(SRC[POS]) == 1 { POS = POS + 1 }
  }
  if ok_here() == 1 && (SRC[POS] == 101 || SRC[POS] == 69) {
    POS = POS + 1
    if ok_here() == 1 && (SRC[POS] == 43 || SRC[POS] == 45) { POS = POS + 1 }
    while ok_here() == 1 && is_digit(SRC[POS]) == 1 { POS = POS + 1 }
  }
  return add_text(K_NUM, slice(SRC, start, POS - start))
}

fn parse_literal(word: str, kind: int, shown: str) -> int {
  let n = len(word)
  for i in 0..n {
    if POS + i >= SRC_LEN { fail("truncated literal") }
    if SRC[POS + i] != word[i] { fail("unknown literal") }
  }
  POS = POS + n
  return add_text(kind, shown)
}

fn parse_array() -> int {
  POS = POS + 1
  let mark = NSTK
  DEPTH = DEPTH + 1
  skip_ws()
  if ok_here() == 1 && SRC[POS] == 93 {
    POS = POS + 1
    DEPTH = DEPTH - 1
    return close_container(K_ARR, mark)
  }
  while 1 == 1 {
    skip_ws()
    STK[NSTK] = parse_value()
    NSTK = NSTK + 1
    skip_ws()
    if ok_here() == 0 { fail("unterminated array") }
    if SRC[POS] == 44 {
      POS = POS + 1
    } else if SRC[POS] == 93 {
      POS = POS + 1
      break
    } else {
      fail("expected ',' or ']'")
    }
  }
  DEPTH = DEPTH - 1
  return close_container(K_ARR, mark)
}

fn parse_object() -> int {
  POS = POS + 1
  let mark = NSTK
  DEPTH = DEPTH + 1
  skip_ws()
  if ok_here() == 1 && SRC[POS] == 125 {
    POS = POS + 1
    DEPTH = DEPTH - 1
    return close_container(K_OBJ, mark)
  }
  while 1 == 1 {
    skip_ws()
    if ok_here() == 0 || SRC[POS] != 34 { fail("object keys must be strings") }
    STK[NSTK] = parse_string()
    NSTK = NSTK + 1
    skip_ws()
    if ok_here() == 0 || SRC[POS] != 58 { fail("expected ':'") }
    POS = POS + 1
    skip_ws()
    STK[NSTK] = parse_value()
    NSTK = NSTK + 1
    skip_ws()
    if ok_here() == 0 { fail("unterminated object") }
    if SRC[POS] == 44 {
      POS = POS + 1
    } else if SRC[POS] == 125 {
      POS = POS + 1
      break
    } else {
      fail("expected ',' or '}'")
    }
  }
  DEPTH = DEPTH - 1
  return close_container(K_OBJ, mark)
}

fn parse_value() -> int {
  if DEPTH > 200 { fail("nested too deeply") }
  skip_ws()
  if ok_here() == 0 { fail("unexpected end of input") }
  let c = SRC[POS]
  if c == 123 { return parse_object() }
  if c == 91 { return parse_array() }
  if c == 34 { return parse_string() }
  if c == 116 { return parse_literal("true", K_BOOL, "true") }
  if c == 102 { return parse_literal("false", K_BOOL, "false") }
  if c == 110 { return parse_literal("null", K_NULL, "null") }
  return parse_number()
}

fn parse_document() -> int {
  NNODE = 0
  NLINK = 0
  NSTK = 0
  POS = 0
  DEPTH = 0
  let root = parse_value()
  skip_ws()
  if ok_here() == 1 { fail("trailing text after the document") }
  return root
}

# -------------------------------------------------------------------- printing

# Strings are stored raw, so printing a quoted one is just quoting it again.
fn print_quoted(s: str) {
  print("\"")
  print(s)
  print("\"")
}

fn hexval(c: int) -> int {
  if c >= 48 && c <= 57 { return c - 48 }
  if c >= 65 && c <= 70 { return c - 55 }
  if c >= 97 && c <= 102 { return c - 87 }
  return 0
}

# Decode a raw JSON string body onto stdout. Nothing is built: escapes are
# resolved a byte at a time, which is the only way to emit bytes like \b that
# tlang string literals cannot express.
fn print_decoded(s: str) {
  let i = 0
  let n = len(s)
  while i < n {
    let c = s[i]
    if c != 92 {
      print_char(c)
      i = i + 1
    } else {
      i = i + 1
      let e = s[i]
      if e == 110 {
        print_char(10)
      } else if e == 116 {
        print_char(9)
      } else if e == 114 {
        print_char(13)
      } else if e == 98 {
        print_char(8)
      } else if e == 102 {
        print_char(12)
      } else if e == 117 {
        if i + 4 >= n {
          print_char(63)
        } else {
          let code = hexval(s[i + 1]) * 4096 + hexval(s[i + 2]) * 256 + hexval(s[i + 3]) * 16 + hexval(s[i + 4])
          if code > 0 && code < 128 {
            print_char(code)
          } else {
            print_char(63)
          }
          i = i + 4
        }
      } else {
        print_char(e)
      }
      i = i + 1
    }
  }
}

fn indent(n: int) {
  print("\n")
  for i in 0..n { print("  ") }
}

fn emit(idx: int, level: int) {
  let k = KIND[idx]
  if k == K_STR {
    print_quoted(VAL[idx])
    return
  }
  if k == K_NULL || k == K_BOOL || k == K_NUM {
    print(VAL[idx])
    return
  }
  let count = COUNT[idx]
  let first = FIRST[idx]
  if k == K_ARR {
    if count == 0 {
      print("[]")
      return
    }
    print("[")
    for i in 0..count {
      if i > 0 { print(",") }
      if COMPACT == 0 { indent(level + 1) }
      emit(LINKS[first + i], level + 1)
    }
    if COMPACT == 0 { indent(level) }
    print("]")
    return
  }
  if count == 0 {
    print("{}")
    return
  }
  let n = count / 2
  print("{")
  for i in 0..n {
    if i > 0 { print(",") }
    if COMPACT == 0 { indent(level + 1) }
    print_quoted(VAL[LINKS[first + i * 2]])
    print(":")
    if COMPACT == 0 { print(" ") }
    emit(LINKS[first + i * 2 + 1], level + 1)
  }
  if COMPACT == 0 { indent(level) }
  print("}")
}

fn print_value(idx: int) {
  let k = KIND[idx]
  if k == K_STR {
    print_decoded(VAL[idx])
    print("\n")
    return
  }
  if k == K_NULL || k == K_BOOL || k == K_NUM {
    print(VAL[idx])
    print("\n")
    return
  }
  emit(idx, 0)
  print("\n")
}

# ------------------------------------------------------------------- querying

fn child_key(obj: int, name: str) -> int {
  let first = FIRST[obj]
  let n = pairs(obj)
  for i in 0..n {
    if VAL[LINKS[first + i * 2]] == name {
      return LINKS[first + i * 2 + 1]
    }
  }
  return -1
}

fn report_missing(part: str) {
  print_err("tjson: no such key '")
  print_err(part)
  print_err("'\n")
  exit(1)
}

# Walk PATH from the root: `.name` selects a key, `[n]` an array element. A
# leading name without the dot works too, so `name.0` and `.name[0]` both read.
fn resolve(root: int, path: str) -> int {
  let node = root
  let i = 0
  while i < len(path) {
    if path[i] == 46 {
      i = i + 1
    } else if path[i] == 91 {
      i = i + 1
      let start = i
      while i < len(path) && path[i] != 93 { i = i + 1 }
      let index = int(slice(path, start, i - start))
      i = i + 1
      if KIND[node] != K_ARR || index < 0 || index >= COUNT[node] {
        report_missing(str(index))
      }
      node = LINKS[FIRST[node] + index]
    } else {
      # a key name, with or without the leading '.'
      let start = i
      while i < len(path) && path[i] != 46 && path[i] != 91 { i = i + 1 }
      let name = slice(path, start, i - start)
      if KIND[node] != K_OBJ { report_missing(name) }
      node = child_key(node, name)
      if node < 0 { report_missing(name) }
    }
  }
  return node
}

fn list_keys(root: int, path: str) {
  let node = resolve(root, path)
  if KIND[node] != K_OBJ {
    print_err("tjson: that value is not an object\n")
    exit(1)
  }
  let first = FIRST[node]
  for i in 0..pairs(node) {
    print_decoded(VAL[LINKS[first + i * 2]])
    print("\n")
  }
}

# ----------------------------------------------------------------------- main

fn usage() {
  print("usage: tjson <command> [options] [file]\n")
  print("\n")
  print("  fmt [--compact] [file]   re-print the document (default: pretty)\n")
  print("  get PATH [file]          print one value, e.g. .users[0].name\n")
  print("  keys PATH [file]         list an object's keys\n")
  print("\n")
  print("no file means standard input\n")
}

fn load(path: str) -> int {
  if path == "-" {
    SRC = read_file("/dev/stdin")
  } else {
    SRC = read_file(path)
  }
  SRC_LEN = len(SRC)
  if SRC_LEN == 0 { fail("empty input or unreadable file") }
  return parse_document()
}

fn main() {
  if argc() < 2 {
    usage()
    exit(2)
  }
  let cmd = argv(1)
  if cmd == "fmt" {
    let at = 2
    if at < argc() && argv(at) == "--compact" {
      COMPACT = 1
      at = at + 1
    }
    let path = "-"
    if at < argc() {
      path = argv(at)
      at = at + 1
    }
    if at < argc() { fail("too many arguments") }
    emit(load(path), 0)
    print("\n")
    return
  }
  if cmd == "get" || cmd == "keys" {
    if argc() < 3 { fail("this command needs a path") }
    let file = "-"
    if argc() > 3 { file = argv(3) }
    let root = load(file)
    if cmd == "keys" {
      list_keys(root, argv(2))
      return
    }
    print_value(resolve(root, argv(2)))
    return
  }
  if cmd == "-h" || cmd == "--help" || cmd == "help" {
    usage()
    return
  }
  print_err("tjson: no such command '")
  print_err(cmd)
  print_err("'\n")
  exit(2)
}
