#!/usr/bin/env python3
"""Test the common Linux builtins in both compilers.

Time, entropy, process identity and directory operations are checked for
behaviour rather than fixed output: a timestamp or pid is not reproducible,
so the programs report invariants and the harness runs them in a private
temporary directory. Both stage 0 and the self-hosted compiler must agree.
"""

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TCOMP = os.path.join(ROOT, "tcomp")
PORT_MODULE = os.path.join(ROOT, "Modules", "tport.tl")
LDFLAGS = ["-s", "-z", "noseparate-code", "--build-id=none"]
sys.path.insert(0, ROOT)

from Bootstrap.elf import strip_sections  # noqa: E402

TIME_SRC = '''fn main() {
  print_int(now() > 0)
  print(" ")
  print_int(sleep_ns(1000000) == 0)
  print(" ")
  print_int(getpid() > 0)
  print(" ")
  print(getcwd())
  print(" ")
  let a = random_int()
  let b = random_int()
  print_int(a != b)
  print("\\n")
}
'''

FS_SRC = '''fn main() {
  print_int(mkdir(argv(1), 493))
  print(" ")
  print_int(write_file(argv(2), "hi"))
  print(" ")
  print_int(rename(argv(2), argv(3)))
  print(" ")
  print_int(unlink(argv(3)))
  print(" ")
  print_int(file_exists(argv(3)))
  print("\\n")
}
'''

FD_SRC = '''fn main() {
  let p = argv(1)
  let fd = open_fd(p, 1 | 64 | 512)
  print_int(fd >= 0)
  print(" ")
  print_int(fd_write(fd, "xyz", 3))
  print(" ")
  print_int(close_fd(fd))
  print(" ")
  print_int(file_mtime(p) > 0)
  print("\\n")
}
'''

PORT_SRC = '''import "@MODULE@"

fn main() {
  print_int(port_is_abs("/x"))
  print(" ")
  print(port_base("/a/b/"))
  print(" ")
  print(port_base("/"))
  print(" ")
  print(port_dir("/"))
  print(" ")
  print(port_dir("/a/b"))
  print(" ")
  print(port_ext("a.tar.gz"))
  print(" ")
  print(port_join("a/", "b"))
  print(" ")
  print_int(len(port_which("sh")) > 0)
  print(" ")
  print_int(len(port_which("tlang-no-such-command")) == 0)
  print("\\n")

  let root = argv(1)
  if port_mkdir_p(root + "/a/b") == 0 { print(port_error()) exit(1) }
  print_int(is_dir(root + "/a/b"))
  print(" ")
  print_int(port_copy(root, root + "/not-a-file"))
  print(" ")
  print_int(file_exists(root + "/not-a-file"))
  print(" ")
  let data = newbuf(5)
  data[0] = 0
  data[1] = 1
  data[2] = 255
  data[3] = 65
  data[4] = 66
  let fd = open_fd(root + "/src.bin", 1 | 64 | 512)
  fd_write(fd, data, 5)
  close_fd(fd)
  print_int(port_copy(root + "/src.bin", root + "/copy.bin"))
  print(" ")
  print_int(file_size(root + "/copy.bin"))
  print(" ")
  let got = read_file(root + "/copy.bin")
  print_int(ld8(got, 0) == 0 && ld8(got, 2) == 255)
  print(" ")
  print_int(port_move(root + "/copy.bin", root + "/moved.bin"))
  print(" ")
  print_int(file_exists(root + "/moved.bin") && file_exists(root + "/copy.bin") == 0)
  print(" ")
  print_int(port_remove(root + "/moved.bin"))
  print(" ")
  print_int(port_remove(root + "/src.bin"))
  print(" ")
  let big = newbuf(150000)
  let i = 0
  while i < 150000 {
    big[i] = i & 255
    i = i + 1
  }
  let bfd = open_fd(root + "/big.bin", 1 | 64 | 512)
  fd_write(bfd, big, 150000)
  close_fd(bfd)
  print_int(port_copy(root + "/big.bin", root + "/big-copy.bin"))
  print(" ")
  print_int(file_size(root + "/big-copy.bin"))
  print(" ")
  let bg = read_file(root + "/big-copy.bin")
  print_int(ld8(bg, 0) == 0 && ld8(bg, 65536) == 0 && ld8(bg, 149999) == 239)
  print(" ")
  print_int(port_remove(root + "/big.bin"))
  print(" ")
  print_int(port_remove(root + "/big-copy.bin"))
  print(" ")
  print_int(port_remove(root + "/a/b"))
  print(" ")
  print_int(port_remove(root + "/a"))
  print(" ")
  let args = alloc(3, str)
  args[0] = "sh"
  args[1] = "-c"
  args[2] = "exit 7"
  print_int(port_run(args))
  print(" ")
  args[2] = "test x$TL_PORT_ENV = xinherited"
  print_int(port_run(args) == 0)
  print(" ")
  print_int(len(port_stdin()))
  print("\\n")
}
'''.replace("@MODULE@", PORT_MODULE)

