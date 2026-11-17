# syscalls.tl -- Linux AArch64 syscalls, translated to host facilities.
#
# The guest ABI is the real one: x8 holds the number, x0..x5 the arguments,
# x0 the result. A failure is a negated errno, exactly as the kernel reports
# it, so libc's wrappers take their normal error path instead of seeing a
# success that did nothing.
#
# Supported:
#   29 ioctl (-ENOTTY: the guest never sees a terminal)
#   57 close   63 read   64 write   66 writev   93 exit   94 exit_group
#   96 set_tid_address   99 set_robust_list
#   113 clock_gettime   114 gettimeofday
#   172 getpid  173 getppid  174 getuid  175 geteuid  176 getgid  177 getegid
#   178 gettid  214 brk  215 munmap  222 mmap  226 mprotect  233 madvise
#   278 getrandom
#
# Anything else stops with a diagnostic naming the number. Deliberately
# unsupported: openat and the rest of the file API, file-backed mmap, threads
# (clone/futex), signals, dynamic linking and sockets. See README.md.

let IOBUF = newbuf(65536)

# errno values these calls can return.
let EBADF = 9
let ENOMEM = 12
let EFAULT = 14
let EINVAL = 22
let ENOTTY = 25
let ENOSYS = 38

# One virtual process: pid, tid, and the clear_child_tid pointer.
let VIRTUAL_TID = 1
let TID_ADDR = 0

# Guest descriptors. There is no openat, so only the three inherited stdio
# descriptors can be open: the table only has to remember closings.
let FD_CLOSED = newbuf(4)

fn fd_bad(fd: int) -> int {
  if fd < 0 { return 1 }
  if fd > 2 { return 1 }
  return FD_CLOSED[fd]
}

# ------------------------------------------------------------ host transfer

# Host descriptors are pipes, files or terminals: fd_write may take only part
# of a buffer, so keep offering the rest until it is all gone or an error is
# reported.
fn io_write(fd: int, addr: int, n: int) -> int {
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
    if w < 0 {
      if done > 0 { return done }
      return w
    }
    if w == 0 { return done }
    done = done + w
  }
  return done
}

# A read returns what is available, like the kernel: it does not keep waiting
# to fill the buffer, which matters for a terminal or a pipe.
fn io_read(fd: int, addr: int, n: int) -> int {
  let chunk = n
  if chunk > 65536 { chunk = 65536 }
  let got = fd_read(fd, IOBUF, chunk)
  if got <= 0 { return got }
  let i = 0
  while i < got {
    MEM[addr - BASE + i] = IOBUF[i]
    i = i + 1
  }
  return got
}

# ---------------------------------------------------------------- simple calls

fn sys_write() -> int {
  if fd_bad(X[0]) == 1 { return -EBADF }
  if X[2] < 0 { return -EINVAL }
  if mem_ok(X[1], X[2]) == 0 { return -EFAULT }
  return io_write(X[0], X[1], X[2])
}

fn sys_read() -> int {
  if fd_bad(X[0]) == 1 { return -EBADF }
  if X[2] < 0 { return -EINVAL }
  if mem_ok(X[1], X[2]) == 0 { return -EFAULT }
  return io_read(X[0], X[1], X[2])
}

# libc writes through writev: __stdio_write hands over the buffered block and
# the rest of the line as two iovecs.
fn sys_writev() -> int {
  let fd = X[0]
  let iov = X[1]
  let cnt = X[2]
  if fd_bad(fd) == 1 { return -EBADF }
  if cnt < 0 || cnt > 1024 { return -EINVAL }
  if mem_ok(iov, cnt * 16) == 0 { return -EFAULT }
  let total = 0
  let i = 0
  while i < cnt {
    let base = rd64(iov + i * 16)
    let len = rd64(iov + i * 16 + 8)
    if len < 0 { return -EINVAL }
    if mem_ok(base, len) == 0 { return -EFAULT }
    let w = io_write(fd, base, len)
    if w < 0 {
      if total > 0 { return total }
      return w
    }
    total = total + w
    if w < len { return total }
    i = i + 1
  }
  return total
}

