# tjson -- a small JSON parser and emitter as an importable module.
#
#   import "Modules/tjson.tl"
#
#   let root = json_parse("{\"a\":[1,2]}")
#   if root < 0 { print(json_error()) return }
#   print_int(json_array_len(json_get(root, ".a")))   # 2
#   json_emit(root, 0)                               # pretty-printed
#
# The tree lives in parallel arrays indexed by an int, because tlang has no
# tagged unions: KIND says what a node is, TEXT holds its original token, and
# FIRST/COUNT point into a shared child-index array. Children are contiguous
# because each container appends the indices it parsed when it closes.
#
# Numbers and strings keep their original text. `json_text` returns the raw
# token, so a caller can re-emit `1.50` exactly as written; `json_print_value`
# decodes string escapes on the way out. Strings that tlang cannot hold as
# values (raw control bytes, \uXXXX above ASCII) are therefore preserved by a
# parse/emit round trip instead of being mangled.
#
# Parsing is strict JSON: leading zeroes, a trailing decimal point, an empty
# exponent, raw control characters and unknown escapes are rejected. On error
# json_parse returns -1 and leaves the reason in JSON_ERR and the byte offset in
# JSON_ERR_POS.

let JSON_NULL = 0
let JSON_BOOL = 1
let JSON_NUM = 2
let JSON_STR = 3
let JSON_ARR = 4
let JSON_OBJ = 5

let JSON_MAX_NODES = 50000
let JSON_MAX_LINKS = 200000
let JSON_MAX_DEPTH = 200

# Source and parser state. len() is strlen, so the length is cached once;
# asking for it in every character loop would make parsing quadratic.
let JSON_SRC = ""
let JSON_LEN = 0
let JSON_POS = 0
let JSON_DEPTH = 0
let JSON_BAD = 0
let JSON_ERR = ""
let JSON_ERR_POS = 0

let JSON_KIND = alloc(50000)
let JSON_TEXT = alloc(50000, str)
let JSON_FIRST = alloc(50000)
let JSON_COUNT = alloc(50000)
let JSON_NNODE = 0

let JSON_LINKS = alloc(200000)
let JSON_NLINK = 0

# Child indices collected by the container currently open.
let JSON_STK = alloc(50000)
let JSON_NSTK = 0

let JSON_COMPACT = 0

# ---------------------------------------------------------------- diagnostics

fn json_error() -> str {
  return JSON_ERR
}

fn json_error_pos() -> int {
  return JSON_ERR_POS
}

# Keep the first failure: a recursive caller unwinding through several levels
# should not overwrite the useful position with a later "expected a value".
fn json_fail(msg: str) {
  if JSON_BAD == 1 {
    return
  }
  JSON_BAD = 1
  JSON_ERR = msg
  JSON_ERR_POS = JSON_POS
}

fn json_at_end() -> int {
  if JSON_POS >= JSON_LEN {
    return 1
  }
  return 0
}

# ---------------------------------------------------------------------- nodes

fn json_add_node(kind: int, text: str, first: int, count: int) -> int {
  if JSON_NNODE >= JSON_MAX_NODES {
    json_fail("document has too many values")
    return -1
  }
  JSON_KIND[JSON_NNODE] = kind
  JSON_TEXT[JSON_NNODE] = text
  JSON_FIRST[JSON_NNODE] = first
  JSON_COUNT[JSON_NNODE] = count
  JSON_NNODE = JSON_NNODE + 1
  return JSON_NNODE - 1
}

fn json_add_text(kind: int, text: str) -> int {
  return json_add_node(kind, text, 0, 0)
}

fn json_close(kind: int, mark: int) -> int {
  let count = JSON_NSTK - mark
  if JSON_NLINK + count > JSON_MAX_LINKS {
    json_fail("document has too many links")
    return -1
  }
  let first = JSON_NLINK
  for i in 0..count {
    JSON_LINKS[JSON_NLINK] = JSON_STK[mark + i]
    JSON_NLINK = JSON_NLINK + 1
  }
  JSON_NSTK = mark
  return json_add_node(kind, "", first, count)
}

