#!/usr/bin/env python3
"""Stress the language with generated programs, checked against a Python model.

Every program is compiled by the Python bootstrap compiler and by a freshly
built self-hosted compiler; both must print exactly what the model predicts.
Covers expressions, arrays, append, for-each, switch, ++/--, structs, strings,
recursion and block comments.
"""

import os
import random
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PY = sys.executable
TCOMP = os.path.join(ROOT, "tcomp")
LDFLAGS = ["-s", "-z", "noseparate-code", "--build-id=none"]
sys.path.insert(0, ROOT)

from Bootstrap.elf import strip_sections  # noqa: E402


def link(work, asm, name):
    src = os.path.join(work, name + ".s")
    obj = os.path.join(work, name + ".o")
    exe = os.path.join(work, name)
    with open(src, "w") as fh:
        fh.write(asm)
    subprocess.run(["as", "--64", "-mx86-used-note=no", "-o", obj, src], check=True, capture_output=True)
    subprocess.run(["ld", *LDFLAGS, "-o", exe, obj], check=True, capture_output=True)
    strip_sections(exe)
    return exe


def build0(path, work, name):
    exe = os.path.join(work, name)
    proc = subprocess.run([PY, TCOMP, "build", path, "-o", exe],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip())
    return exe


def build1(stage1, path, work, name):
    proc = subprocess.run([stage1, path], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip())
    return link(work, proc.stdout, name)


def gen_expr(rng, depth=3):
    if depth == 0 or rng.random() < 0.3:
        return str(rng.randrange(0, 50))
    op = rng.choice(["+", "*", "&", "|", "^", "<<", ">>"])
    left = gen_expr(rng, depth - 1)
    if op in ("<<", ">>"):
        right = str(rng.randrange(0, 6))
    else:
        right = gen_expr(rng, depth - 1)
    return f"({left} {op} {right})"


def expr_program(rng):
    expr = gen_expr(rng)
    src = ('fn main() {\n  let x = ' + expr +
           '\n  print_int(x)\n  print("\\n")\n}\n')
    return ("expr", src, f"{eval(expr)}\n")


def array_program(rng):
    n = rng.randrange(0, 12)
    k = rng.randrange(1, 5)
    m = rng.choice([2, 3, 4])
    m2 = rng.choice([2, 3])
    c = rng.randrange(0, 10)
    src = f"""fn build(n: int) -> int[] {{
  let a = []
  let i = 0
  while i < n {{
    let v = i * {k}
    if v % {m} == 0 {{
      switch v % {m2} {{
        case 0 {{ a = append(a, v + {c}) }}
        else {{ a = append(a, v) }}
      }}
    }} else {{
      a = append(a, v)
    }}
    i++
  }}
  return a
}}

fn main() {{
  let a = build({n})
  let total = 0
  let count = 0
  for x in a {{
    if x % 3 == 0 {{
      continue
    }}
    total += x
    count++
  }}
  print_int(count)
  print(" ")
  print_int(total)
  print(" ")
  print_int(len(a))
  print("\\n")
}}
"""
    arr = []
    for i in range(n):
        v = i * k
        if v % m == 0:
            arr.append(v + c if v % m2 == 0 else v)
        else:
            arr.append(v)
    kept = [x for x in arr if x % 3 != 0]
    return ("array", src, f"{len(kept)} {sum(kept)} {len(arr)}\n")


def loop_switch_program(rng):
    n = rng.randrange(1, 20)
    k = rng.randrange(1, 6)
    src = f"""fn main() {{
  let total = 0
  let i = 0
  while i < {n} {{
    i++
    switch i % 4 {{
      case 0 {{ continue }}
      case 1 {{ total += 1 }}
      case 2, 3 {{ total += {k} }}
    }}
    if i % 5 == 0 {{
      break
    }}
    total += 10
  }}
  print_int(total)
  print("\\n")
}}
"""
    total = 0
    i = 0
    while i < n:
        i += 1
        r = i % 4
        if r == 0:
            continue
        total += 1 if r == 1 else k
        if i % 5 == 0:
            break
        total += 10
    return ("switch-loop", src, f"{total}\n")