PORT_WANT = b"1 b / / /a .gz a/b 1 1\n1 0 0 1 5 1 1 1 1 1 1 150000 1 1 1 1 1 7 1 70000\n"

BAD_ARGS = (
    ('fn main() { now(1) }', 'now'),
    ('fn main() { sleep_ns("x") }', 'sleep_ns'),
    ('fn main() { mkdir(1, 2) }', 'mkdir'),
    ('fn main() { rename("a", 3) }', 'rename'),
)


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


def check_rejections(compiler, failures, label, work):
    for index, (source, name) in enumerate(BAD_ARGS):
        # The driver reads source from a path, not from "-"; writing a real
        # file keeps this a real rejection test rather than an open failure.
        path = os.path.join(work, f"bad-{label}-{index}.tl")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(source)
        if compiler is None:
            proc = subprocess.run([sys.executable, TCOMP, "build", path,
                                   "-o", os.devnull], capture_output=True,
                                  text=True)
        else:
            proc = subprocess.run([compiler, path], capture_output=True,
                                  text=True)
        if proc.returncode == 0:
            failures.append(f"{label}: {name}() accepted bad arguments")


def main():
    work = tempfile.mkdtemp(prefix="tlang-portability-")
    failures = []
    try:
        stage1 = build_stage1(work)
        for label, compiler in (("stage0", None), ("stage1", stage1)):
            time_exe = build(TIME_SRC, compiler, work, "time-" + label)
            fs_exe = build(FS_SRC, compiler, work, "fs-" + label)
            fd_exe = build(FD_SRC, compiler, work, "fd-" + label)
            port_exe = build(PORT_SRC, compiler, work, "port-" + label)

            got = subprocess.run([time_exe], cwd=work, capture_output=True,
                                 text=True)
            want = f"1 1 1 {work} 1\n"
            if (got.returncode, got.stdout) != (0, want):
                failures.append(f"{label}: time {got.returncode} {got.stdout!r}")

            path = os.path.join(work, "ops-" + label)
            a = os.path.join(path, "a.txt")
            b = os.path.join(path, "b.txt")
            got = subprocess.run([fs_exe, path, a, b], capture_output=True,
                                 text=True)
            if (got.returncode, got.stdout) != (0, "0 1 0 0 0\n"):
                failures.append(f"{label}: fs {got.returncode} {got.stdout!r}")
            shutil.rmtree(path, ignore_errors=True)

            out = os.path.join(work, "fd-" + label + ".txt")
            got = subprocess.run([fd_exe, out], capture_output=True, text=True)
            if (got.returncode, got.stdout) != (0, "1 3 0 1\n"):
                failures.append(f"{label}: fd {got.returncode} {got.stdout!r}")

            port_dir = os.path.join(work, "tport-" + label)
            got = subprocess.run([port_exe, port_dir], input=b"x" * 70000,
                                 env={**os.environ, "TL_PORT_ENV": "inherited"},
                                 capture_output=True)
            if (got.returncode, got.stdout) != (0, PORT_WANT):
                failures.append(
                    f"{label}: tport {got.returncode} {got.stdout!r} "
                    f"{got.stderr!r}")

            check_rejections(compiler, failures, label, work)
            if not any(f.startswith(label) for f in failures):
                print(f"  ok   {label}")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    if failures:
        for failure in failures:
            print("  FAIL " + failure)
        return 1
    print("\ncommon Linux builtins work in both compilers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
