#!/usr/bin/env python3
"""Protocol-level test for twayland's wl_seat input.

A fake compositor on a private Unix socket advertises the four globals the
module binds, completes the xdg_surface configure handshake, then sends a
keymap message with an fd attached (the module must survive dropping it), a
key press, pointer motion and a button. `Tests/Wayland/events.tl` prints what
it saw; the expected line is checked byte for byte in both compilers.
"""

import os
import socket
import struct
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from Bootstrap.elf import strip_sections  # noqa: E402

TCOMP = os.path.join(ROOT, "tcomp")
PROGRAM = os.path.join(ROOT, "Tests", "Wayland", "events.tl")
EXPECTED = b"caps 3 key 16 1 motion 10 20 button 272 1 got 7\n"
LDFLAGS = ["-s", "-z", "noseparate-code", "--build-id=none"]
SERIAL = 41


def u32(body, off):
    return struct.unpack_from("<I", body, off)[0]


def p32(value):
    return struct.pack("<I", value)


def pstr(text):
    raw = text.encode() + b"\x00"
    return p32(len(raw)) + raw + b"\x00" * (-len(raw) % 4)


class FakeCompositor:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.sock.listen(1)
        self.conn = None
        self.registry = 0
        self.ids = {}
        self.surface = 0
        self.xsurf = 0
        self.seat = 0
        self.kb = 0
        self.ptr = 0
        self.configured = False
        self.caps_sent = False
        self.input_sent = False
        self.error = None

    def recv_exact(self, n):
        data = b""
        while len(data) < n:
            chunk = self.conn.recv(n - len(data))
            if not chunk:
                raise EOFError
            data += chunk
        return data

    def send(self, obj, op, body=b""):
        header = struct.pack("<II", obj, ((len(body) + 8) << 16) | op)
        self.conn.sendall(header + body)

    def send_with_fd(self, obj, op, body, fd):
        header = struct.pack("<II", obj, ((len(body) + 8) << 16) | op)
        self.conn.sendmsg([header + body],
                          [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                            struct.pack("<i", fd))])

    def run(self):
        self.sock.settimeout(30)
        try:
            self.conn, _ = self.sock.accept()
        except socket.timeout:
            self.error = "client did not connect within 30 seconds"
            return
        self.conn.settimeout(15)
        try:
            while True:
                header = self.recv_exact(8)
                obj, word = struct.unpack("<II", header)
                op, size = word & 0xFFFF, word >> 16
                body = self.recv_exact(size - 8) if size > 8 else b""
                self.handle(obj, op, body)
        except EOFError:
            pass
        except socket.timeout:
            self.error = "client did not finish within 15 seconds"
        finally:
            self.sock.close()

    def handle(self, obj, op, body):
        if obj == 1:
            if op == 1:                                  # get_registry
                self.registry = u32(body, 0)
                for name, iface, version in (
                        (1, "wl_compositor", 4),
                        (2, "wl_shm", 1),
                        (3, "xdg_wm_base", 1),
                        (4, "wl_seat", 4)):
                    self.send(self.registry, 0,
                              p32(name) + pstr(iface) + p32(version))
            elif op == 0:                                # sync
                self.send(u32(body, 0), 0, p32(SERIAL))
            return

        if obj == self.registry and op == 0:             # registry.bind
            length = u32(body, 4)
            iface = body[8:8 + length - 1].decode()
            off = 8 + ((length + 3) // 4) * 4
            oid = u32(body, off + 4)
            self.ids[iface] = oid
            if iface == "wl_seat":
                self.seat = oid
            return

        if obj == self.ids.get("wl_compositor") and op == 0:
            self.surface = u32(body, 0)                  # create_surface
            return

        if obj == self.ids.get("xdg_wm_base") and op == 2:
            self.xsurf = u32(body, 0)                    # get_xdg_surface
            return

        if obj == self.xsurf:
            if op == 1:
                return                                   # get_toplevel
            if op == 4:                                  # ack_configure
                if not self.caps_sent:
                    self.caps_sent = True
                    self.send(self.seat, 0, p32(3))      # pointer + keyboard
                return
            return

        if obj == self.surface and op == 6:              # commit
            if not self.configured:
                self.configured = True
                self.send(self.xsurf, 0, p32(0) + p32(64) + p32(48))
            return

        if obj == self.seat:
            if op == 1:
                self.kb = u32(body, 0)                   # get_keyboard
                self.send_input()
            elif op == 0:
                self.ptr = u32(body, 0)                  # get_pointer
                self.send_input()
            return

    def send_input(self):
        if self.input_sent or not self.kb or not self.ptr:
            return
        self.input_sent = True
        try:
            fd = os.memfd_create("tw-keymap")
            os.write(fd, b"xkb-keymap")
            self.send_with_fd(self.kb, 0, p32(1) + p32(10), fd)
            os.close(fd)
        except (AttributeError, OSError):
            # memfd_create is Linux-only, and this test is Linux-only anyway;
            # fall back to sending no keymap rather than failing on the fd.
            pass
        self.send(self.kb, 3, p32(SERIAL) + p32(0) + p32(16) + p32(1))
        self.send(self.ptr, 2, p32(0) + p32(10 * 256) + p32(20 * 256))
        self.send(self.ptr, 3, p32(SERIAL) + p32(0) + p32(272) + p32(1))


def build_stage1(work):
    exe = os.path.join(work, "tcomp1")
    subprocess.run([sys.executable, TCOMP, "build",
                    os.path.join(ROOT, "tcomp.tl"), "-o", exe],
                   check=True, capture_output=True)
    return exe


def link(work, asm_text, name):
    asm = os.path.join(work, name + ".s")
    obj = os.path.join(work, name + ".o")
    exe = os.path.join(work, name)
    with open(asm, "w") as fh:
        fh.write(asm_text)
    subprocess.run(["as", "--64", "-mx86-used-note=no", "-o", obj, asm],
                   check=True)
    subprocess.run(["ld", *LDFLAGS, "-o", exe, obj], check=True)
    strip_sections(exe)
    return exe


def run_against_fake(exe, work, name):
    path = os.path.join(work, name + ".sock")
    server = FakeCompositor(path)
    env = dict(os.environ, WAYLAND_DISPLAY=path)
    proc = subprocess.Popen([exe], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=env)
    try:
        server.run()
        try:
            out, err = proc.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
            out, err = proc.communicate()
            return [f"{name}: client hung"], out, err
    finally:
        if proc.poll() is None:
            proc.kill()
    failures = []
    if server.error:
        failures.append(f"{name}: {server.error}")
    if out != EXPECTED:
        failures.append(f"{name}: output mismatch\n"
                        f"  expected: {EXPECTED!r}\n  actual:   {out!r}")
    if err:
        failures.append(f"{name}: wrote to stderr: {err!r}")
    if proc.returncode != 0:
        failures.append(f"{name}: exit status {proc.returncode}")
    return failures, out, err


def main():
    failures = []
    with tempfile.TemporaryDirectory(prefix="tlang-wayland-") as work:
        stage1 = build_stage1(work)
        for label, compiler in (("stage0", None), ("stage1", stage1)):
            exe = os.path.join(work, "events-" + label)
            if compiler is None:
                built = subprocess.run([sys.executable, TCOMP, "build",
                                        PROGRAM, "-o", exe],
                                       capture_output=True)
                if built.returncode != 0:
                    failures.append(f"{label}: build failed\n"
                                    f"{built.stderr.decode(errors='replace')}")
                    continue
            else:
                built = subprocess.run([compiler, PROGRAM],
                                       capture_output=True)
                if built.returncode != 0:
                    failures.append(f"{label}: compile failed\n"
                                    f"{built.stderr.decode(errors='replace')}")
                    continue
                exe = link(work, built.stdout.decode(), "events-stage1")
            result, _, _ = run_against_fake(exe, work, label)
            failures.extend(result)
            print(f"  {'FAIL' if result else 'ok  '} {label}")

    if failures:
        print()
        for failure in failures:
            print(failure)
        return 1
    print("\nwayland input works in both compilers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
