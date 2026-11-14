#!/usr/bin/env python3
"""Benchmark tlang float arithmetic against tlang integers and C.

The workload is a dependent recurrence, so it cannot be vectorized:

    x = x * a + b

Both languages execute the same number of arithmetic operations. Each binary is
built ahead of time; only execution time is measured. Runs are interleaved in
rounds to reduce CPU-frequency drift, then the median of each series is shown.

Usage:
    python3 Benchmarks/float_bench.py
"""

import os
import platform
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from Bootstrap.elf import strip_sections  # noqa: E402

TCOMP = os.path.join(ROOT, "tcomp")
N = 50_000_000
ROUNDS = 7
LDFLAGS = ["-s", "-z", "noseparate-code", "--build-id=none"]

TL_FLOAT = f"""\
let N = {N}

fn main() {{
  let x = 1.0
  let a = 1.0000001
  let b = 0.0000001
  let i = 0
  while i < N {{
    x = x * a + b
    i = i + 1
  }}
  print_float(x)
  print("\\n")
}}
"""

TL_INT = f"""\
let N = {N}

fn main() {{
  let x = 1
  let a = 1000001
  let b = 7
  let i = 0
  while i < N {{
    x = x * a + b
    i = i + 1
  }}
  print_int(x)
  print("\\n")
}}
"""

TL_EMPTY = f"""\
let N = {N}

fn main() {{
  let i = 0
  while i < N {{
    i = i + 1
  }}
  print_int(i)
  print("\\n")
}}
"""

C_FLOAT = f"""\
#include <stdint.h>
#include <stdio.h>
int main(void) {{
  double x = 1.0, a = 1.0000001, b = 0.0000001;
  for (uint64_t i = 0; i < {N}ULL; i++) x = x * a + b;
  printf("%.6f\\n", x);
  return 0;
}}
"""

C_INT = f"""\
#include <stdint.h>
#include <stdio.h>
int main(void) {{
  uint64_t x = 1, a = 1000001, b = 7;
  for (uint64_t i = 0; i < {N}ULL; i++) x = x * a + b;
  printf("%llu\\n", (unsigned long long)x);
  return 0;
}}
"""


def build_tlang_stage0(work, name, source):
    src = os.path.join(work, name + ".tl")
    exe = os.path.join(work, name + "-stage0")
    with open(src, "w") as fh:
        fh.write(source)
    subprocess.run([sys.executable, TCOMP, "build", src, "-o", exe],
                   check=True, capture_output=True)
    return exe


def build_stage1_compiler(work):
    exe = os.path.join(work, "tcomp1")
    subprocess.run([sys.executable, TCOMP, "build",
                    os.path.join(ROOT, "tcomp.tl"), "-o", exe],
                   check=True, capture_output=True)
    return exe


def build_tlang_stage1(work, compiler, name, source):
    src = os.path.join(work, name + ".tl")
    asm = os.path.join(work, name + "-stage1.s")
    obj = os.path.join(work, name + "-stage1.o")
    exe = os.path.join(work, name + "-stage1")
    with open(src, "w") as fh:
        fh.write(source)
    proc = subprocess.run([compiler, src], check=True, capture_output=True)
    with open(asm, "wb") as fh:
        fh.write(proc.stdout)
    subprocess.run(["as", "--64", "-mx86-used-note=no", "-o", obj, asm], check=True)
    subprocess.run(["ld", *LDFLAGS, "-o", exe, obj], check=True)
    strip_sections(exe)
    return exe


def build_c(work, name, source):
    src = os.path.join(work, name + ".c")
    exe = os.path.join(work, name + "-c")
    with open(src, "w") as fh:
        fh.write(source)
    subprocess.run(["gcc", "-O2", "-fno-tree-vectorize", "-o", exe, src],
                   check=True, capture_output=True)
    return exe


def timed(exe):
    start = time.perf_counter_ns()
    subprocess.run([exe], stdout=subprocess.DEVNULL, check=True)
    return (time.perf_counter_ns() - start) / 1e9


def main():
    if shutil.which("gcc") is None:
        print("gcc is required for the comparison build", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="tlang-bench-") as work:
        stage1 = build_stage1_compiler(work)
        cases = {
            "tlang float (stage 0)": build_tlang_stage0(
                work, "float", TL_FLOAT),
            "tlang float (self-hosted)": build_tlang_stage1(
                work, stage1, "float", TL_FLOAT),
            "C double -O2": build_c(work, "float", C_FLOAT),
            "tlang int (stage 0)": build_tlang_stage0(
                work, "int", TL_INT),
            "tlang int (self-hosted)": build_tlang_stage1(
                work, stage1, "int", TL_INT),
            "C uint64 -O2": build_c(work, "int", C_INT),
            "tlang loop only (stage 0)": build_tlang_stage0(
                work, "empty", TL_EMPTY),
        }

        # Warm every binary once, then interleave rounds.
        for exe in cases.values():
            timed(exe)
        samples = {name: [] for name in cases}
        for _ in range(ROUNDS):
            for name, exe in cases.items():
                samples[name].append(timed(exe))

        print(f"workload: x = x * a + b, {N:,} iterations")
        print(f"CPU: {platform.processor() or platform.machine()}, "
              f"{os.cpu_count()} logical CPUs")
        print(f"load: {os.getloadavg()[0]:.2f}, runs: {ROUNDS} interleaved rounds")
        print()
        print(f"{'case':30} {'median':>10} {'min':>10} {'ns/iter':>10} {'Mops/s':>9}")
        for name, values in samples.items():
            median = statistics.median(values)
            low = min(values)
            ns_iter = median * 1e9 / N
            ops = "" if "loop only" in name else f"{2 * N / median / 1e6:9.2f}"
            print(f"{name:30} {median:10.3f}s {low:10.3f}s "
                  f"{ns_iter:10.2f} {ops:>9}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
