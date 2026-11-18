# tjson -- a JSON processor: validate, pretty-print, and query.
#
#   tjson fmt [--compact] [file]        re-print the document
#   tjson get [--pointer] PATH [file]   print one value, decoded
#   tjson keys [--pointer] PATH [file]  list an object's keys
#
# PATH is jq-flavoured by default: `.users[2].name`, `.tags[0]`,
# `.tags[-1]`, `.["a.b"]`, or `.` for the root. With `--pointer`, PATH is an
# RFC 6901 JSON Pointer such as `/users/0/name` or `/a~1b`, and the empty
# pointer selects the root.
#
# The parser, tree accessors and emitter live in Modules/tjson.tl so programs
# can import them without going through this CLI. This file only handles
# arguments, diagnostics and the three commands.

import "../Modules/tjson.tl"

let COMPACT = 0

fn fail(msg: str) {
  print_err("tjson: ")
  print_err(msg)
  print_err("\n")
  exit(2)
}

fn load(path: str) -> int {
  let src = ""
  if path == "-" {
    src = read_file("/dev/stdin")
  } else {
    src = read_file(path)
  }
  if len(src) == 0 {
    fail("empty input or unreadable file")
  }
  let root = json_parse(src)
  if root < 0 {
    print_err("tjson: ")
    print_err(JSON_ERR)
    print_err(" at byte ")
    print_err(str(JSON_ERR_POS))
    print_err("\n")
    exit(2)
  }
  return root
}

fn report_missing(part: str) {
  print_err("tjson: no such key '")
  print_err(part)
  print_err("'\n")
  exit(1)
}

fn lookup(root: int, path: str, pointer: int) -> int {
  if pointer == 1 {
    return json_pointer(root, path)
  }
  return json_get(root, path)
}

fn list_keys(root: int, path: str, pointer: int) {
  let node = lookup(root, path, pointer)
  if node < 0 {
    report_missing(path)
  }
  if json_kind(node) != JSON_OBJ {
    print_err("tjson: that value is not an object\n")
    exit(1)
  }
  for i in 0..json_count(node) {
    json_print_decoded(json_key(node, i))
    print("\n")
  }
}

fn usage() {
  print("usage: tjson <command> [options] [file]\n")
  print("\n")
  print("  fmt [--compact] [file]   re-print the document (default: pretty)\n")
  print("  get [--pointer] PATH [file]\n")
  print("                           print one value, e.g. .users[0].name or .[\"a.b\"]\n")
  print("  keys [--pointer] PATH [file]\n")
  print("                           list an object's keys\n")
  print("\n")
  print("no file means standard input\n")
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
    if at < argc() {
      fail("too many arguments")
    }
    json_emit(load(path), COMPACT)
    print("\n")
    return
  }
  if cmd == "get" || cmd == "keys" {
    let at = 2
    let pointer = 0
    if at < argc() && argv(at) == "--pointer" {
      pointer = 1
      at = at + 1
    }
    if at >= argc() {
      fail("this command needs a path")
    }
    let path = argv(at)
    at = at + 1
    let file = "-"
    if at < argc() {
      file = argv(at)
      at = at + 1
    }
    if at < argc() {
      fail("too many arguments")
    }
    let root = load(file)
    if cmd == "keys" {
      list_keys(root, path, pointer)
      return
    }
    let node = lookup(root, path, pointer)
    if node < 0 {
      report_missing(path)
    }
    json_print_value(node)
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
