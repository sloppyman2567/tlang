# tjson -- a small JSON parser and emitter as an importable module.
#
#   import "Modules/tjson.tl"
#
#   let root = json_parse("{\"a\":[1,2]}")
#   if root < 0 { print(json_error()) return }
#   print_int(json_count(json_get(root, ".a")))   # 2
#   json_emit(root, 0)                             # pretty-printed
#
# The tree lives in parallel arrays indexed by an int, because tlang has no
# tagged unions: KIND says what a node is, TEXT holds its original token, and
# FIRST/COUNT point into a shared child-index array. Children are contiguous
# because each container appends the indices it parsed when it closes.
#
# Object keys in a path use dot syntax (`.users[2].name`) or a quoted bracket
# key (`.["a.b"]`) for names containing dots or brackets. JSON escapes in the
# key are decoded before matching, so `.ab` finds `"a\u0062"`. Array indices
# may be negative, as in jq (`.tags[-1]` is the last element).
#
# `json_pointer` resolves RFC 6901 pointers: `/users/0/name`, `/a~1b` for a
# key containing '/', `/m~0n` for one containing '~', and the empty pointer
# for the root. It is separate from the jq-flavoured path syntax above.
#
# Building uses the same tree:
#
#   let obj = json_new_object()
#   obj = json_object_set(obj, "name", json_new_string("tlang"))
#   let arr = json_new_array()
#   arr = json_array_push(arr, json_new_int(1))
#   obj = json_object_set(obj, "items", arr)
#   json_emit(obj, 1)   # {"name":"tlang","items":[1]}
#
# Updates return the node to keep. A child run at the end of the link array is
# extended in place; otherwise the node is copied. json_parse resets the shared
# arrays, so do not keep node indices across a parse. Builder mutations reject
# direct and indirect cycles and value subtrees deeper than JSON_MAX_DEPTH.
#
# Numbers and strings keep their original text. `json_text` returns the raw
# token, so a caller can re-emit `1.50` exactly as written; `json_print_value`
# decodes string escapes on the way out, including non-ASCII \uXXXX code
# points as UTF-8. Strings that tlang cannot hold as values (raw control bytes,
# \uXXXX above ASCII) are therefore preserved by a parse/emit round trip
# instead of being mangled.
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
let JSON_HEX = "0123456789abcdef"

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
  if index < 0 || index >= JSON_NNODE || JSON_KIND[index] != JSON_ARR {
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

fn json_hex4(s: str, at: int) -> int {
  return json_hexval(s[at]) * 4096 + json_hexval(s[at + 1]) * 256 + json_hexval(s[at + 2]) * 16 + json_hexval(s[at + 3])
}

fn json_put_utf8(out: str, w: int, code: int) -> int {
  if code < 128 {
    out[w] = code
    return w + 1
  }
  if code < 2048 {
    out[w] = 192 | (code >> 6)
    out[w + 1] = 128 | (code & 63)
    return w + 2
  }
  if code < 65536 {
    out[w] = 224 | (code >> 12)
    out[w + 1] = 128 | ((code >> 6) & 63)
    out[w + 2] = 128 | (code & 63)
    return w + 3
  }
  out[w] = 240 | (code >> 18)
  out[w + 1] = 128 | ((code >> 12) & 63)
  out[w + 2] = 128 | ((code >> 6) & 63)
  out[w + 3] = 128 | (code & 63)
  return w + 4
}

# Decode a raw JSON string body. The parser has already validated escapes, so
# this is also safe to use on a path's quoted key. A decoded NUL cannot appear
# in a path, but keeping the remaining bytes is harmless because tlang strings
# are NUL-terminated (the key simply becomes unaddressable).
fn json_decode_string(raw: str) -> str {
  let n = len(raw)
  let out = newbuf(n + 1)
  let i = 0
  let w = 0
  while i < n {
    let c = raw[i]
    if c != 92 {
      out[w] = c
      w = w + 1
      i = i + 1
    } else {
      i = i + 1
      if i >= n {
        break
      }
      let e = raw[i]
      if e == 117 {
        let code = 63
        if i + 4 < n {
          code = json_hex4(raw, i + 1)
        }
        i = i + 5
        if code >= 55296 && code <= 56319 && i + 5 < n && raw[i] == 92 && raw[i + 1] == 117 {
          let low = json_hex4(raw, i + 2)
          if low >= 56320 && low <= 57343 {
            code = 65536 + ((code - 55296) << 10) + (low - 56320)
            i = i + 6
          }
        }
        if code >= 55296 && code <= 57343 {
          code = 65533
        }
        w = json_put_utf8(out, w, code)
      } else {
        if e == 110 {
          out[w] = 10
        } else if e == 116 {
          out[w] = 9
        } else if e == 114 {
          out[w] = 13
        } else if e == 98 {
          out[w] = 8
        } else if e == 102 {
          out[w] = 12
        } else {
          out[w] = e
        }
        w = w + 1
        i = i + 1
      }
    }
  }
  return out
}

fn json_key_matches(raw: str, name: str) -> int {
  if raw == name {
    return 1
  }
  let decoded = json_decode_string(raw)
  let match = decoded == name
  free(decoded)
  if match {
    return 1
  }
  return 0
}

fn json_child_pair(obj: int, name: str) -> int {
  if obj < 0 || obj >= JSON_NNODE || JSON_KIND[obj] != JSON_OBJ {
    return -1
  }
  let first = JSON_FIRST[obj]
  let n = JSON_COUNT[obj] / 2
  for i in 0..n {
    if json_key_matches(JSON_TEXT[JSON_LINKS[first + i * 2]], name) == 1 {
      return i
    }
  }
  return -1
}

fn json_child_key(obj: int, name: str) -> int {
  let pair = json_child_pair(obj, name)
  if pair < 0 {
    return -1
  }
  return JSON_LINKS[JSON_FIRST[obj] + pair * 2 + 1]
}

# RFC 6901 pointers are Unicode strings beginning with '/'; each segment is a
# reference token. Validate the two escapes before decoding so `~2` and a
# trailing `~` are errors, not literal characters.
fn json_pointer_ok(token: str) -> int {
  let i = 0
  let n = len(token)
  while i < n {
    if token[i] == 126 {
      if i + 1 >= n {
        return 0
      }
      if token[i + 1] != 48 && token[i + 1] != 49 {
        return 0
      }
      i = i + 2
    } else {
      i = i + 1
    }
  }
  return 1
}

# Decode a validated JSON Pointer token: `~1` is '/', `~0` is '~'. A single
# pass is equivalent to RFC 6901's ordered substitutions and keeps `~01` as
# `~1` rather than turning it into '/'.
fn json_pointer_decode(token: str) -> str {
  let n = len(token)
  let out = newbuf(n + 1)
  let i = 0
  let w = 0
  while i < n {
    if token[i] == 126 {
      if token[i + 1] == 48 {
        out[w] = 126
      } else {
        out[w] = 47
      }
      w = w + 1
      i = i + 2
    } else {
      out[w] = token[i]
      w = w + 1
      i = i + 1
    }
  }
  return out
}

fn json_pointer_step(node: int, token: str) -> int {
  if node < 0 || node >= JSON_NNODE {
    return -1
  }
  let kind = JSON_KIND[node]
  if kind == JSON_OBJ {
    let name = json_pointer_decode(token)
    let found = json_child_key(node, name)
    free(name)
    return found
  }
  if kind != JSON_ARR {
    return -1
  }
  let n = len(token)
  if n == 0 {
    return -1
  }
  # The '-' token means the nonexistent element after the end; a resolver
  # cannot return a concrete node for it (RFC 6901 section 4).
  if token[0] == 45 {
    return -1
  }
  # RFC 6901 array-index = "0" / (1-9 *DIGIT).
  if token[0] == 48 && n > 1 {
    return -1
  }
  let index = 0
  let i = 0
  while i < n {
    if json_is_digit(token[i]) == 0 {
      return -1
    }
    index = index * 10 + (token[i] - 48)
    if index > JSON_MAX_NODES {
      return -1
    }
    i = i + 1
  }
  if index >= JSON_COUNT[node] {
    return -1
  }
  return JSON_LINKS[JSON_FIRST[node] + index]
}

# Resolve an RFC 6901 JSON Pointer. The empty pointer selects the root. A
# pointer that is syntactically invalid or names no value returns -1. Object
# keys are compared by decoded Unicode code points; duplicate names select the
# first member, since RFC 6901 leaves that case undefined.
fn json_pointer(root: int, ptr: str) -> int {
  if root < 0 || root >= JSON_NNODE {
    return -1
  }
  let n = len(ptr)
  if n == 0 {
    return root
  }
  if ptr[0] != 47 {
    return -1
  }
  let node = root
  let i = 0
  while i < n {
    if ptr[i] != 47 {
      return -1
    }
    i = i + 1
    let start = i
    while i < n && ptr[i] != 47 {
      i = i + 1
    }
    let token = slice(ptr, start, i - start)
    if json_pointer_ok(token) == 0 {
      free(token)
      return -1
    }
    node = json_pointer_step(node, token)
    free(token)
    if node < 0 {
      return -1
    }
  }
  return node
}

# Walk a jq-flavoured path: `.users[2].name`, `.tags[0]`, `.tags[-1]`,
# `.["a.b"]`, or `.`. A missing key, a bad index or a type mismatch returns -1.
fn json_get(root: int, path: str) -> int {
  if root < 0 || root >= JSON_NNODE {
    return -1
  }
  let n = len(path)
  if n == 0 || (n == 1 && path[0] == 46) {
    return root
  }
  let node = root
  let i = 0
  while i < n {
    if path[i] == 46 {
      i = i + 1
      if i >= n {
        return -1
      }
    }
    if path[i] == 91 {
      i = i + 1
      if i >= n {
        return -1
      }
      if path[i] == 34 {
        let start = i + 1
        i = i + 1
        while i < n && path[i] != 34 {
          if path[i] == 92 {
            i = i + 2
          } else {
            i = i + 1
          }
        }
        if i >= n {
          return -1
        }
        let raw = slice(path, start, i - start)
        i = i + 1
        if i >= n || path[i] != 93 {
          free(raw)
          return -1
        }
        i = i + 1
        let name = json_decode_string(raw)
        free(raw)
        node = json_child_key(node, name)
        free(name)
        if node < 0 {
          return -1
        }
        continue
      }
      let negative = 0
      if path[i] == 45 {
        negative = 1
        i = i + 1
      }
      let digits = i
      let index = 0
      while i < n && path[i] != 93 {
        if json_is_digit(path[i]) == 0 {
          return -1
        }
        index = index * 10 + (path[i] - 48)
        if index > JSON_MAX_NODES {
          return -1
        }
        i = i + 1
      }
      if i >= n || i == digits {
        return -1
      }
      i = i + 1
      if node < 0 || node >= JSON_NNODE || JSON_KIND[node] != JSON_ARR {
        return -1
      }
      let count = JSON_COUNT[node]
      if negative == 1 && index != 0 {
        index = count - index
      }
      if index < 0 || index >= count {
        return -1
      }
      node = JSON_LINKS[JSON_FIRST[node] + index]
      continue
    }
    let start = i
    while i < n && path[i] != 46 && path[i] != 91 {
      i = i + 1
    }
    if i == start {
      return -1
    }
    let name = slice(path, start, i - start)
    node = json_child_key(node, name)
    free(name)
    if node < 0 {
      return -1
    }
  }
  return node
}

# ---------------------------------------------------------------- building

# Encode plain text as a JSON string body (without the surrounding quotes).
# Short escapes are used for the common controls; other bytes below U+0020
# become \u00XX. Bytes above ASCII are copied as UTF-8.
fn json_encode_string(text: str) -> str {
  let n = len(text)
  let out = newbuf(n * 6 + 1)
  let i = 0
  let w = 0
  while i < n {
    let c = text[i]
    if c == 34 {
      out[w] = 92
      out[w + 1] = 34
      w = w + 2
    } else if c == 92 {
      out[w] = 92
      out[w + 1] = 92
      w = w + 2
    } else if c == 10 {
      out[w] = 92
      out[w + 1] = 110
      w = w + 2
    } else if c == 9 {
      out[w] = 92
      out[w + 1] = 116
      w = w + 2
    } else if c == 13 {
      out[w] = 92
      out[w + 1] = 114
      w = w + 2
    } else if c == 8 {
      out[w] = 92
      out[w + 1] = 98
      w = w + 2
    } else if c == 12 {
      out[w] = 92
      out[w + 1] = 102
      w = w + 2
    } else if c < 32 {
      out[w] = 92
      out[w + 1] = 117
      out[w + 2] = 48
      out[w + 3] = 48
      out[w + 4] = JSON_HEX[c >> 4]
      out[w + 5] = JSON_HEX[c & 15]
      w = w + 6
    } else {
      out[w] = c
      w = w + 1
    }
    i = i + 1
  }
  return out
}

fn json_number_ok(raw: str) -> int {
  let n = len(raw)
  let i = 0
  if i < n && raw[i] == 45 {
    i = i + 1
  }
  if i >= n {
    return 0
  }
  if raw[i] == 48 {
    i = i + 1
  } else if raw[i] >= 49 && raw[i] <= 57 {
    while i < n && json_is_digit(raw[i]) == 1 {
      i = i + 1
    }
  } else {
    return 0
  }
  if i < n && raw[i] == 46 {
    i = i + 1
    if i >= n || json_is_digit(raw[i]) == 0 {
      return 0
    }
    while i < n && json_is_digit(raw[i]) == 1 {
      i = i + 1
    }
  }
  if i < n && (raw[i] == 101 || raw[i] == 69) {
    i = i + 1
    if i < n && (raw[i] == 43 || raw[i] == 45) {
      i = i + 1
    }
    if i >= n || json_is_digit(raw[i]) == 0 {
      return 0
    }
    while i < n && json_is_digit(raw[i]) == 1 {
      i = i + 1
    }
  }
  if i == n {
    return 1
  }
  return 0
}

fn json_new_null() -> int {
  return json_add_text(JSON_NULL, "null")
}

fn json_new_bool(value: int) -> int {
  if value == 0 {
    return json_add_text(JSON_BOOL, "false")
  }
  return json_add_text(JSON_BOOL, "true")
}

fn json_new_int(value: int) -> int {
  return json_add_text(JSON_NUM, str(value))
}

# raw must be a JSON number token; json_new_int is the tlang integer form.
fn json_new_number(raw: str) -> int {
  if json_number_ok(raw) == 0 {
    return -1
  }
  return json_add_text(JSON_NUM, raw)
}

fn json_new_string(text: str) -> int {
  return json_add_text(JSON_STR, json_encode_string(text))
}

fn json_new_array() -> int {
  return json_add_node(JSON_ARR, "", JSON_NLINK, 0)
}

fn json_new_object() -> int {
  return json_add_node(JSON_OBJ, "", JSON_NLINK, 0)
}

# Return 1 when value already contains target, or when the value subtree is
# deeper than the parser limit. This prevents a builder update from creating a
# cycle (directly or through an ancestor) and catches runaway nesting before
# the emitter has to recurse through it.
fn json_subtree_contains(value: int, target: int, depth: int) -> int {
  if depth > JSON_MAX_DEPTH {
    return 1
  }
  if value < 0 || value >= JSON_NNODE {
    return 1
  }
  if value == target {
    return 1
  }
  if JSON_KIND[value] == JSON_ARR {
    let first = JSON_FIRST[value]
    let count = JSON_COUNT[value]
    for i in 0..count {
      if json_subtree_contains(JSON_LINKS[first + i], target, depth + 1) == 1 {
        return 1
      }
    }
  } else if JSON_KIND[value] == JSON_OBJ {
    let first = JSON_FIRST[value]
    let pairs = JSON_COUNT[value] / 2
    for i in 0..pairs {
      if json_subtree_contains(JSON_LINKS[first + i * 2 + 1], target, depth + 1) == 1 {
        return 1
      }
    }
  }
  return 0
}

# These updates mutate the node when its child run is already at the end of
# the shared link array, and otherwise return a new node. Callers assign the
# result, following the same convention as the append builtin.
fn json_array_push(arr: int, value: int) -> int {
  if arr < 0 || arr >= JSON_NNODE || JSON_KIND[arr] != JSON_ARR {
    return -1
  }
  if value < 0 || value >= JSON_NNODE || json_subtree_contains(value, arr, 1) == 1 {
    return -1
  }
  let count = JSON_COUNT[arr]
  let first = JSON_FIRST[arr]
  if first + count == JSON_NLINK && JSON_NLINK < JSON_MAX_LINKS {
    JSON_LINKS[JSON_NLINK] = value
    JSON_NLINK = JSON_NLINK + 1
    JSON_COUNT[arr] = count + 1
    return arr
  }
  if JSON_NLINK + count + 1 > JSON_MAX_LINKS || JSON_NNODE >= JSON_MAX_NODES {
    return -1
  }
  let start = JSON_NLINK
  let i = 0
  while i < count {
    JSON_LINKS[JSON_NLINK] = JSON_LINKS[first + i]
    JSON_NLINK = JSON_NLINK + 1
    i = i + 1
  }
  JSON_LINKS[JSON_NLINK] = value
  JSON_NLINK = JSON_NLINK + 1
  return json_add_node(JSON_ARR, "", start, count + 1)
}

fn json_array_set(arr: int, index: int, value: int) -> int {
  if arr < 0 || arr >= JSON_NNODE || JSON_KIND[arr] != JSON_ARR {
    return -1
  }
  if value < 0 || value >= JSON_NNODE || json_subtree_contains(value, arr, 1) == 1 {
    return -1
  }
  let count = JSON_COUNT[arr]
  if index < 0 {
    index = count + index
  }
  if index < 0 || index >= count {
    return -1
  }
  JSON_LINKS[JSON_FIRST[arr] + index] = value
  return arr
}

fn json_array_remove(arr: int, index: int) -> int {
  if arr < 0 || arr >= JSON_NNODE || JSON_KIND[arr] != JSON_ARR {
    return -1
  }
  let count = JSON_COUNT[arr]
  if index < 0 {
    index = count + index
  }
  if index < 0 || index >= count {
    return -1
  }
  let first = JSON_FIRST[arr]
  let i = index
  while i + 1 < count {
    JSON_LINKS[first + i] = JSON_LINKS[first + i + 1]
    i = i + 1
  }
  JSON_COUNT[arr] = count - 1
  if first + count == JSON_NLINK {
    JSON_NLINK = JSON_NLINK - 1
  }
  return arr
}

fn json_object_set(obj: int, key: str, value: int) -> int {
  if obj < 0 || obj >= JSON_NNODE || JSON_KIND[obj] != JSON_OBJ {
    return -1
  }
  if value < 0 || value >= JSON_NNODE || json_subtree_contains(value, obj, 1) == 1 {
    return -1
  }
  let pair = json_child_pair(obj, key)
  if pair >= 0 {
    JSON_LINKS[JSON_FIRST[obj] + pair * 2 + 1] = value
    return obj
  }
  let count = JSON_COUNT[obj]
  let first = JSON_FIRST[obj]
  let at_end = 0
  if first + count == JSON_NLINK {
    at_end = 1
  }
  if at_end == 1 {
    if JSON_NLINK + 2 > JSON_MAX_LINKS || JSON_NNODE >= JSON_MAX_NODES {
      return -1
    }
  } else {
    if JSON_NLINK + count + 2 > JSON_MAX_LINKS || JSON_NNODE + 1 >= JSON_MAX_NODES {
      return -1
    }
  }
  let keynode = json_add_text(JSON_STR, json_encode_string(key))
  if keynode < 0 {
    return -1
  }
  if at_end == 1 {
    JSON_LINKS[JSON_NLINK] = keynode
    JSON_LINKS[JSON_NLINK + 1] = value
    JSON_NLINK = JSON_NLINK + 2
    JSON_COUNT[obj] = count + 2
    return obj
  }
  let start = JSON_NLINK
  let i = 0
  while i < count {
    JSON_LINKS[JSON_NLINK] = JSON_LINKS[first + i]
    JSON_NLINK = JSON_NLINK + 1
    i = i + 1
  }
  JSON_LINKS[JSON_NLINK] = keynode
  JSON_LINKS[JSON_NLINK + 1] = value
  JSON_NLINK = JSON_NLINK + 2
  return json_add_node(JSON_OBJ, "", start, count + 2)
}

# Removes the first matching pair, returning the object unchanged if the key
# is absent. Duplicate names are not collapsed.
fn json_object_remove(obj: int, key: str) -> int {
  if obj < 0 || obj >= JSON_NNODE || JSON_KIND[obj] != JSON_OBJ {
    return -1
  }
  let pair = json_child_pair(obj, key)
  if pair < 0 {
    return obj
  }
  let count = JSON_COUNT[obj]
  let first = JSON_FIRST[obj]
  let at = first + pair * 2
  let i = at
  while i + 2 < first + count {
    JSON_LINKS[i] = JSON_LINKS[i + 2]
    i = i + 1
  }
  JSON_COUNT[obj] = count - 2
  if first + count == JSON_NLINK {
    JSON_NLINK = JSON_NLINK - 2
  }
  return obj
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

fn json_print_utf8(code: int) {
  if code < 128 {
    print_char(code)
  } else if code < 2048 {
    print_char(192 | (code >> 6))
    print_char(128 | (code & 63))
  } else if code < 65536 {
    print_char(224 | (code >> 12))
    print_char(128 | ((code >> 6) & 63))
    print_char(128 | (code & 63))
  } else {
    print_char(240 | (code >> 18))
    print_char(128 | ((code >> 12) & 63))
    print_char(128 | ((code >> 6) & 63))
    print_char(128 | (code & 63))
  }
}

# Decode a raw JSON string body onto stdout as UTF-8. Escapes are resolved one
# at a time because tlang string literals cannot express bytes such as \b;
# \u escapes, including surrogate pairs, are emitted as UTF-8. A lone
# surrogate becomes U+FFFD, matching json_decode_string.
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
      if i >= n {
        print_char(63)
        break
      }
      let e = s[i]
      if e == 117 {
        let code = 63
        if i + 4 < n {
          code = json_hex4(s, i + 1)
        }
        i = i + 5
        if code >= 55296 && code <= 56319 && i + 5 < n && s[i] == 92 && s[i + 1] == 117 {
          let low = json_hex4(s, i + 2)
          if low >= 56320 && low <= 57343 {
            code = 65536 + ((code - 55296) << 10) + (low - 56320)
            i = i + 6
          }
        }
        if code >= 55296 && code <= 57343 {
          code = 65533
        }
        json_print_utf8(code)
      } else {
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
        } else {
          print_char(e)
        }
        i = i + 1
      }
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
