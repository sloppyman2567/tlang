# Stdlib module test driver: JSON accessors and ZIP read/write.
# The Python test compares this output with the json and zipfile modules.

import "../../Modules/tjson.tl"
import "../../Modules/tzip.tl"

let HEX = "0123456789abcdef"

fn hexdump(data: str, n: int) {
  let i = 0
  while i < n {
    let c = data[i] & 255
    print_char(HEX[c >> 4])
    print_char(HEX[c & 15])
    i = i + 1
  }
}

fn json_bad(src: str) {
  let root = json_parse(src)
  print_int(root)
  print("|")
  print(json_error())
  print("|")
  print_int(json_error_pos())
  print("\n")
}

fn json_check() {
  let doc = "{\"name\":\"tlang\",\"tags\":[\"fast\",1,true,null],\"nested\":{\"x\":-1.5e2}}"
  let root = json_parse(doc)
  print_int(root)
  print("|")
  print(json_text(json_get(root, ".name")))
  print("|")
  print_int(json_count(json_get(root, ".tags")))
  print("|")
  print_int(json_kind(json_get(root, ".tags[2]")))
  print("|")
  print_int(json_get(root, ".missing"))
  print("|")
  print(json_text(json_get(root, ".nested.x")))
  print("\n")
  print_int(json_get(root, ".tags[x]"))
  print("\n")
  json_emit(root, 0)
  print("\n")
  json_emit(root, 1)
  print("\n")

  json_bad("{\"a\":1,}")
  json_bad("01")
  json_bad("\"a\n\"")
  json_bad("1.")

  # Invalid tree indices are API errors, not out-of-bounds accesses.
  print_int(json_child(-1, 0))
  print(" ")
  print_int(json_get(-1, "[0]"))
  print(" ")
  print_int(json_has(-1, ".x"))
  print("\n")

  json_extended()
  json_pointer_check()
  json_unicode_check()
  json_build_check()
}

fn json_extended() {
  let root = json_parse("{\"a\\u0062\":7,\"a.b\":8,\"a[b]\":9,\"na\\u00efve\":10,\"quote\\\"key\":11}")
  if root < 0 {
    print("ext-error ")
    print(json_error())
    print("\n")
    return
  }
  print(json_text(json_get(root, ".ab")))
  print(" ")
  print(json_text(json_get(root, ".[\"a.b\"]")))
  print(" ")
  print(json_text(json_get(root, "[\"a[b]\"]")))
  print(" ")
  print(json_text(json_get(root, ".[\"na\\u00efve\"]")))
  print(" ")
  print(json_text(json_get(root, ".[\"quote\\\"key\"]")))
  print(" ")
  print_int(json_get(root, ".[\"nope\"]"))
  print(" ")
  print_int(json_get(root, ".[\"a.b]"))
  print("\n")
}

fn json_pointer_check() {
  # RFC 6901 section 5 example document and pointer table. The expected
  # values are the ones printed by the RFC, in the same order.
  let doc = "{\"foo\":[\"bar\",\"baz\"],\"\":0,\"a/b\":1,\"c%d\":2,\"e^f\":3,\"g|h\":4,\"i\\\\j\":5,\"k\\\"l\":6,\" \":7,\"m~n\":8}"
  let root = json_parse(doc)
  if root < 0 {
    print("pointer-error ")
    print(json_error())
    print("\n")
    return
  }
  print_int(json_kind(json_pointer(root, "")))
  print("|")
  print_int(json_count(json_pointer(root, "/foo")))
  print("|")
  print(json_text(json_pointer(root, "/foo/0")))
  print("|")
  print(json_text(json_pointer(root, "/")))
  print("|")
  print(json_text(json_pointer(root, "/a~1b")))
  print("|")
  print(json_text(json_pointer(root, "/c%d")))
  print("|")
  print(json_text(json_pointer(root, "/e^f")))
  print("|")
  print(json_text(json_pointer(root, "/g|h")))
  print("|")
  print(json_text(json_pointer(root, "/i\\j")))
  print("|")
  print(json_text(json_pointer(root, "/k\"l")))
  print("|")
  print(json_text(json_pointer(root, "/ ")))
  print("|")
  print(json_text(json_pointer(root, "/m~0n")))
  print("\n")

  # Invalid syntax, out-of-range indices and non-container traversal all fail.
  print_int(json_pointer(root, "foo"))
  print(" ")
  print_int(json_pointer(root, "/foo/01"))
  print(" ")
  print_int(json_pointer(root, "/foo/-"))
  print(" ")
  print_int(json_pointer(root, "/a~2b"))
  print(" ")
  print_int(json_pointer(root, "/m~"))
  print(" ")
  print_int(json_pointer(root, "/foo/2"))
  print(" ")
  print_int(json_pointer(root, "/foo/0/x"))
  print("\n")

  # RFC 6901 replaces ~1 before ~0, so ~01 is the key "~1", not "/".
  let escapes = json_parse("{\"~1\":9,\"/\":10,\"~0\":11}")
  if escapes < 0 {
    print("escape-error\n")
    return
  }
  print(json_text(json_pointer(escapes, "/~01")))
  print(" ")
  print(json_text(json_pointer(escapes, "/~00")))
  print(" ")
  print(json_text(json_pointer(escapes, "/~1")))
  print("\n")
}

