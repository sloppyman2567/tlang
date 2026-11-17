#!/usr/bin/env python3
"""Test the directory, metadata and process builtins in both compilers.

Like portability_test.py, these programs report invariants rather than fixed
timestamps or pids.  Each one is built with stage 0 and with the self-hosted
compiler; the directory and process cases run in a private temporary tree.
"""

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TCOMP = os.path.join(ROOT, "tcomp")
LDFLAGS = ["-s", "-z", "noseparate-code", "--build-id=none"]
sys.path.insert(0, ROOT)

from Bootstrap.elf import strip_sections  # noqa: E402

DIR_SRC = '''fn has_name(d, want) {
  loop {
    let n = read_dir(d)
    if n == "" { return 0 }
    if str_eq(n, want) == 1 { return 1 }
  }
  return 0
}

fn main() {
  let p = argv(1)
  print_int(mkdir(p, 493))
  print(" ")
  write_file(p + "/a.txt", "hello")
  print_int(symlink(p + "/a.txt", p + "/link") == 0)
  print(" ")
  print_int(str_eq(readlink(p + "/link"), p + "/a.txt"))
  print(" ")
  print_int(file_mode(p + "/a.txt") > 0)
  print(" ")
  print_int(is_dir(p))
  print(" ")
  print_int(is_file(p + "/a.txt"))
  print(" ")
  print_int(chmod(p + "/a.txt", 384) == 0)
  print(" ")
  let d = open_dir(p)
  print_int(d >= 0)
  print(" ")
  print_int(has_name(d, "a.txt"))
  print(" ")
  close_dir(d)
  let d2 = open_dir(p)
  print_int(has_name(d2, "link"))
  print(" ")
  close_dir(d2)
  print_int(file_mode(p + "/missing") < 0)
  print("\\n")
}
'''

PROC_SRC = '''fn main() {
  let fds = alloc(2)
  print_int(pipe(fds) == 0)
  print(" ")
  let pid = fork()
  if pid == 0 {
    close_fd(fds[0])
    fd_write(fds[1], "hi", 2)
    close_fd(fds[1])
    exit(7)
  }
  close_fd(fds[1])
  let buf = newbuf(8)
  let n = fd_read(fds[0], buf, 8)
  close_fd(fds[0])
  print_int(n)
  print(" ")
  print(buf)
  print(" ")
  let st = waitpid(pid, 0)
  print_int(st >= 0)
  print(" ")
  print_int((st & 127) == 0)
  print(" ")
  print_int((st >> 8) & 255)
  print(" ")
  print_int(getppid() > 1)
  print(" ")
  let c = fork()
  if c == 0 {
    sleep_ns(5000000000)
    exit(0)
  }
  kill(c, 15)
  let st2 = waitpid(c, 0)
  print_int((st2 & 127) != 0)
  print("\\n")
}
'''

EXEC_SRC = '''fn main() {
  let args = alloc(4, str)
  args[0] = "echo"
  args[1] = "hello"
  args[2] = "from"
  args[3] = "exec"
  let r = exec("/bin/echo", args)
  print_int(r)
  print("\\n")
}
'''

# Wrong arity must name the builtin and the actual count in both compilers.
BAD_ARITY = (
    ('fn main() { now(1) }', "now() takes 0 argument(s), got 1"),
    ('fn main() { chmod() }', "chmod() takes 2 argument(s), got 0"),
    ('fn main() { chmod("a") }', "chmod() takes 2 argument(s), got 1"),
    ('fn main() { symlink("a", "b", "c") }',
     "symlink() takes 2 argument(s), got 3"),
)

# Closing a directory must release its read_dir cursor: the next open_dir may
# reuse the same fd and must not continue returning the old directory's names.
REUSE_SRC = '''fn main() {
  let a = argv(1)
  let b = argv(2)
  write_file(a + "/a1", "x")
  write_file(b + "/b1", "x")
  let d1 = open_dir(a)
  let first = read_dir(d1)
  print_int(first[0] == 97)
  print(" ")
  close_dir(d1)
  let d2 = open_dir(b)
  let second = read_dir(d2)
  print_int(second[0] == 98)
  print(" ")
  close_dir(d2)
  print("\\n")
}
'''

# waitpid with WNOHANG returns 0 while the child is still running; it must not
# read the uninitialized status slot on a zero syscall result.
WNOHANG_SRC = '''fn main() {
  let p = fork()
  if p == 0 {
    sleep_ns(2000000000)
    exit(0)
  }
  print_int(waitpid(p, 1))
  print(" ")
  kill(p, 15)
  waitpid(p, 0)
  print("\\n")
}
'''

# A probe we exec with a dirty stack; it reports the argc it actually received.
PROBE_SRC = '''fn main() {
  print_int(argc())
  print(" ")
  for i in 0..argc() {
    print(argv(i))
    print(",")
  }
  print("\\n")
}
'''

DIRTY_LOCALS = "\n".join(f"  let v{i} = {i}" for i in range(80))
EXEC_DIRTY_SRC = '''fn dirty() {
%s
}

fn main() {
  dirty()
  let args = alloc(4, str)
  args[0] = "echo"
  args[1] = "hello"
  args[2] = "from"
  args[3] = "exec"
  exec(argv(1), args)
}
''' % DIRTY_LOCALS

# A fifth concurrent directory has no cursor slot; it must fail cleanly with
# "" rather than reading past the four-slot cursor arrays in BSS.
FIVEDIRS_SRC = '''fn main() {
  let ds = alloc(5)
  for i in 0..5 {
    ds[i] = open_dir(argv(i + 1))
  }
  for i in 0..4 {
    read_dir(ds[i])
  }
  print_int(read_dir(ds[4]) == "")
  print(" ")
  print_int(read_dir(ds[0]) != "")
  print("\\n")
}
'''


