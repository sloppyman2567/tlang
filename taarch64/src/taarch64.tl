# taarch64 -- a user-mode AArch64 interpreter for static Linux binaries.
#
#   taarch64 FILE.a64
#
# The interpreter is an ordinary tlang program: it owns a flat guest address
# space (see machine.tl), loads an ET_EXEC image into it (elf.tl), and runs the
# instruction stream (exec.tl), translating Linux syscalls onto the host
# (syscalls.tl). It does not depend on the tlang compiler's internals.

import "machine.tl"
import "elf.tl"
import "syscalls.tl"
import "exec.tl"

# Linux starts a process with argc, argv, envp and an auxiliary vector on the
# stack, and libc reads all of it: musl finds the program headers through
# AT_PHDR/AT_PHENT/AT_PHNUM, which is how it locates the TLS template, and
# seeds its stack canary from AT_RANDOM. The strings sit just below the
# vectors and the stack grows down from them, so the program never overwrites
# its own argument area.
let AUX_PAIRS = 17

fn aux_pair(p: int, typ: int, val: int) -> int {
  wr64(p, typ)
  wr64(p + 8, val)
  return p + 16
}

fn setup_stack(path: str, entry: int) {
  let top = STACK_TOP

  top = top - 16
  entropy_fill(top, 16)
  let rnd = top

  let n = len(path)
  let exe = (top - (n + 1)) & ~15
  let i = 0
  while i < n {
    wr8(exe + i, path[i])
    i = i + 1
  }
  wr8(exe + n, 0)

  # argc, argv[0], the argv terminator, the empty envp, then the auxv pairs.
  SP = (exe - (32 + AUX_PAIRS * 16)) & ~15
  wr64(SP, 1)               # argc
  wr64(SP + 8, exe)         # argv[0]
  wr64(SP + 16, 0)          # argv terminator
  wr64(SP + 24, 0)          # envp: empty, and its NULL is where auxv starts

  let p = SP + 32
  p = aux_pair(p, 3, IMG_PHDR)     # AT_PHDR
  p = aux_pair(p, 4, 56)           # AT_PHENT
  p = aux_pair(p, 5, IMG_PHNUM)    # AT_PHNUM
  p = aux_pair(p, 6, 4096)         # AT_PAGESZ
  p = aux_pair(p, 7, 0)            # AT_BASE: no interpreter
  p = aux_pair(p, 8, 0)            # AT_FLAGS
  p = aux_pair(p, 9, entry)        # AT_ENTRY
  p = aux_pair(p, 11, 0)           # AT_UID
  p = aux_pair(p, 12, 0)           # AT_EUID
  p = aux_pair(p, 13, 0)           # AT_GID
  p = aux_pair(p, 14, 0)           # AT_EGID
  p = aux_pair(p, 16, 0)           # AT_HWCAP: no optional instructions
  p = aux_pair(p, 17, 100)         # AT_CLKTCK
  p = aux_pair(p, 23, 0)           # AT_SECURE
  p = aux_pair(p, 25, rnd)         # AT_RANDOM
  p = aux_pair(p, 31, exe)         # AT_EXECFN
  p = aux_pair(p, 0, 0)            # AT_NULL
}

fn main() {
  if argc() < 2 {
    print_err("usage: taarch64 FILE.a64\n")
    exit(2)
  }
  if argc() > 2 {
    print_err("taarch64: guest arguments are not supported yet\n")
    exit(2)
  }
  let path = argv(1)
  let entry = elf_load(path)
  setup_stack(path, entry)
  run(entry)
}