fn json_push(index: int) -> int {
  if index < 0 {
    return 0
  }
  if JSON_NSTK >= JSON_MAX_NODES {
    json_fail("document has too many values")
    return 0
  }
  JSON_STK[JSON_NSTK] = index
  JSON_NSTK = JSON_NSTK + 1
  return 1
}

# --------------------------------------------------------------------- parsing

fn json_is_ws(c: int) -> int {
  if c == 32 || c == 9 || c == 10 || c == 13 {
    return 1
  }
  return 0
}

fn json_is_digit(c: int) -> int {
  if c >= 48 && c <= 57 {
    return 1
  }
  return 0
}

fn json_is_hex(c: int) -> int {
  if c >= 48 && c <= 57 {
    return 1
  }
  if c >= 65 && c <= 70 {
    return 1
  }
  if c >= 97 && c <= 102 {
    return 1
  }
  return 0
}

fn json_skip_ws() {
  while json_at_end() == 0 && json_is_ws(JSON_SRC[JSON_POS]) == 1 {
    JSON_POS = JSON_POS + 1
  }
}

fn json_parse_string() -> int {
  if json_at_end() == 1 || JSON_SRC[JSON_POS] != 34 {
    json_fail("expected a string")
    return -1
  }
  JSON_POS = JSON_POS + 1
  let start = JSON_POS
  while json_at_end() == 0 && JSON_SRC[JSON_POS] != 34 {
    let c = JSON_SRC[JSON_POS]
    if c < 32 {
      json_fail("raw control character in string")
      return -1
    }
    if c == 92 {
      JSON_POS = JSON_POS + 1
      if json_at_end() == 1 {
        json_fail("unterminated string")
        return -1
      }
      let e = JSON_SRC[JSON_POS]
      if e == 117 {
        let k = 1
        while k <= 4 {
          if JSON_POS + k >= JSON_LEN || json_is_hex(JSON_SRC[JSON_POS + k]) == 0 {
            json_fail("\\u needs four hex digits")
            return -1
          }
          k = k + 1
        }
        JSON_POS = JSON_POS + 4
      } else if e != 34 && e != 47 && e != 92 && e != 98 && e != 102 && e != 110 && e != 114 && e != 116 {
        json_fail("unknown escape in string")
        return -1
      }
    }
    JSON_POS = JSON_POS + 1
  }
  if json_at_end() == 1 {
    json_fail("unterminated string")
    return -1
  }
  let span = JSON_POS - start
  JSON_POS = JSON_POS + 1
  return json_add_text(JSON_STR, slice(JSON_SRC, start, span))
}

fn json_parse_number() -> int {
  let start = JSON_POS
  if json_at_end() == 0 && JSON_SRC[JSON_POS] == 45 {
    JSON_POS = JSON_POS + 1
  }
  if json_at_end() == 1 || json_is_digit(JSON_SRC[JSON_POS]) == 0 {
    json_fail("malformed number")
    return -1
  }
  if JSON_SRC[JSON_POS] == 48 {
    JSON_POS = JSON_POS + 1
    if json_at_end() == 0 && json_is_digit(JSON_SRC[JSON_POS]) == 1 {
      json_fail("leading zero in number")
      return -1
    }
  } else {
    while json_at_end() == 0 && json_is_digit(JSON_SRC[JSON_POS]) == 1 {
      JSON_POS = JSON_POS + 1
    }
  }
  if json_at_end() == 0 && JSON_SRC[JSON_POS] == 46 {
    JSON_POS = JSON_POS + 1
    if json_at_end() == 1 || json_is_digit(JSON_SRC[JSON_POS]) == 0 {
      json_fail("fraction needs a digit")
      return -1
    }
    while json_at_end() == 0 && json_is_digit(JSON_SRC[JSON_POS]) == 1 {
      JSON_POS = JSON_POS + 1
    }
  }
  if json_at_end() == 0 && (JSON_SRC[JSON_POS] == 101 || JSON_SRC[JSON_POS] == 69) {
    JSON_POS = JSON_POS + 1
    if json_at_end() == 0 && (JSON_SRC[JSON_POS] == 43 || JSON_SRC[JSON_POS] == 45) {
      JSON_POS = JSON_POS + 1
    }
    if json_at_end() == 1 || json_is_digit(JSON_SRC[JSON_POS]) == 0 {
      json_fail("exponent needs a digit")
      return -1
    }
    while json_at_end() == 0 && json_is_digit(JSON_SRC[JSON_POS]) == 1 {
      JSON_POS = JSON_POS + 1
    }
  }
  return json_add_text(JSON_NUM, slice(JSON_SRC, start, JSON_POS - start))
}

