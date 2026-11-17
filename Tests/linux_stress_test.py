#!/usr/bin/env python3
"""Stress the new Linux builtins: many files, many mappings, many sockets.

The TCP case runs a tlang echo server through 40 sequential connections,
including a 1 MiB transfer, and checks that its open-fd count is unchanged
afterwards.  Every program is built with the seed and with a self-hosted
stage 1.
"""

import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TCOMP = os.path.join(ROOT, "tcomp")
LDFLAGS = ["-s", "-z", "noseparate-code", "--build-id=none"]
sys.path.insert(0, ROOT)

from Bootstrap.elf import strip_sections  # noqa: E402

FS_STRESS = '''fn main() {
  let d = "/tmp/tlang_stress_" + getpid()
  mkdir(d, 493)
  chdir(d)
  let bad = 0
  let i = 0
  while i < 500 {
    let name = "f" + i
    write_file(name, "0123456789")
    truncate(name, 4)
    if file_size(name) != 4 { bad = bad + 1 }
    unlink(name)
    i = i + 1
  }
  let fd = open_fd("x", 577)
  fd_write(fd, "abcdef", 6)
  ftruncate(fd, 2)
  close_fd(fd)
  if file_size("x") != 2 { bad = bad + 1 }
  unlink("x")
  mkdir("sub", 493)
  write_file("sub/g", "x")
  let notempty = rmdir("sub") < 0
  unlink("sub/g")
  rmdir("sub")
  chdir("/")
  rmdir(d)
  print_int(bad)
  print(" ")
  print_int(notempty)
  print("\\n")
}
'''

MMAP_STRESS = '''fn main() {
  let bad = 0
  let i = 0
  while i < 2000 {
    let p = mmap(4096)
    let j = (i * 37) % 4096
    st8(p, j, i % 256)
    if ld8(p, j) != i % 256 { bad = bad + 1 }
    if mprotect(p, 4096, 3) != 0 { bad = bad + 1 }
    if munmap(p, 4096) != 0 { bad = bad + 1 }
    i = i + 1
  }
  let big = mmap(16777216)
  st64(big, 0, 1)
  st64(big, 16777208, 2)
  print_int(ld64(big, 0) + ld64(big, 16777208))
  munmap(big, 16777216)
  print(" ")
  print_int(bad)
  print("\\n")
}
'''

TCP_SERVER = '''fn count_fds() -> int {
  let d = open_dir("/proc/self/fd")
  let n = 0
  loop {
    let name = read_dir(d)
    if name == "" { break }
    n = n + 1
  }
  close_dir(d)
  return n
}

fn main() {
  let lfd = tcp_listen(int(argv(1)))
  if lfd < 0 {
    print("listen failed\\n")
    exit(1)
  }
  let before = count_fds()
  let rounds = int(argv(2))
  let total = 0
  let r = 0
  while r < rounds {
    let c = tcp_accept(lfd)
    if c < 0 {
      print("accept failed\\n")
      exit(1)
    }
    let b = newbuf(4096)
    loop {
      let n = fd_read(c, b, 4096)
      if n <= 0 { break }
      let off = 0
      while off < n {
        let w = fd_write(c, str_offset(b, off), n - off)
        if w <= 0 { break }
        off = off + w
      }
      total = total + n
    }
    close_fd(c)
    r = r + 1
  }
  let after = count_fds()
  close_fd(lfd)
  print_int(total)
  print(" ")
  print_int(after - before)
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


def free_port():
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def finish(proc, timeout=60):
    try:
        return proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        return proc.communicate()


def exchange(conn, payload):
    """Send and receive at the same time, so a 1 MiB echo cannot deadlock."""
    errors = []

    def send():
        try:
            conn.sendall(payload)
            conn.shutdown(socket.SHUT_WR)
        except OSError as exc:
            errors.append(exc)

    thread = threading.Thread(target=send)
    thread.start()
    chunks = []
    while True:
        data = conn.recv(65536)
        if not data:
            break
        chunks.append(data)
    thread.join()
    conn.close()
    return b"".join(chunks), errors


def connect(port):
    for _ in range(200):
        try:
            return socket.create_connection(("127.0.0.1", port), timeout=30)
        except OSError:
            time.sleep(0.05)
    return None


def tcp_stress(exe, label, failures):
    rounds = 40
    sizes = [(r * 997 % 60000) + 1 for r in range(rounds - 1)] + [1 << 20]
    port = free_port()
    proc = subprocess.Popen([exe, str(port), str(rounds)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True)
    conn = connect(port)
    if conn is None:
        out, err = finish(proc)
        failures.append(f"{label}: stress server never listened "
                        f"(stdout {out!r}, stderr {err!r})")
        return
    total = 0
    for index, size in enumerate(sizes):
        if index > 0:
            conn = connect(port)
            if conn is None:
                failures.append(f"{label}: connection {index} refused")
                proc.kill()
                return
        conn.settimeout(60)
        payload = bytes([65 + index % 26]) * size
        data, errors = exchange(conn, payload)
        if errors or data != payload:
            failures.append(
                f"{label}: round {index} ({size} B) got {len(data)} B, "
                f"errors {errors!r}")
            proc.kill()
            return
        total += size
    out, err = finish(proc)
    if proc.returncode != 0 or out != f"{total} 0\n":
        failures.append(f"{label}: stress server exit {proc.returncode}, "
                        f"stdout {out!r}, stderr {err!r}")


def run_checked(exe, expected, label, name, failures):
    got = subprocess.run([exe], capture_output=True, text=True, timeout=120)
    if (got.returncode, got.stdout) != (0, expected):
        failures.append(f"{label}: {name} exit {got.returncode}, "
                        f"stdout {got.stdout!r}, stderr {got.stderr!r}")


def main():
    work = tempfile.mkdtemp(prefix="tlang-linux-stress-")
    failures = []
    try:
        stage1 = build_stage1(work)
        for label, compiler in (("stage0", None), ("stage1", stage1)):
            fs = build(FS_STRESS, compiler, work, "fs-" + label)
            mm = build(MMAP_STRESS, compiler, work, "mmap-" + label)
            server = build(TCP_SERVER, compiler, work, "server-" + label)
            run_checked(fs, "0 1\n", label, "filesystem", failures)
            run_checked(mm, "3 0\n", label, "mmap", failures)
            tcp_stress(server, label, failures)
            print(f"  {'ok' if not failures else '..'}   {label}")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("filesystem, mmap and TCP stress pass in both compilers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
