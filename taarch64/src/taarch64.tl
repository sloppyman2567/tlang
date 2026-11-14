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

# Linux starts a process with argc/argv/envp/auxv on the stack. Freestanding
# test programs do not read them, but a program that does should see a valid
# empty vector rather than garbage.
fn setup_stack() {
  SP = STACK_TOP - 64
  let i = 0
  while i < 64 {
    wr64(SP + i, 0)
    i = i + 8
  }
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
  let entry = elf_load(argv(1))
  setup_stack()
  run(entry)
}