# musl's stdio reads through readv as well as writes through writev. One host
# read fills the caller's iovecs in order, which is what a pipe read gives.
fn sys_readv() -> int {
  let fd = X[0]
  let iov = X[1]
  let cnt = X[2]
  if fd_bad(fd) == 1 { return -EBADF }
  if cnt < 0 || cnt > 1024 { return -EINVAL }
  if mem_ok(iov, cnt * 16) == 0 { return -EFAULT }
  let total = 0
  let i = 0
  while i < cnt {
    let len = rd64(iov + i * 16 + 8)
    if len < 0 { return -EINVAL }
    if mem_ok(rd64(iov + i * 16), len) == 0 { return -EFAULT }
    total = total + len
    i = i + 1
  }
  if total == 0 { return 0 }
  if total > 65536 { total = 65536 }
  let got = fd_read(fd, IOBUF, total)
  if got <= 0 { return got }
  let done = 0
  i = 0
  while i < cnt && done < got {
    let base = rd64(iov + i * 16)
    let len = rd64(iov + i * 16 + 8)
    let j = 0
    while j < len && done < got {
      MEM[base - BASE + j] = IOBUF[done]
      done = done + 1
      j = j + 1
    }
    i = i + 1
  }
  return done
}

fn sys_close() -> int {
  let fd = X[0]
  if fd_bad(fd) == 1 { return -EBADF }
  # Only the guest's view is closed; the host descriptor belongs to the
  # interpreter and stays open for the next program it might run.
  FD_CLOSED[fd] = 1
  return 0
}

# libc probes stdout with TIOCGWINSZ to decide whether to line-buffer. The
# guest is never attached to a terminal, so report "not a tty" and let stdio
# use full buffering, which is what it would do behind a pipe.
fn sys_ioctl() -> int {
  if fd_bad(X[0]) == 1 { return -EBADF }
  return -ENOTTY
}

# ------------------------------------------------------------------- memory

fn sys_brk() -> int {
  let want = X[0]
  if want == 0 { return BRK }
  if want < IMG_END { return BRK }     # the break cannot move into the image
  if want > HEAP_LIMIT { return BRK }  # out of room: report the old break
  BRK = want
  return want
}

# Anonymous mappings are served from the same bump pointer as the break, so a
# mapping is always fresh zeroed memory that no earlier request handed out.
# File-backed mappings would need a descriptor and a page cache: refuse loudly.
fn sys_mmap() -> int {
  let addr = X[0]
  let len = X[1]
  if X[4] != -1 { die("file-backed mmap is not supported (only anonymous mappings)") }
  if X[5] != 0 { return -EINVAL }      # anonymous mappings start at offset 0
  if len <= 0 { return -EINVAL }
  if len > MEM_BYTES { return -ENOMEM }
  # MAP_FIXED is how libc reserves the page after the break before mapping it:
  # the range is checked, and the break is kept above it so a later bump
  # allocation cannot hand the same bytes out twice. Protection is not
  # enforced anywhere in this address space, so PROT_NONE reserves nothing.
  if (X[3] & 16) != 0 {
    if (addr & 4095) != 0 { return -EINVAL }
    if mem_ok(addr, len) == 0 { return -ENOMEM }
    if addr < IMG_END { return -ENOMEM }
    if addr + len > HEAP_LIMIT { return -ENOMEM }
    if addr + len > BRK { BRK = addr + len }
    return addr
  }
  let start = (BRK + 4095) & ~4095
  let end = start + ((len + 4095) & ~4095)
  if end > HEAP_LIMIT { return -ENOMEM }
  BRK = end
  return start
}

# Unmapped memory is zeroed and never handed out again, so the guest cannot
# observe a page it released, even though the space is not reclaimed.
fn sys_munmap() -> int {
  let addr = X[0]
  let len = X[1]
  if len <= 0 { return -EINVAL }
  if (addr & 4095) != 0 { return -EINVAL }
  if mem_ok(addr, len) == 0 { return -EINVAL }
  zero_mem(addr, len)
  return 0
}