fn json_unicode_check() {
  let root = json_parse("{\"caf\\u00e9\":\"caf\\u00e9\",\"\\uD834\\uDD1E\":\"clef\"}")
  if root < 0 {
    print("unicode-error ")
    print(json_error())
    print("\n")
    return
  }
  json_print_value(json_get(root, ".[\"caf\\u00e9\"]"))
  json_print_value(json_get(root, ".[\"\\uD834\\uDD1E\"]"))
  json_print_decoded(json_key(root, 0))
  print(" ")
  json_print_decoded(json_key(root, 1))
  print("\n")
}

fn json_build_check() {
  let arr = json_new_array()
  arr = json_array_push(arr, json_new_string("first"))
  arr = json_array_push(arr, json_new_int(2))
  arr = json_array_push(arr, json_new_bool(1))
  arr = json_array_push(arr, json_new_null())
  arr = json_array_set(arr, -1, json_new_string("last"))
  arr = json_array_remove(arr, 0)

  let obj = json_new_object()
  obj = json_object_set(obj, "name", json_new_string("tlang"))
  obj = json_object_set(obj, "items", arr)
  obj = json_object_set(obj, "name", json_new_string("updated"))
  obj = json_object_remove(obj, "missing")
  obj = json_object_remove(obj, "name")
  json_emit(obj, 1)
  print("\n")

  let esc = json_new_string("line\nquote\"slash\\")
  json_emit(esc, 1)
  print("\n")
  print_int(json_new_number("01"))
  print(" ")
  print(json_text(json_new_number("1.5e2")))
  print("\n")
  print_int(json_array_push(arr, arr))
  print(" ")
  print_int(json_object_set(obj, "self", obj))
  print(" ")
  let cycle_a = json_new_array()
  let cycle_b = json_new_array()
  cycle_a = json_array_push(cycle_a, cycle_b)
  print_int(json_array_push(cycle_b, cycle_a))
  print(" ")
  let cycle_obj_a = json_new_object()
  let cycle_obj_b = json_new_object()
  cycle_obj_a = json_object_set(cycle_obj_a, "child", cycle_obj_b)
  print_int(json_object_set(cycle_obj_b, "back", cycle_obj_a))
  print("\n")

  # Parsed containers usually have siblings' links after their own run, so
  # these updates take the copy path and leave the original node unchanged.
  let parsed = json_parse("{\"a\":[1],\"nested\":{\"x\":1},\"b\":2}")
  let a = json_get(parsed, ".a")
  let a2 = json_array_push(a, json_new_int(2))
  json_emit(a2, 1)
  print("\n")
  json_emit(a, 1)
  print("\n")
  let nested = json_get(parsed, ".nested")
  let nested2 = json_object_set(nested, "y", json_new_int(3))
  json_emit(nested2, 1)
  print("\n")
  json_emit(nested, 1)
  print("\n")
}

fn json_file(path: str) {
  let root = json_parse_file(path)
  if root < 0 {
    print("error ")
    print(json_error())
    print("\n")
    exit(1)
  }
  json_emit(root, 1)
  print("\n")
}

fn zip_create_test(path: str) {
  if zip_create(path) == 0 {
    print("create-fail ")
    print_int(zip_error())
    print("\n")
    exit(1)
  }
  if zip_add("hello.txt", "hello\n", 6) == 0 {
    print("add-fail ")
    print_int(zip_error())
    print("\n")
    exit(1)
  }
  let bin = newbuf(4)
  bin[0] = 0
  bin[1] = 1
  bin[2] = 255
  bin[3] = 65
  if zip_add("bin.dat", bin, 4) == 0 {
    print("add-fail ")
    print_int(zip_error())
    print("\n")
    exit(1)
  }
  if zip_add("empty", "", 0) == 0 {
    print("add-fail ")
    print_int(zip_error())
    print("\n")
    exit(1)
  }
  let repeated = newbuf(800)
  let letters = "abcd"
  for i in 0..800 {
    repeated[i] = letters[i % 4]
  }
  if zip_add("repeat.txt", repeated, 800) == 0 {
    print("add-fail ")
    print_int(zip_error())
    print("\n")
    exit(1)
  }
  if zip_add("dir/nested.txt", "nested", 6) == 0 {
    print("add-fail ")
    print_int(zip_error())
    print("\n")
    exit(1)
  }
  if zip_finish() == 0 {
    print("finish-fail ")
    print_int(zip_error())
    print("\n")
    exit(1)
  }
  print("created ")
  print_int(zip_count())
  print("\n")
}

