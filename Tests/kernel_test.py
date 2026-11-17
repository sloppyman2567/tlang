#!/usr/bin/env python3
"""The desktop boots, runs its apps, and keeps a file across a reboot.

Builds Kernel/kernel.img, boots it under QEMU with COM1 in a file, a monitor
socket and a second disk for the filesystem, then drives it: mouse clicks on
the close button and the taskbar, typed shell commands, the editor saving with
Ctrl+S, and `halt` (isa-debug-exit gives 33).  The filesystem disk is kept, and
a second boot reads the edited file back, so persistence is checked end to end
rather than assumed.

Skips with exit 77 when QEMU is not installed.
"""

import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMAGE = os.path.join(ROOT, "Kernel", "kernel.img")
FLAT = os.path.join(ROOT, "Kernel", "kernel.bin")
LOAD_BYTES = 192 * 512         # the window Kernel/mbr.s reads
FS_BYTES = 1024 * 512          # the filesystem disk the kernel formats
EXIT_HALTED = 33               # (0x10 << 1) | 1, from isa-debug-exit
HAVE_ISSUES = 1
SKIPPED = 77

# QEMU key names that differ from the character they type.
KEY_NAMES = {
    " ": "spc", "\n": "ret", "\b": "backspace",
    ".": "dot", ",": "comma", "/": "slash", "\\": "backslash",
    "-": "minus", "=": "equal", ";": "semicolon", "'": "apostrophe",
    "[": "bracket_left", "]": "bracket_right", "`": "grave_accent",
    "*": "shift-8", "+": "shift-equal", "_": "shift-minus",
}