def build_stage1(work):
    compiler = os.path.join(work, "tcomp1")
    subprocess.run([sys.executable, TCOMP, "build",
                    os.path.join(ROOT, "tcomp.tl"), "-o", compiler],
                   check=True, capture_output=True)
    return compiler


def build(source, compiler, work, name):
    text = os.path.join(work, name + ".tl")
    exe = os.path.join(work, name)
    with open(text, "w", encoding="utf-8") as fh:
        fh.write(source)
    if compiler is None:
        subprocess.run([sys.executable, TCOMP, "build", text, "-o", exe],
                       check=True, capture_output=True)
        return exe
    proc = subprocess.run([compiler, text], capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode(errors="replace"))
    asm = os.path.join(work, name + ".s")
    obj = os.path.join(work, name + ".o")
    with open(asm, "wb") as fh:
        fh.write(proc.stdout)
    subprocess.run(["as", "--64", "-mx86-used-note=no", "-o", obj, asm],
                   check=True)
    subprocess.run(["ld", *LDFLAGS, "-o", exe, obj], check=True)
    strip_sections(exe)
    return exe


def check_diagnostics(compiler, failures, label, work, serial):
    for source, expected in BAD_ARITY:
        path = os.path.join(work, f"bad-{label}-{serial}.tl")
        serial += 1
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(source)
        if compiler is None:
            proc = subprocess.run([sys.executable, TCOMP, "build", path,
                                   "-o", os.devnull], capture_output=True,
                                  text=True)
        else:
            proc = subprocess.run([compiler, path], capture_output=True,
                                  text=True)
        text = proc.stderr + proc.stdout
        if proc.returncode == 0 or expected not in text:
            failures.append(f"{label}: expected {expected!r}, got {text!r}")
    return serial


def main():
    work = tempfile.mkdtemp(prefix="tlang-linux-extra-")
    failures = []
    try:
        stage1 = build_stage1(work)
        probe = build(PROBE_SRC, None, work, "probe")
        serial = 0
        for label, compiler in (("stage0", None), ("stage1", stage1)):
            dir_exe = build(DIR_SRC, compiler, work, "dir-" + label)
            proc_exe = build(PROC_SRC, compiler, work, "proc-" + label)
            exec_exe = build(EXEC_SRC, compiler, work, "exec-" + label)
            reuse_exe = build(REUSE_SRC, compiler, work, "reuse-" + label)
            wno_exe = build(WNOHANG_SRC, compiler, work, "wno-" + label)
            dirty_exe = build(EXEC_DIRTY_SRC, compiler, work,
                              "dirty-" + label)
            five_exe = build(FIVEDIRS_SRC, compiler, work, "five-" + label)

            tree = os.path.join(work, "tree-" + label)
            got = subprocess.run([dir_exe, tree], capture_output=True,
                                 text=True)
            if (got.returncode, got.stdout) != (0, "0 1 1 1 1 1 1 1 1 1 1\n"):
                failures.append(f"{label}: dir {got.returncode} {got.stdout!r}")
            shutil.rmtree(tree, ignore_errors=True)

            got = subprocess.run([proc_exe], capture_output=True, text=True,
                                 timeout=20)
            if (got.returncode, got.stdout) != (0, "1 2 hi 1 1 7 1 1\n"):
                failures.append(
                    f"{label}: process {got.returncode} {got.stdout!r}")

            got = subprocess.run([exec_exe], capture_output=True, text=True)
            if (got.returncode, got.stdout) != (0, "hello from exec\n"):
                failures.append(f"{label}: exec {got.returncode} {got.stdout!r}")

            a = os.path.join(work, "reuse-a-" + label)
            b = os.path.join(work, "reuse-b-" + label)
            os.mkdir(a)
            os.mkdir(b)
            got = subprocess.run([reuse_exe, a, b], capture_output=True,
                                 text=True)
            if (got.returncode, got.stdout) != (0, "1 1 \n"):
                failures.append(f"{label}: fd reuse {got.stdout!r}")
            shutil.rmtree(a)
            shutil.rmtree(b)

            got = subprocess.run([wno_exe], capture_output=True, text=True,
                                 timeout=20)
            if (got.returncode, got.stdout) != (0, "0 \n"):
                failures.append(f"{label}: WNOHANG {got.stdout!r}")

            got = subprocess.run([dirty_exe, probe], capture_output=True,
                                 text=True, timeout=20)
            if (got.returncode, got.stdout) != (0, "4 echo,hello,from,exec,\n"):
                failures.append(f"{label}: dirty exec {got.stdout!r}")

            five = [os.path.join(work, f"five-{label}-{i}") for i in range(5)]
            for path in five:
                os.mkdir(path)
                for name in ("first", "second"):
                    open(os.path.join(path, name), "w").close()
            got = subprocess.run([five_exe, *five], capture_output=True,
                                 text=True)
            if (got.returncode, got.stdout) != (0, "1 1\n"):
                failures.append(f"{label}: five dirs {got.stdout!r}")
            for path in five:
                shutil.rmtree(path)

            serial = check_diagnostics(compiler, failures, label, work, serial)
            if not any(f.startswith(label) for f in failures):
                print(f"  ok   {label}")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    if failures:
        for failure in failures:
            print("  FAIL " + failure)
        return 1
    print("\ndirectory, metadata and process builtins work in both compilers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