# One flat address space with no page tables: permissions are not enforced,
# but the range still has to be one the guest owns.
fn sys_mprotect() -> int {
  if (X[1] <= 0) { return -EINVAL }
  if (X[0] & 4095) != 0 { return -EINVAL }
  if mem_ok(X[0], X[1]) == 0 { return -ENOMEM }
  return 0
}

fn sys_madvise() -> int {
  let addr = X[0]
  let len = X[1]
  if len < 0 { return -EINVAL }
  if mem_ok(addr, len) == 0 { return -EINVAL }
  if X[2] == 4 { zero_mem(addr, len) }   # MADV_DONTNEED: drop the contents
  return 0
}

# --------------------------------------------------------------------- time

# Host time comes from /proc: uptime counts from boot, and /proc/stat's btime
# is the wall clock at boot. Both reads allocate a scratch megabyte because
# the kernel reports size 0 for a proc file, so the arena is rewound after
# each one and the result is cached against the instruction counter.
let BOOT_SEC = -1
let CLOCK_NS = 0
let CLOCK_AT = -1000000

fn read_uptime_ns() -> int {
  let mark = arena_mark()
  let s = read_file("/proc/uptime")
  let n = len(s)
  let i = 0
  let sec = 0
  while i < n && s[i] >= 48 && s[i] <= 57 {
    sec = sec * 10 + (s[i] - 48)
    i = i + 1
  }
  let frac = 0
  if i < n && s[i] == 46 {
    i = i + 1
    let scale = 100000000
    while i < n && s[i] >= 48 && s[i] <= 57 {
      frac = frac + (s[i] - 48) * scale
      scale = scale / 10
      i = i + 1
    }
  }
  arena_release(mark)
  return sec * 1000000000 + frac
}

fn boot_seconds() -> int {
  if BOOT_SEC >= 0 { return BOOT_SEC }
  let mark = arena_mark()
  let s = read_file("/proc/stat")
  let n = len(s)
  let at = 0
  let i = 0
  while i + 6 <= n && at == 0 {
    # "btime " appears once, at the start of its own line.
    if s[i] == 98 && s[i + 1] == 116 && s[i + 2] == 105 && s[i + 3] == 109 {
      if s[i + 4] == 101 && s[i + 5] == 32 { at = i + 6 }
    }
    i = i + 1
  }
  let v = 0
  while at != 0 && at < n && s[at] >= 48 && s[at] <= 57 {
    v = v * 10 + (s[at] - 48)
    at = at + 1
  }
  arena_release(mark)
  BOOT_SEC = v
  return v
}

fn now_ns() -> int {
  if TICKS - CLOCK_AT > 1000000 {
    CLOCK_NS = read_uptime_ns()
    CLOCK_AT = TICKS
  }
  return CLOCK_NS
}

fn sys_clock_gettime() -> int {
  let which = X[0]
  let tp = X[1]
  # CLOCK_PROCESS_CPUTIME_ID and CLOCK_THREAD_CPUTIME_ID measure CPU time,
  # which this interpreter does not account for: fail rather than invent it.
  if which == 2 || which == 3 { return -EINVAL }
  if which < 0 || which > 7 { return -EINVAL }
  if mem_ok(tp, 16) == 0 { return -EFAULT }
  let ns = now_ns()
  let sec = ns / 1000000000
  let sub = ns % 1000000000
  # REALTIME and its coarse variant are epoch based; the monotonic clocks
  # start at boot, which is exactly what uptime measures.
  if which == 0 || which == 5 { sec = boot_seconds() + sec }
  wr64(tp, sec)
  wr64(tp + 8, sub)
  return 0
}

fn sys_gettimeofday() -> int {
  let tv = X[0]
  let ns = boot_seconds() * 1000000000 + now_ns()
  if tv != 0 {
    if mem_ok(tv, 16) == 0 { return -EFAULT }
    wr64(tv, ns / 1000000000)
    wr64(tv + 8, (ns % 1000000000) / 1000)
  }
  # The timezone argument is ignored by Linux and by every libc in practice.
  if X[1] != 0 {
    if mem_ok(X[1], 8) == 0 { return -EFAULT }
    wr64(X[1], 0)
  }
  return 0
}