def read_log(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except FileNotFoundError:
        return ""


def wait_for_log(path, needle, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        text = read_log(path)
        if needle in text:
            return text
        time.sleep(0.1)
    return None


class Monitor:
    """The QEMU monitor, used only to type keys and move the pointer."""

    def __init__(self, path):
        deadline = time.time() + 30
        while True:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                sock.connect(path)
            except (FileNotFoundError, ConnectionRefusedError):
                sock.close()
                if time.time() > deadline:
                    raise
                time.sleep(0.1)
            else:
                self.sock = sock
                self.drain()
                return

    def drain(self):
        self.sock.settimeout(0.2)
        try:
            while self.sock.recv(4096):
                pass
        except socket.timeout:
            pass

    def send(self, line):
        self.sock.sendall((line + "\n").encode())
        time.sleep(0.02)
        self.drain()

    def type(self, text):
        for ch in text:
            self.send("sendkey " + KEY_NAMES.get(ch, ch))
            time.sleep(0.04)

    def click(self):
        self.send("mouse_button 1")
        self.send("mouse_button 0")

    def move(self, dx, dy):
        """Walk the relative pointer in small steps.

        A burst of large deltas outruns the polled guest, which then loses
        packets and lands short of the target.
        """
        while dx != 0 or dy != 0:
            sx = max(-60, min(60, dx))
            sy = max(-60, min(60, dy))
            self.send(f"mouse_move {sx} {sy}")
            time.sleep(0.04)
            dx -= sx
            dy -= sy

    def home(self):
        """Saturate the pointer at the top-left so guest and host agree."""
        self.move(-2040, -1536)

    def close(self):
        self.sock.close()


def start_guest(qemu, workdir, fs_path, tag):
    """Boot the image with the filesystem disk attached as the IDE slave."""
    disk = os.path.join(workdir, f"disk{tag}.img")
    shutil.copyfile(IMAGE, disk)
    log = os.path.join(workdir, f"serial{tag}.log")
    mon = os.path.join(workdir, f"monitor{tag}.sock")
    proc = subprocess.Popen(
        [qemu,
         "-drive", f"file={disk},format=raw,if=ide,index=0",
         "-drive", f"file={fs_path},format=raw,if=ide,index=1",
         "-display", "none",
         "-serial", f"file:{log}",
         "-monitor", f"unix:{mon},server,nowait",
         "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04",
         "-no-reboot",
         "-m", "128"],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    return proc, mon, log


def stop_guest(proc, monitor, tag, failures, log):
    if monitor is not None:
        monitor.close()
    if proc.poll() is None:
        proc.kill()
        proc.wait()
        failures.append(f"guest {tag} did not halt on its own")
        return None
    return proc.returncode


def main():
    qemu = shutil.which("qemu-system-x86_64")
    if not qemu:
        print("skipped: qemu-system-x86_64 is not installed")
        return SKIPPED

    failures = []

    proc = subprocess.run(["./Kernel/build.sh"], cwd=ROOT, capture_output=True,
                          text=True)
    if proc.returncode != 0:
        print("FAIL: Kernel/build.sh failed:")
        print(proc.stdout + proc.stderr)
        return HAVE_ISSUES

    with open(IMAGE, "rb") as fh:
        image = fh.read()
    if len(image) != 512 + LOAD_BYTES:
        failures.append(f"kernel.img is {len(image)} bytes, expected "
                        f"{512 + LOAD_BYTES}")
    if image[510:512] != b"\x55\xaa":
        failures.append("kernel.img has no 0xaa55 boot signature")
    flat = os.path.getsize(FLAT)
    if flat > LOAD_BYTES:
        failures.append(f"kernel.bin is {flat} B, past the {LOAD_BYTES} B "
                        f"window the MBR loads")

    workdir = tempfile.mkdtemp(prefix="tlang-desktop-")
    fs_path = os.path.join(workdir, "fs.img")
    with open(fs_path, "wb") as fh:
        fh.write(b"\x00" * FS_BYTES)
    guest = None
    monitor = None
    try:
        # ---- boot 1: desktop, apps, filesystem writes, editor save.
        guest, mon, log = start_guest(qemu, workdir, fs_path, "1")
        if wait_for_log(log, "tlang> ", 90) is None:
            failures.append(f"no prompt on the serial log: {read_log(log)!r}")
        else:
            monitor = Monitor(mon)
            if wait_for_log(log, "[fs]", 20) is None:
                failures.append(f"the filesystem never mounted: "
                                f"{read_log(log)!r}")
            if wait_for_log(log, "mouse: ready", 20) is None:
                failures.append(f"the mouse never came up: {read_log(log)!r}")

            # Close the terminal with its round close button (932, 170), then
            # bring it back from the taskbar button (24..210, 990..1018).
            monitor.home()
            monitor.move(932, 170)
            monitor.click()
            if wait_for_log(log, "[close]", 20) is None:
                failures.append(f"the close button closed nothing: "
                                f"{read_log(log)!r}")
            monitor.move(-815, 834)
            monitor.click()
            deadline = time.time() + 20
            while time.time() < deadline:
                if read_log(log).count("[terminal]") >= 2:
                    break
                time.sleep(0.1)
            else:
                failures.append(f"the taskbar opened no terminal: "
                                f"{read_log(log)!r}")

            # A file written from the shell.
            monitor.type("write notes.txt hello disk\n")
            if wait_for_log(log, "[saved] notes.txt 10", 20) is None:
                failures.append(f"`write` did not save: {read_log(log)!r}")
            monitor.type("cat notes.txt\n")
            if wait_for_log(log, "hello disk", 20) is None:
                failures.append(f"`cat` did not print the file: "
                                f"{read_log(log)!r}")

            # The editor loads it, a keystroke edits it, Ctrl+S saves it.
            monitor.type("edit notes.txt\n")
            if wait_for_log(log, "[edit] notes.txt 10", 20) is None:
                failures.append(f"`edit` did not open the file: "
                                f"{read_log(log)!r}")
            monitor.send("sendkey shift-1")
            time.sleep(0.3)
            monitor.send("sendkey ctrl-s")
            if wait_for_log(log, "[saved] notes.txt 11", 20) is None:
                failures.append(f"Ctrl+S did not save the edit: "
                                f"{read_log(log)!r}")

            # The editor owns the keyboard; the terminal button takes it back.
            monitor.home()
            monitor.move(117, 1004)
            monitor.click()
            deadline = time.time() + 20
            while time.time() < deadline:
                if read_log(log).count("[terminal]") >= 3:
                    break
                time.sleep(0.1)
            else:
                failures.append(f"the taskbar did not focus the terminal: "
                                f"{read_log(log)!r}")

            monitor.type("halt\n")
            try:
                status = guest.wait(timeout=25)
            except subprocess.TimeoutExpired:
                status = None
            if status != EXIT_HALTED:
                failures.append(f"`halt` did not stop the machine: QEMU exited "
                                f"{status}, serial {read_log(log)!r}")
            monitor.close()
            monitor = None

        # ---- boot 2: the same filesystem disk, read back.
        guest2, mon2, log2 = start_guest(qemu, workdir, fs_path, "2")
        guest = guest2
        if wait_for_log(log2, "tlang> ", 90) is None:
            failures.append(f"the second boot never reached a prompt: "
                            f"{read_log(log2)!r}")
        else:
            monitor = Monitor(mon2)
            if wait_for_log(log2, "[fs] 1 files", 20) is None:
                failures.append(f"the directory did not survive the reboot: "
                                f"{read_log(log2)!r}")
            monitor.type("cat notes.txt\n")
            if wait_for_log(log2, "hello disk!", 20) is None:
                failures.append(f"the saved file did not survive the reboot: "
                                f"{read_log(log2)!r}")
            monitor.type("halt\n")
            try:
                status = guest.wait(timeout=25)
            except subprocess.TimeoutExpired:
                status = None
            if status != EXIT_HALTED:
                failures.append(f"the second guest did not halt: QEMU exited "
                                f"{status}, serial {read_log(log2)!r}")
            monitor.close()
            monitor = None
    except (OSError, socket.timeout) as exc:
        failures.append(f"could not drive the guest: {exc}")
    finally:
        if monitor is not None:
            monitor.close()
        if guest is not None and guest.poll() is None:
            guest.kill()
            guest.wait()
        shutil.rmtree(workdir, ignore_errors=True)

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return HAVE_ISSUES
    print("the desktop boots, opens and closes windows, runs shell commands, "
          "edits a file, and finds it again after a reboot")
    return 0


if __name__ == "__main__":
    sys.exit(main())
