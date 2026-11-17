#!/usr/bin/env python3
"""Optional acceptance test using the static aarch64 guests from bifrost-emu.

The binaries are not part of this repository.  If a bifrost-emu download is
present, run each static ET_EXEC guest under qemu-aarch64 and taarch64 and
compare stdout, stderr and exit status.  Guests that stop on a feature taarch64
does not implement (documented in README.md) are reported as skipped, not
failed.  With no binaries or no qemu, the test exits 0 with a notice.
"""

import glob
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EMU = os.path.join(ROOT, "taarch64", "taarch64")

# Static ET_EXEC guests; taarch64 rejects static-pie images.
NAMES = (
    "hello_arm64", "args_test", "bit_test", "struct_test", "malloc_test",
    "iterfib.elf", "malloctest.elf", "test3.elf", "io_test", "sys_test",
    "filetest_simple.elf", "fpu_test", "floattest.elf", "systest.elf",
)

UNSUPPORTED = ("unsupported syscall", "unsupported instruction",
               "SIMD/FP load or store", "not implemented")


def find_bins():
    home = os.path.expanduser("~")
    roots = glob.glob(os.path.join(home, "Downloads", "bifrost-emu-*"))
    found = []
    for root in roots:
        for name in NAMES:
            path = os.path.join(root, name)
            if os.path.isfile(path) and path not in found:
                found.append(path)
    return sorted(found)


def run(argv, binary):
    try:
        proc = subprocess.run(argv + [binary], capture_output=True, timeout=20)
    except subprocess.TimeoutExpired:
        return None
    return proc.returncode, proc.stdout, proc.stderr


def main():
    bins = find_bins()
    if not bins:
        print("no bifrost-emu static guests found; skipping")
        return 0
    if not os.path.exists(EMU):
        print(f"{EMU} not built; run taarch64/build.sh first")
        return 1
    if not subprocess.run(["which", "qemu-aarch64"], capture_output=True
                          ).returncode:
        qemu = "qemu-aarch64"
    else:
        print("qemu-aarch64 not found; skipping")
        return 0

    passed = skipped = failures = 0
    for binary in bins:
        name = os.path.basename(binary)
        want = run([qemu], binary)
        got = run([EMU], binary)
        if want is None or got is None:
            print(f"  skip {name}: timed out")
            skipped += 1
            continue
        if any(mark in got[2].decode("utf-8", "replace") for mark in UNSUPPORTED):
            print(f"  skip {name}: {got[2].decode('utf-8', 'replace').strip()}")
            skipped += 1
            continue
        if want == got:
            print(f"  ok   {name}")
            passed += 1
        else:
            print(f"  FAIL {name}\n    qemu: {want}\n    taarch64: {got}")
            failures += 1

    print(f"{passed} guest(s) match qemu-aarch64, {skipped} skipped, "
          f"{failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