fn json_parse_literal(word: str, kind: int, shown: str) -> int {
  let n = len(word)
  for i in 0..n {
    if JSON_POS + i >= JSON_LEN || JSON_SRC[JSON_POS + i] != word[i] {
      json_fail("unknown literal")
      return -1
    }
  }
  JSON_POS = JSON_POS + n
  return json_add_text(kind, shown)
}

fn json_parse_array() -> int {
  JSON_POS = JSON_POS + 1
  let mark = JSON_NSTK
  JSON_DEPTH = JSON_DEPTH + 1
  json_skip_ws()
  if json_at_end() == 0 && JSON_SRC[JSON_POS] == 93 {
    JSON_POS = JSON_POS + 1
    JSON_DEPTH = JSON_DEPTH - 1
    return json_close(JSON_ARR, mark)
  }
  while 1 == 1 {
    json_skip_ws()
    if json_push(json_parse_value()) == 0 {
      return -1
    }
    json_skip_ws()
    if json_at_end() == 1 {
      json_fail("unterminated array")
      return -1
    }
    if JSON_SRC[JSON_POS] == 44 {
      JSON_POS = JSON_POS + 1
    } else if JSON_SRC[JSON_POS] == 93 {
      JSON_POS = JSON_POS + 1
      break
    } else {
      json_fail("expected ',' or ']'")
      return -1
    }
  }
  JSON_DEPTH = JSON_DEPTH - 1
  return json_close(JSON_ARR, mark)
}

fn json_parse_object() -> int {
  JSON_POS = JSON_POS + 1
  let mark = JSON_NSTK
  JSON_DEPTH = JSON_DEPTH + 1
  json_skip_ws()
  if json_at_end() == 0 && JSON_SRC[JSON_POS] == 125 {
    JSON_POS = JSON_POS + 1
    JSON_DEPTH = JSON_DEPTH - 1
    return json_close(JSON_OBJ, mark)
  }
  while 1 == 1 {
    json_skip_ws()
    if json_at_end() == 1 || JSON_SRC[JSON_POS] != 34 {
      json_fail("object keys must be strings")
      return -1
    }
    if json_push(json_parse_string()) == 0 {
      return -1
    }
    json_skip_ws()
    if json_at_end() == 1 || JSON_SRC[JSON_POS] != 58 {
      json_fail("expected ':'")
      return -1
    }
    JSON_POS = JSON_POS + 1
    json_skip_ws()
    if json_push(json_parse_value()) == 0 {
      return -1
    }
    json_skip_ws()
    if json_at_end() == 1 {
      json_fail("unterminated object")
      return -1
    }
    if JSON_SRC[JSON_POS] == 44 {
      JSON_POS = JSON_POS + 1
    } else if JSON_SRC[JSON_POS] == 125 {
      JSON_POS = JSON_POS + 1
      break
    } else {
      json_fail("expected ',' or '}'")
      return -1
    }
  }
  JSON_DEPTH = JSON_DEPTH - 1
  return json_close(JSON_OBJ, mark)
}

