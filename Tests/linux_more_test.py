#!/usr/bin/env python3
"""Newer Linux builtins: numeric TCP, exercised against real sockets.

A tlang client talks to a Python server, and a tlang server talks to a Python
client.  Both programs are built with the checked-in compiler and with a
self-hosted stage 1, so the generated dispatch and the runtime are covered on
both paths.  The filesystem/identity/mmap side lives in Tests/Cases/sysops.tl.
"""

import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TCOMP = os.path.join(ROOT, "tcomp")
LDFLAGS = ["-s", "-z", "noseparate-code", "--build-id=none"]
sys.path.insert(0, ROOT)

from Bootstrap.elf import strip_sections  # noqa: E402

CLIENT = '''fn main() {
  let fd = tcp_connect(argv(1), int(argv(2)))
  if fd < 0 {
    print("connect failed\\n")
    exit(1)
  }
  fd_write(fd, "ping", 4)
  let b = newbuf(8)
  let n = fd_read(fd, b, 4)
  print_int(n)
  print(" ")
  print(b)
  print("\\n")
  close_fd(fd)
}
'''

SERVER = '''fn main() {
  let lfd = tcp_listen(int(argv(1)))
  if lfd < 0 {
    print("listen failed\\n")
    exit(1)
  }
  let c = tcp_accept(lfd)
  if c < 0 {
    print("accept failed\\n")
    exit(1)
  }
  let b = newbuf(8)
  let n = fd_read(c, b, 3)
  fd_write(c, "seen", 4)
  print_int(n)
  print(" ")
  print(b)
  print("\\n")
  close_fd(c)
  close_fd(lfd)
}
'''

BAD_IP = 'fn main() {\n  print_int(tcp_connect("300.0.0.1", 80))\n  print("\\n")\n}\n'

LONG_OCTET = '''fn main() {
  let fd = tcp_connect("0127.0.0.1", int(argv(1)))
  if fd >= 0 {
    print("connected\\n")
    close_fd(fd)
  } else {
    print("rejected\\n")
  }
}
'''

BAD_TCP = '''fn main() {
  print_int(tcp_connect("127.0.0.1", 0))
  print(" ")
  print_int(tcp_connect("127.0.0.1", 70000))
  print(" ")
  print_int(tcp_connect("127.0.0.1.", 80))
  print(" ")
  print_int(tcp_connect(".127.0.0.1", 80))
  print(" ")
  print_int(tcp_connect("127..0.1", 80))
  print(" ")
  print_int(tcp_listen(0))
  print(" ")
  print_int(tcp_listen(70000))
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


def finish(proc, timeout=10):
    try:
        return proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        return proc.communicate()


def client_case(exe, label, failures):
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(10)
    port = listener.getsockname()[1]
    proc = subprocess.Popen([exe, "127.0.0.1", str(port)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True)
    try:
        conn, _ = listener.accept()
        conn.settimeout(10)
        data = conn.recv(4)
        if data != b"ping":
            failures.append(f"{label}: client sent {data!r}")
        conn.sendall(b"pong")
        conn.close()
    except (OSError, socket.timeout) as exc:
        failures.append(f"{label}: client socket failed: {exc}")
        proc.kill()
    finally:
        listener.close()
    out, err = finish(proc)
    if proc.returncode != 0 or out != "4 pong\n":
        failures.append(f"{label}: client exit {proc.returncode}, "
                        f"stdout {out!r}, stderr {err!r}")


def long_octet_case(exe, label, failures):
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(0.5)
    port = listener.getsockname()[1]
    proc = subprocess.Popen([exe, str(port)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True)
    conn = None
    try:
        conn, _ = listener.accept()
    except (OSError, socket.timeout):
        pass
    if conn is not None:
        conn.close()
        failures.append(f"{label}: four-digit octet was accepted")
        proc.kill()
    listener.close()
    out, err = finish(proc)
    if (proc.returncode, out) != (0, "rejected\n"):
        failures.append(f"{label}: long octet exit {proc.returncode}, "
                        f"stdout {out!r}, stderr {err!r}")


def server_case(exe, label, failures):
    port = free_port()
    proc = subprocess.Popen([exe, str(port)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True)
    conn = None
    for _ in range(100):
        try:
            conn = socket.create_connection(("127.0.0.1", port), timeout=0.2)
            break
        except OSError:
            if proc.poll() is not None:
                break
            time.sleep(0.05)
    if conn is None:
        out, err = finish(proc)
        failures.append(f"{label}: server never listened (stdout {out!r}, "
                        f"stderr {err!r})")
        return
    try:
        conn.settimeout(10)
        conn.sendall(b"hey")
        data = conn.recv(4)
        if data != b"seen":
            failures.append(f"{label}: server replied {data!r}")
    except (OSError, socket.timeout) as exc:
        failures.append(f"{label}: server socket failed: {exc}")
        proc.kill()
    finally:
        conn.close()
    out, err = finish(proc)
    if proc.returncode != 0 or out != "3 hey\n":
        failures.append(f"{label}: server exit {proc.returncode}, "
                        f"stdout {out!r}, stderr {err!r}")


def main():
    work = tempfile.mkdtemp(prefix="tlang-linux-more-")
    failures = []
    try:
        stage1 = build_stage1(work)
        for label, compiler in (("stage0", None), ("stage1", stage1)):
            client = build(CLIENT, compiler, work, "client-" + label)
            server = build(SERVER, compiler, work, "server-" + label)
            bad_ip = build(BAD_IP, compiler, work, "badip-" + label)
            bad_tcp = build(BAD_TCP, compiler, work, "badtcp-" + label)
            long_octet = build(LONG_OCTET, compiler, work, "longoctet-" + label)
            client_case(client, label, failures)
            server_case(server, label, failures)
            long_octet_case(long_octet, label, failures)
            got = subprocess.run([bad_ip], capture_output=True, text=True)
            if (got.returncode, got.stdout) != (0, "-1\n"):
                failures.append(f"{label}: bad IPv4 gave {got.stdout!r}")
            got = subprocess.run([bad_tcp], capture_output=True, text=True)
            if (got.returncode, got.stdout) != (0, "-1 -1 -1 -1 -1 -1 -1\n"):
                failures.append(f"{label}: bad TCP arguments gave {got.stdout!r}")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("numeric TCP client and server work in both compilers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
