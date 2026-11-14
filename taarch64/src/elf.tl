# elf.tl -- loader for static AArch64 executables.
#
# Only ET_EXEC images with no interpreter are accepted. That is what
# `aarch64-linux-gnu-gcc -static -nostdlib` produces: a small file whose
# PT_LOAD segments already name the addresses they want, so loading is a copy
# and a memset. Dynamic binaries are rejected with an explanation rather than
# a partial load, because running them would require a dynamic linker, TLS and
# a much larger syscall surface.

let IMG_END = 0

fn le16(f: str, o: int) -> int {
  return f[o] | (f[o + 1] << 8)
}

fn le32(f: str, o: int) -> int {
  return f[o] | (f[o + 1] << 8) | (f[o + 2] << 16) | (f[o + 3] << 24)
}

fn le64(f: str, o: int) -> int {
  let lo = le32(f, o)
  let hi = le32(f, o + 4)
  return lo | (hi << 32)
}

fn align16(v: int) -> int {
  return (v + 15) & ~15
}

fn elf_load(path: str) -> int {
  let n = file_size(path)
  if n < 64 { die("not an ELF file: " + path) }
  let f = read_file(path)

  if f[0] != 0x7F || f[1] != 69 || f[2] != 76 || f[3] != 70 {
    die("not an ELF file: " + path)
  }
  if f[4] != 2 { die("not a 64-bit ELF file: " + path) }
  if f[5] != 1 { die("not a little-endian ELF file: " + path) }
  if le16(f, 18) != 183 { die("not an AArch64 executable (e_machine " + le16(f, 18) + ")") }
  let etype = le16(f, 16)
  if etype == 3 {
    die("dynamic executable: link with -static -nostdlib (or -static-pie is not supported)")
  }
  if etype != 2 { die("unsupported ELF type " + etype + "; expected a static ET_EXEC") }

  let entry = le64(f, 24)
  let phoff = le64(f, 32)
  let phentsize = le16(f, 54)
  let phnum = le16(f, 56)
  if phnum == 0 { die("ELF file has no program headers") }
  if phentsize < 56 { die("unexpected program header size " + phentsize) }
  if phoff + phnum * phentsize > n { die("program headers outside the file") }

  let i = 0
  while i < phnum {
    let p = phoff + i * phentsize
    let typ = le32(f, p)
    if typ == 3 {
      die("PT_INTERP found: this is a dynamic executable, not a static one")
    }
    if typ == 1 {
      let off = le64(f, p + 8)
      let vaddr = le64(f, p + 16)
      let filesz = le64(f, p + 32)
      let memsz = le64(f, p + 40)
      if filesz > memsz { die("PT_LOAD has p_filesz > p_memsz") }
      if off + filesz > n { die("PT_LOAD data outside the file") }
      if mem_ok(vaddr, memsz) == 0 {
        die("PT_LOAD segment at 0x" + hex(vaddr) + " does not fit in guest memory")
      }
      let k = 0
      while k < filesz {
        MEM[vaddr - BASE + k] = f[off + k]
        k = k + 1
      }
      # Fresh buffers are already zero; zeroing again keeps a re-load honest.
      while k < memsz {
        MEM[vaddr - BASE + k] = 0
        k = k + 1
      }
      if vaddr + memsz > IMG_END { IMG_END = vaddr + memsz }
    }
    i = i + 1
  }

  if IMG_END == 0 { die("ELF file has no loadable segments") }
  if entry < BASE || entry >= MEM_TOP {
    die("entry point 0x" + hex(entry) + " is outside guest memory")
  }

  BRK = align16(IMG_END)
  if BRK < BASE { BRK = BASE }
  if BRK > HEAP_LIMIT { die("image is too large for the 16 MiB guest address space") }
  return entry
}