fn json_parse_value() -> int {
  if JSON_BAD == 1 {
    return -1
  }
  if JSON_DEPTH > JSON_MAX_DEPTH {
    json_fail("nested too deeply")
    return -1
  }
  json_skip_ws()
  if json_at_end() == 1 {
    json_fail("unexpected end of input")
    return -1
  }
  let c = JSON_SRC[JSON_POS]
  if c == 123 {
    return json_parse_object()
  }
  if c == 91 {
    return json_parse_array()
  }
  if c == 34 {
    return json_parse_string()
  }
  if c == 116 {
    return json_parse_literal("true", JSON_BOOL, "true")
  }
  if c == 102 {
    return json_parse_literal("false", JSON_BOOL, "false")
  }
  if c == 110 {
    return json_parse_literal("null", JSON_NULL, "null")
  }
  return json_parse_number()
}

# Parse a complete document and return its root node, or -1 on error.
fn json_parse(src: str) -> int {
  JSON_SRC = src
  JSON_LEN = len(src)
  JSON_POS = 0
  JSON_DEPTH = 0
  JSON_BAD = 0
  JSON_ERR = ""
  JSON_ERR_POS = 0
  JSON_NNODE = 0
  JSON_NLINK = 0
  JSON_NSTK = 0
  let root = json_parse_value()
  if JSON_BAD == 1 {
    return -1
  }
  json_skip_ws()
  if json_at_end() == 0 {
    json_fail("trailing text after the document")
    return -1
  }
  return root
}

# Read a file and parse it. A JSON document is text, so read_file's NUL
# termination is not a limitation here.
fn json_parse_file(path: str) -> int {
  return json_parse(read_file(path))
}

# ------------------------------------------------------------------- tree API

fn json_kind(index: int) -> int {
  if index < 0 || index >= JSON_NNODE {
    return -1
  }
  return JSON_KIND[index]
}

fn json_text(index: int) -> str {
  if index < 0 || index >= JSON_NNODE {
    return ""
  }
  return JSON_TEXT[index]
}

fn json_count(index: int) -> int {
  if index < 0 || index >= JSON_NNODE {
    return 0
  }
  if JSON_KIND[index] == JSON_ARR {
    return JSON_COUNT[index]
  }
  if JSON_KIND[index] == JSON_OBJ {
    return JSON_COUNT[index] / 2
  }
  return 0
}

fn json_child(index: int, slot: int) -> int {
  if JSON_KIND[index] != JSON_ARR {
    return -1
  }
  if slot < 0 || slot >= JSON_COUNT[index] {
    return -1
  }
  return JSON_LINKS[JSON_FIRST[index] + slot]
}

fn json_key(index: int, pair: int) -> str {
  if index < 0 || index >= JSON_NNODE || JSON_KIND[index] != JSON_OBJ {
    return ""
  }
  if pair < 0 || pair >= JSON_COUNT[index] / 2 {
    return ""
  }
  return JSON_TEXT[JSON_LINKS[JSON_FIRST[index] + pair * 2]]
}

fn json_value(index: int, pair: int) -> int {
  if index < 0 || index >= JSON_NNODE || JSON_KIND[index] != JSON_OBJ {
    return -1
  }
  if pair < 0 || pair >= JSON_COUNT[index] / 2 {
    return -1
  }
  return JSON_LINKS[JSON_FIRST[index] + pair * 2 + 1]
}

fn json_child_key(obj: int, name: str) -> int {
  if obj < 0 || obj >= JSON_NNODE || JSON_KIND[obj] != JSON_OBJ {
    return -1
  }
  let first = JSON_FIRST[obj]
  let n = JSON_COUNT[obj] / 2
  for i in 0..n {
    if JSON_TEXT[JSON_LINKS[first + i * 2]] == name {
      return JSON_LINKS[first + i * 2 + 1]
    }
  }
  return -1
}

