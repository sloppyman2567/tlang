#!/usr/bin/env python3
"""Bootstrap tcomp and verify the self-hosting fixed point.

This is the one implementation shared by Tools/selfhost.sh and
Tests/fixedpoint.py, so staging, linking and fixed-point checks cannot drift
between the developer command and CI.

    Tools/selfhost.sh              # build Build/tcomp
    Tools/selfhost.sh --verify     # also build stages 2-3 and check equality
"""

import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from Bootstrap import __version__  # noqa: E402
from Bootstrap.driver import AS_FLAGS, LINK_FLAGS  # noqa: E402
from Bootstrap.elf import strip_sections  # noqa: E402

SOURCE = os.path.join(ROOT, "tcomp.tl")
SEED = os.path.join(ROOT, "Tools", "tcomp-seed")


@dataclass
class Chain:
    stage1: str
    stage2: str
    asm2: str
    stage3: str
    asm3: str
    stage4: str
    failures: list


def run(argv, **kwargs):
    proc = subprocess.run(argv, capture_output=True, text=True, **kwargs)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise SystemExit(f"failed: {' '.join(argv)}\n{detail}")
    return proc


def check_generated():
    for script in ("gen_runtime.py", "gen_kinds.py", "gen_builtins.py",
                   "gen_version.py"):
        run([sys.executable, os.path.join(ROOT, "Tools", script), "--check"])


def compile_to_asm(compiler, asm_path):
    proc = run([compiler, SOURCE])
    with open(asm_path, "w", encoding="utf-8") as fh:
        fh.write(proc.stdout)


def link_asm(asm_path, out_path):
    obj_path = os.path.splitext(out_path)[0] + ".o"
    run(["as", *AS_FLAGS, "-o", obj_path, asm_path])
    run(["ld", *LINK_FLAGS, "-o", out_path, obj_path])
    strip_sections(out_path)
    return out_path


def build_stage1(path):
    # There is no Python compiler: the checked-in seed binary is stage 1.
    shutil.copy2(SEED, path)
    return path


def check_version(compiler):
    """The generated compiler must report the same version as the driver."""
    want = f"tcomp {__version__}"
    for arg in ("--version", "version"):
        got = run([compiler, arg]).stdout.strip()
        if got != want:
            raise SystemExit(f"{compiler} {arg}: expected {want!r}, got {got!r}")


def build_chain(workdir):
    """Build four compiler stages and return their paths and comparisons."""
    stage1 = build_stage1(os.path.join(workdir, "tcomp1"))
    check_version(stage1)
    asm1 = os.path.join(workdir, "stage1.s")
    compile_to_asm(stage1, asm1)
    stage2 = link_asm(asm1, os.path.join(workdir, "tcomp2"))
    check_version(stage2)

    asm2 = os.path.join(workdir, "stage2.s")
    compile_to_asm(stage2, asm2)
    stage3 = link_asm(asm2, os.path.join(workdir, "tcomp3"))

    asm3 = os.path.join(workdir, "stage3.s")
    compile_to_asm(stage3, asm3)
    stage4 = link_asm(asm3, os.path.join(workdir, "tcomp4"))

    failures = []
    if open(asm2, "rb").read() != open(asm3, "rb").read():
        failures.append("stage 2 and stage 3 emitted different assembly")
    if open(stage3, "rb").read() != open(stage4, "rb").read():
        failures.append("stage 2 and stage 3 binaries differ")
    return Chain(stage1, stage2, asm2, stage3, asm3, stage4, failures)


def main(argv):
    verify = "--verify" in argv
    check_generated()
    build_dir = os.path.join(ROOT, "Build")
    os.makedirs(build_dir, exist_ok=True)
    workdir = tempfile.mkdtemp(prefix="tlang-selfhost-")
    try:
        chain = build_chain(workdir)
        shutil.copy2(chain.stage1, os.path.join(build_dir, "tcomp0"))
        shutil.copy2(chain.stage2, os.path.join(build_dir, "tcomp"))
        print("stage 1: checked-in seed compiler (Tools/tcomp-seed)")
        print(f"  seed: {os.path.getsize(chain.stage1)} bytes")
        print("stage 2: tcomp.tl -> Build/tcomp (via the seed)")
        print(f"  Build/tcomp: {os.path.getsize(chain.stage2)} bytes")

        if verify:
            shutil.copy2(chain.stage3, os.path.join(build_dir, "tcomp2"))
            shutil.copy2(chain.stage4, os.path.join(build_dir, "tcomp3"))
            shutil.copy2(chain.asm2, os.path.join(build_dir, "tcomp2.s"))
            shutil.copy2(chain.asm3, os.path.join(build_dir, "tcomp3.s"))
            if chain.failures:
                for failure in chain.failures:
                    print(f"FAIL: {failure}", file=sys.stderr)
                return 1
            print("stage 3: tcomp.tl -> Build/tcomp2 (via stage 2)")
            print("stage 4: tcomp.tl -> Build/tcomp3 (via stage 3)")
            print(f"fixed point: stage 2 and stage 3 are identical "
                  f"({os.path.getsize(chain.stage3)} bytes)")
        return 0
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
