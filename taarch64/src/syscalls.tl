# syscalls.tl -- Linux AArch64 syscalls, translated to host facilities.
#
# The guest ABI is the real one: x8 holds the number, x0..x5 the arguments,
# x0 the result. Only the calls a freestanding program needs are implemented;
# anything else stops with a diagnostic naming the number, because silently
# returning ENOSYS turns a missing feature into a confusing guest bug.
#
# Supported:
#   57 close   63 read   64 write   93 exit   94 exit_group
#   96 set_tid_address   99 set_robust_list
#   113 clock_gettime   114 gettimeofday
#   172 getpid  173 getppid  174 getuid  175 geteuid  176 getgid  177 getegid
#   178 gettid  214 brk  215 munmap  222 mmap  226 mprotect  233 madvise
#   278 getrandom
#
# Deliberately unsupported: file-backed mmap, threads (clone/futex), signals,
# dynamic linking, sockets and ioctl. See README.md for the reasoning.

let IOBUF = newbuf(65536)

fn io_write(fd: int, addr: int, n: int) -> int {
  if mem_ok(addr, n) == 0 { mem_fail("write buffer", addr) }
  let done = 0
  while done < n {
    let chunk = n - done
    if chunk > 65536 { chunk = 65536 }
    let i = 0
    while i < chunk {
      IOBUF[i] = MEM[addr - BASE + done + i]
      i = i + 1
    }
    let w = fd_write(fd, IOBUF, chunk)
    if w <= 0 { return done }
    done = done + w
  }
  return done
}

fn io_read(fd: int, addr: int, n: int) -> int {
  if mem_ok(addr, n) == 0 { mem_fail("read buffer", addr) }
  let done = 0
  while done < n {
    let chunk = n - done
    if chunk > 65536 { chunk = 65536 }
    let got = fd_read(fd, IOBUF, chunk)
    if got <= 0 { return done }
    let i = 0
    while i < got {
      MEM[addr - BASE + done + i] = IOBUF[i]
      i = i + 1
    }
    done = done + got
    if got < chunk { return done }
  }
  return done
}

fn sys_brk() {
  let want = X[0]
  if want == 0 {
    X[0] = BRK
    return
  }
  if want < IMG_END || want > HEAP_LIMIT {
    X[0] = BRK
    return
  }
  BRK = want
  X[0] = want
}

fn sys_mmap() {
  let len = X[1]
  if X[4] != -1 { die("file-backed mmap is not supported (only anonymous mappings)") }
  if len <= 0 {
    X[0] = -1
    return
  }
  let start = (BRK + 4095) & ~4095
  let end = start + ((len + 4095) & ~4095)
  if end > HEAP_LIMIT {
    X[0] = -1
    return
  }
  BRK = end
  X[0] = start
}

fn zero_at(addr: int, n: int) {
  if mem_ok(addr, n) == 0 { mem_fail("syscall result buffer", addr) }
  let i = 0
  while i < n {
    MEM[addr - BASE + i] = 0
    i = i + 1
  }
}

fn do_syscall() {
  let n = X[8]
  TICKS = TICKS + 1

  if n == 64 {                       # write
    X[0] = io_write(X[0], X[1], X[2])
    return
  }
  if n == 63 {                       # read
    X[0] = io_read(X[0], X[1], X[2])
    return
  }
  if n == 93 || n == 94 {            # exit, exit_group
    exit(X[0] & 255)
  }
  if n == 214 {                      # brk
    sys_brk()
    return
  }
  if n == 222 {                      # mmap (anonymous)
    sys_mmap()
    return
  }
  if n == 215 || n == 226 || n == 233 {   # munmap, mprotect, madvise
    X[0] = 0
    return
  }
  if n == 57 || n == 62 {            # close, lseek
    X[0] = 0
    return
  }
  if n == 96 || n == 99 {            # set_tid_address, set_robust_list
    X[0] = 0
    return
  }
  if n == 113 || n == 114 {          # clock_gettime, gettimeofday
    zero_at(X[1], 16)
    X[0] = 0
    return
  }
  if n == 278 {                      # getrandom
    zero_at(X[0], X[1])
    X[0] = X[1]
    return
  }
  if n == 172 || n == 178 {          # getpid, gettid
    X[0] = 1
    return
  }
  if n == 173 || n == 174 || n == 175 || n == 176 || n == 177 {
    X[0] = 0
    return
  }
  if n == 293 {                      # rseq: let the caller see ENOSYS
    X[0] = -38
    return
  }
  die("unsupported syscall " + n + " at pc 0x" + hex(AT))
}