# Walk a jq-flavoured path: `.users[2].name`, `.tags[0]`, or `.`.
# A missing key, a bad index or a type mismatch returns -1.
fn json_get(root: int, path: str) -> int {
  let node = root
  let i = 0
  let n = len(path)
  while i < n {
    if path[i] == 46 {
      i = i + 1
    } else if path[i] == 91 {
      i = i + 1
      let start = i
      while i < n && path[i] != 93 {
        i = i + 1
      }
      if i >= n || i == start {
        return -1
      }
      let k = start
      while k < i {
        if json_is_digit(path[k]) == 0 {
          return -1
        }
        k = k + 1
      }
      let index = int(slice(path, start, i - start))
      i = i + 1
      if JSON_KIND[node] != JSON_ARR || index < 0 || index >= JSON_COUNT[node] {
        return -1
      }
      node = JSON_LINKS[JSON_FIRST[node] + index]
    } else {
      let start = i
      while i < n && path[i] != 46 && path[i] != 91 {
        i = i + 1
      }
      let name = slice(path, start, i - start)
      node = json_child_key(node, name)
      if node < 0 {
        return -1
      }
    }
  }
  return node
}

fn json_has(root: int, path: str) -> int {
  if json_get(root, path) < 0 {
    return 0
  }
  return 1
}

# -------------------------------------------------------------------- printing

fn json_print_quoted(s: str) {
  print("\"")
  print(s)
  print("\"")
}

fn json_hexval(c: int) -> int {
  if c >= 48 && c <= 57 {
    return c - 48
  }
  if c >= 65 && c <= 70 {
    return c - 55
  }
  return c - 87
}

# Decode a raw JSON string body onto stdout. Escapes are resolved a byte at a
# time because tlang string literals cannot express bytes such as \b; code
# points above ASCII become '?', matching the emitter's ASCII output.
fn json_print_decoded(s: str) {
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
          let code = json_hexval(s[i + 1]) * 4096 + json_hexval(s[i + 2]) * 256 + json_hexval(s[i + 3]) * 16 + json_hexval(s[i + 4])
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

fn json_indent(n: int) {
  print("\n")
  for i in 0..n {
    print("  ")
  }
}

fn json_emit_node(index: int, level: int) {
  let kind = JSON_KIND[index]
  if kind == JSON_STR {
    json_print_quoted(JSON_TEXT[index])
    return
  }
  if kind == JSON_NULL || kind == JSON_BOOL || kind == JSON_NUM {
    print(JSON_TEXT[index])
    return
  }
  let count = JSON_COUNT[index]
  let first = JSON_FIRST[index]
  if kind == JSON_ARR {
    if count == 0 {
      print("[]")
      return
    }
    print("[")
    for i in 0..count {
      if i > 0 {
        print(",")
      }
      if JSON_COMPACT == 0 {
        json_indent(level + 1)
      }
      json_emit_node(JSON_LINKS[first + i], level + 1)
    }
    if JSON_COMPACT == 0 {
      json_indent(level)
    }
    print("]")
    return
  }
  if count == 0 {
    print("{}")
    return
  }
  let pairs = count / 2
  print("{")
  for i in 0..pairs {
    if i > 0 {
      print(",")
    }
    if JSON_COMPACT == 0 {
      json_indent(level + 1)
    }
    json_print_quoted(JSON_TEXT[JSON_LINKS[first + i * 2]])
    print(":")
    if JSON_COMPACT == 0 {
      print(" ")
    }
    json_emit_node(JSON_LINKS[first + i * 2 + 1], level + 1)
  }
  if JSON_COMPACT == 0 {
    json_indent(level)
  }
  print("}")
}

# Print a whole tree. compact = 0 pretty-prints with two-space indentation;
# any other value emits one line with no spaces. No trailing newline.
fn json_emit(root: int, compact: int) {
  if root < 0 || root >= JSON_NNODE {
    return
  }
  JSON_COMPACT = compact
  json_emit_node(root, 0)
}

# Print one value: a scalar decoded and followed by a newline, or a container
# pretty-printed and followed by a newline. This is what a query command shows.
fn json_print_value(index: int) {
  if index < 0 || index >= JSON_NNODE {
    return
  }
  let kind = JSON_KIND[index]
  if kind == JSON_STR {
    json_print_decoded(JSON_TEXT[index])
    print("\n")
    return
  }
  if kind == JSON_NULL || kind == JSON_BOOL || kind == JSON_NUM {
    print(JSON_TEXT[index])
    print("\n")
    return
  }
  json_emit(index, 0)
  print("\n")
}