# ------------------------------------------------------------------ entropy

# /proc/sys/kernel/random/uuid hands out 36 fresh random bytes per read, and is
# the only entropy source reachable without open(). The bytes are copied into a
# fixed buffer and the scratch arena released, so a caller asking for a large
# buffer does not pay for a proc read per byte. Without /proc the interpreter
# fills with zeros rather than pretend to be random.
let ENTROPY_BUF = newbuf(64)
let ENTROPY_LEN = 0
let ENTROPY_POS = 0
let ENTROPY_FAILED = 0

fn entropy_fill(addr: int, n: int) {
  let i = 0
  while i < n {
    if ENTROPY_POS >= ENTROPY_LEN {
      if ENTROPY_FAILED == 1 {
        wr8(addr + i, 0)
        i = i + 1
      } else {
        let mark = arena_mark()
        let s = read_file("/proc/sys/kernel/random/uuid")
        let k = 0
        while k < 36 && k < len(s) {
          ENTROPY_BUF[k] = s[k]
          k = k + 1
        }
        arena_release(mark)
        ENTROPY_LEN = k
        ENTROPY_POS = 0
        if k == 0 { ENTROPY_FAILED = 1 }
      }
    } else {
      wr8(addr + i, ENTROPY_BUF[ENTROPY_POS])
      ENTROPY_POS = ENTROPY_POS + 1
      i = i + 1
    }
  }
}

fn sys_getrandom() -> int {
  let n = X[1]
  let flags = X[2]
  if n < 0 || flags < 0 || flags > 7 { return -EINVAL }
  if mem_ok(X[0], n) == 0 { return -EFAULT }
  entropy_fill(X[0], n)
  return n
}

# ----------------------------------------------------------------- dispatch

fn sys_set_tid_address() -> int {
  TID_ADDR = X[0]
  return VIRTUAL_TID
}

fn do_syscall() {
  let n = X[8]
  TICKS = TICKS + 1

  # Syscall numbers are sparse, so switch on the high nibble first: the
  # buckets are dense and each arm still tests exact numbers.  This keeps the
  # cold path out of a 26-deep compare chain.
  switch n >> 5 {
    case 0 {
      if n == 29 { X[0] = sys_ioctl(); return }
    }
    case 1 {
      if n == 57 { X[0] = sys_close(); return }
      if n == 63 { X[0] = sys_read(); return }
    }
    case 2 {
      if n == 64 { X[0] = sys_write(); return }
      if n == 65 { X[0] = sys_readv(); return }
      if n == 66 { X[0] = sys_writev(); return }
      if n == 93 || n == 94 { exit(X[0] & 255) }
    }
    case 3 {
      if n == 96 { X[0] = sys_set_tid_address(); return }
      if n == 99 {                       # set_robust_list: one thread, nothing to track
        X[0] = 0
        return
      }
      if n == 113 { X[0] = sys_clock_gettime(); return }
      if n == 114 { X[0] = sys_gettimeofday(); return }
    }
    case 5 {
      if n == 172 || n == 178 { X[0] = VIRTUAL_TID; return }
      if n == 173 { X[0] = 0; return }   # getppid: the single process is init
      if n == 174 || n == 175 || n == 176 || n == 177 { X[0] = 0; return }
    }
    case 6 {
      if n == 214 { X[0] = sys_brk(); return }
      if n == 215 { X[0] = sys_munmap(); return }
      if n == 222 { X[0] = sys_mmap(); return }
    }
    case 7 {
      if n == 226 { X[0] = sys_mprotect(); return }
      if n == 233 { X[0] = sys_madvise(); return }
    }
    case 8 {
      if n == 278 { X[0] = sys_getrandom(); return }
    }
    case 9 {
      if n == 293 {                      # rseq: the guest falls back to locks
        X[0] = -ENOSYS
        return
      }
    }
    else { }
  }
  die("unsupported syscall " + n + " at pc 0x" + hex(AT))
}