fn zip_count_test(path: str) {
  let n = zip_open(path)
  if n < 0 {
    print("error ")
    print_int(zip_error())
    print("\n")
    exit(1)
  }
  print_int(n)
  print("\n")
}

fn zip_file_test(path: str, name: str, src: str) {
  if zip_create(path) == 0 {
    print("create-fail ")
    print_int(zip_error())
    print("\n")
    exit(1)
  }
  if zip_add_file(name, src) == 0 {
    print("add-fail ")
    print_int(zip_error())
    print("\n")
    exit(1)
  }
  if zip_finish() == 0 {
    print("finish-fail ")
    print_int(zip_error())
    print("\n")
    exit(1)
  }
  print("created ")
  print_int(zip_count())
  print("\n")
}

fn zip_stress_test(path: str) {
  if zip_create(path) == 0 {
    print("create-fail ")
    print_int(zip_error())
    print("\n")
    exit(1)
  }
  let text = "the quick brown fox jumps over the lazy dog\n"
  let period = len(text)
  let large = newbuf(60000)
  for i in 0..60000 {
    large[i] = text[i % period]
  }
  if zip_add("large.txt", large, 60000) == 0 {
    print("add-fail ")
    print_int(zip_error())
    print("\n")
    exit(1)
  }
  let noisy = newbuf(20000)
  let x = 7
  for i in 0..20000 {
    x = (x * 1103515245 + 12345) & 0x7FFFFFFF
    noisy[i] = x & 255
  }
  if zip_add("random.bin", noisy, 20000) == 0 {
    print("add-fail ")
    print_int(zip_error())
    print("\n")
    exit(1)
  }
  let binary = newbuf(1000)
  for i in 0..1000 {
    binary[i] = i & 255
  }
  if zip_add("binary.bin", binary, 1000) == 0 {
    print("add-fail ")
    print_int(zip_error())
    print("\n")
    exit(1)
  }
  if zip_finish() == 0 {
    print("finish-fail ")
    print_int(zip_error())
    print("\n")
    exit(1)
  }
  print("created ")
  print_int(zip_count())
  print("\n")
}

fn zip_list(path: str) {
  let n = zip_open(path)
  if n < 0 {
    print("error ")
    print_int(zip_error())
    print("\n")
    exit(1)
  }
  print_int(n)
  print("\n")
  for i in 0..n {
    print(zip_name(i))
    print("|")
    print_int(zip_method(i))
    print("|")
    print_int(zip_size(i))
    print("|")
    print_int(zip_crc(i))
    print("|")
    let data = zip_data(i)
    if zip_error() == 0 {
      hexdump(data, zip_size(i))
    } else {
      print("dataerr")
    }
    print("\n")
  }
}

fn zip_extract_test(path: str, index: int, out: str) {
  let n = zip_open(path)
  if n < 0 {
    print("open-fail ")
    print_int(zip_error())
    print("\n")
    exit(1)
  }
  let ok = zip_extract(index, out)
  print_int(ok)
  print(" ")
  print_int(zip_error())
  print("\n")
}

fn main() {
  if argc() < 2 {
    print("usage: stdlib json|zip-create|zip-list|zip-extract ...\n")
    exit(2)
  }
  let mode = argv(1)
  if mode == "json" {
    json_check()
    return
  }
  if mode == "json-file" {
    json_file(argv(2))
    return
  }
  if mode == "zip-create" {
    zip_create_test(argv(2))
    return
  }
  if mode == "zip-file" {
    zip_file_test(argv(2), argv(3), argv(4))
    return
  }
  if mode == "zip-count" {
    zip_count_test(argv(2))
    return
  }
  if mode == "zip-stress" {
    zip_stress_test(argv(2))
    return
  }
  if mode == "zip-list" {
    zip_list(argv(2))
    return
  }
  if mode == "zip-extract" {
    zip_extract_test(argv(2), int(argv(3)), argv(4))
    return
  }
  print("unknown mode\n")
  exit(2)
}
