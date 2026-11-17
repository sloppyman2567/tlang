#!/usr/bin/env python3
"""Contract test for the single-source builtin metadata.

Checks that stage 0 and the generated tlang mapping are both derived from
Bootstrap/builtin_spec.py, that IDs are unique and contiguous, and that every
builtin points at a real runtime symbol.
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from Bootstrap.builtin_spec import (  # noqa: E402
    BUILTIN_SPECS, GENERATED_BUILTINS, GENERATED_DEPS, HOSTED_ONLY, KERNEL_ONLY,
)
from Bootstrap.builtins_gen import (  # noqa: E402
    BUILTIN_ARGS, BUILTIN_IDS, BUILTIN_MODES, BUILTIN_NAMES, BUILTINS,
)
from Bootstrap.runtime import RUNTIME_SYMBOLS  # noqa: E402


def main():
    failures = []
    specs = {name: (ident, arity, result, symbol, args, stage0)
             for name, ident, arity, result, symbol, args, stage0
             in BUILTIN_SPECS}

    ids = [ident for _name, ident, *_rest in BUILTIN_SPECS]
    names = [name for name, *_rest in BUILTIN_SPECS]
    if len(set(names)) != len(names):
        failures.append("duplicate builtin names")
    if len(set(ids)) != len(ids):
        failures.append("duplicate builtin IDs")
    if sorted(ids) != list(range(1, len(ids) + 1)):
        failures.append("builtin IDs are not contiguous from 1")

    if BUILTIN_IDS != {name: ident for name, ident, *_rest in BUILTIN_SPECS}:
        failures.append("Bootstrap/builtins_gen.py has stale BUILTIN_IDS")
    if BUILTIN_NAMES != {ident: name for name, ident, *_rest in BUILTIN_SPECS}:
        failures.append("Bootstrap/builtins_gen.py has stale BUILTIN_NAMES")

    expected_args = {name: args for name, _ident, _arity, _result, _symbol,
                     args, _stage0 in BUILTIN_SPECS if args is not None}
    if BUILTIN_ARGS != expected_args:
        failures.append("Bootstrap/builtins_gen.py has stale BUILTIN_ARGS")

    expected_modes = {}
    for name, *_rest in BUILTIN_SPECS:
        if name in KERNEL_ONLY:
            expected_modes[name] = "kernel"
        elif name in HOSTED_ONLY:
            expected_modes[name] = "hosted"
    if BUILTIN_MODES != expected_modes:
        failures.append("Bootstrap/builtins_gen.py has stale BUILTIN_MODES")
    if KERNEL_ONLY & HOSTED_ONLY:
        failures.append("a builtin is both kernel-only and hosted-only")
    if not KERNEL_ONLY <= set(names) or not HOSTED_ONLY <= set(names):
        failures.append("a mode set names a builtin that does not exist")

    expected_builtins = {
        name: (arity, result, symbol)
        for name, _ident, arity, result, symbol, _args, stage0
        in BUILTIN_SPECS if stage0
    }
    if BUILTINS != expected_builtins:
        failures.append("Bootstrap/builtins_gen.py has stale BUILTINS")

    for name, (_ident, arity, _result, symbol, args, _stage0) in specs.items():
        if name in KERNEL_ONLY:
            if not symbol.startswith("__k_"):
                failures.append(f"{name}: machine builtins call __k_<name>")
        elif symbol not in RUNTIME_SYMBOLS:
            failures.append(f"{name}: runtime symbol {symbol} is missing")
        if args is not None and len(args) != arity:
            failures.append(f"{name}: argument metadata has the wrong arity")

    tcomp = open(os.path.join(ROOT, "tcomp.tl"), encoding="utf-8").read()
    # A mistyped U_ flag stem in GENERATED_DEPS silently emits an unused flag
    # and leaves the runtime helper out, which only shows up at link time.
    # Check both spellings here instead.
    for name, deps in GENERATED_DEPS.items():
        if name not in GENERATED_BUILTINS:
            failures.append(f"{name}: dependency listed for a non-generated builtin")
        for dep in deps:
            if dep.startswith("GEN_"):
                target = dep[4:].lower()
                if target not in GENERATED_BUILTINS:
                    failures.append(
                        f"{name}: {dep} names no generated builtin")
            elif (dep != dep.upper()
                  or f"let U_{dep} = 0" not in tcomp):
                failures.append(f"{name}: unknown usage flag U_{dep}")
    if 'import "Runtime/builtins_gen.tl"' not in tcomp:
        failures.append("tcomp.tl does not import the generated builtin mapping")
    if "fn builtin_kind(n: str) -> int {" in tcomp:
        failures.append("tcomp.tl still has a hand-maintained builtin_kind")

    generated = open(os.path.join(ROOT, "Runtime", "builtins_gen.tl"),
                     encoding="utf-8").read()
    if "fn builtin_kernel(n: str) -> int {" not in generated:
        failures.append("the tlang mapping has no kernel mode table")
    if "builtin_kernel(name)" not in tcomp:
        failures.append("tcomp.tl does not use the generated mode table")
    for name, ident, *_rest in BUILTIN_SPECS:
        if f'str_eq(n, "{name}")' not in generated:
            failures.append(f"tlang mapping is missing {name}")
        if f"return {ident}" not in generated:
            failures.append(f"tlang mapping is missing ID {ident}")

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print(f"{len(BUILTIN_SPECS)} builtins share one generated contract")
    return 0


if __name__ == "__main__":
    sys.exit(main())