def struct_program():
    src = """struct Pair { k: int, v: str }

fn main() {
  let pairs = alloc(0, Pair)
  pairs = append(pairs, Pair(1, "one"))
  pairs = append(pairs, Pair(2, "two"))
  pairs = append(pairs, Pair(3, "three"))
  for p in pairs {
    switch p.k {
      case 1 { print("int-one ") }
      case 2, 3 { print("int-few ") }
      else { print("int-? ") }
    }
    switch p.v {
      case "one" { print("str-one\\n") }
      case "two", "three" { print("str-few\\n") }
      else { print("str-?\\n") }
    }
  }
  print_int(len(pairs))
  print("\\n")
}
"""
    return ("struct-switch", src,
            "int-one str-one\nint-few str-few\nint-few str-few\n3\n")


def collatz_program():
    src = """fn collatz(n: int) -> int {
  switch n {
    case 0 { return 0 }
    case 1 { return 0 }
    else {
      if n % 2 == 0 {
        return 1 + collatz(n / 2)
      }
      return 1 + collatz(3 * n + 1)
    }
  }
  return 0
}

fn main() {
  let i = 1
  while i <= 20 {
    print_int(collatz(i))
    print(" ")
    i++
  }
  print("\\n")
}
"""

    def steps(n):
        count = 0
        while n > 1:
            n = n // 2 if n % 2 == 0 else 3 * n + 1
            count += 1
        return count

    expected = " ".join(str(steps(i)) for i in range(1, 21)) + " \n"
    return ("collatz", src, expected)


def comments_program():
    src = """/* header
   comment */
fn main() {
  /* before */
  let total = 0
  let i = 0 /* set */
  while i < 4 {
    i++
    total += i /* add */
  }
  /* after */
  print_int(total)
  print("\\n")
}
"""
    return ("comments", src, "10\n")


def words_program():
    src = """fn main() {
  let words = alloc(0, str)
  words = append(words, "a")
  words = append(words, "bb")
  words = append(words, "ccc")
  for w in words {
    switch len(w) {
      case 1 { print("1") }
      case 2 { print("2") }
      else { print("3") }
    }
    print(w)
    print(" ")
  }
  print("\\n")
}
"""
    return ("words", src, "1a 2bb 3ccc \n")


# PROGRAMS built below by the per-area generators.

PROGRAMS = []
rng = random.Random(20261111)
for _ in range(12):
    PROGRAMS.append(expr_program(rng))
for _ in range(6):
    PROGRAMS.append(array_program(rng))
PROGRAMS.append(struct_program())
for _ in range(6):
    PROGRAMS.append(loop_switch_program(rng))
PROGRAMS.append(collatz_program())
PROGRAMS.append(comments_program())
PROGRAMS.append(words_program())


def main():
    work = tempfile.mkdtemp(prefix="tlang-stress-")
    failures = []
    try:
        stage1 = os.path.join(work, "tcomp1")
        proc = subprocess.run(
            [PY, TCOMP, "build", os.path.join(ROOT, "tcomp.tl"), "-o", stage1],
            capture_output=True, text=True)
        if proc.returncode != 0:
            print(f"could not build the self-hosted compiler:\n{proc.stderr}")
            return 1

        for index, (kind, src, expected) in enumerate(PROGRAMS):
            path = os.path.join(work, f"p{index}.tl")
            with open(path, "w") as fh:
                fh.write(src)
            for which, builder in (("stage0", build0),
                                   ("stage1",
                                    lambda p, w, n: build1(stage1, p, w, n))):
                name = f"p{index}_{which}"
                try:
                    exe = builder(path, work, name)
                except RuntimeError as exc:
                    failures.append(f"{kind} #{index} [{which}] build: {exc}")
                    continue
                result = subprocess.run([exe], capture_output=True)
                if result.stdout != expected.encode():
                    failures.append(
                        f"{kind} #{index} [{which}] output\n"
                        f"  expected {expected.encode()!r}\n"
                        f"  actual   {result.stdout!r}\n"
                        f"  source:\n{src}")
                elif result.returncode != 0:
                    failures.append(
                        f"{kind} #{index} [{which}] exit {result.returncode}")
        print(f"  {len(PROGRAMS)} programs, 2 compilers, "
              f"{len(PROGRAMS) * 2} builds")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print()
    if failures:
        for failure in failures:
            print(failure)
            print()
        print(f"{len(failures)} failure(s)")
        return 1
    print(f"{len(PROGRAMS)} generated programs match the model in both compilers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
