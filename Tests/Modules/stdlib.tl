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
  if mode == "zip-create" {
    zip_create_test(argv(2))
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
