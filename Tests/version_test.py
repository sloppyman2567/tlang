#!/usr/bin/env python3
"""Check the tlang/tcomp version contract.

Stage 0 reads Bootstrap.__version__; the self-hosted compiler reads the
TLANG_VERSION constant in tcomp.tl.  They must agree, and both CLI spellings
must report the same value.  Tools/selfhost.py checks the generated stages too.

The expected version is derived from Bootstrap.__version__, so a release bump
only edits Bootstrap/__init__.py and tcomp.tl, not this file.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from Bootstrap import __version__  # noqa: E402

TCOMP = os.path.join(ROOT, "tcomp")
SOURCE = os.path.join(ROOT, "tcomp.tl")
WANT = f"tcomp {__version__}"


def main():
    failures = []
    if re.fullmatch(r"\d+\.\d+\.\d+", __version__) is None:
        failures.append(
            f"Bootstrap.__version__ is {__version__!r}, expected MAJOR.MINOR.PATCH")

    source = open(SOURCE, encoding="utf-8").read()
    match = re.search(r'let TLANG_VERSION = "([^"]+)"', source)
    if match is None:
        failures.append("tcomp.tl has no TLANG_VERSION constant")
    elif match.group(1) != __version__:
        failures.append(
            f"tcomp.tl TLANG_VERSION is {match.group(1)!r}, "
            f"expected {__version__!r}")

    for arg in ("--version", "version"):
        proc = subprocess.run([sys.executable, TCOMP, arg],
                              capture_output=True, text=True)
        if proc.returncode != 0:
            failures.append(f"tcomp {arg} exited {proc.returncode}")
        elif proc.stdout.strip() != WANT:
            failures.append(
                f"tcomp {arg} printed {proc.stdout.strip()!r}, expected {WANT!r}")

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print(f"tcomp/tlang version contract: {WANT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
