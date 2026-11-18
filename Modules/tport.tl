# tport -- portable helpers for hosted tlang command-line programs.
#
#   import "Modules/tport.tl"
#
#   let args = alloc(2, str)
#   args[0] = "git"
#   args[1] = "--version"
#   if port_run(args) != 0 { print(port_error() + "\n") }
#
# The module is deliberately close to the operating system: it uses the
# hosted builtins, not libc.  Path helpers work on bytes, which is what Linux
# paths are.  `port_which` searches PATH and checks the executable bits instead
# of trusting file_exists, and `port_run` inherits the caller's environment.
#
# No function returns a borrowed buffer.  The strings returned by port_stdin,
# port_base, port_dir and port_join are fresh arena allocations, so callers may
# keep them or free them like any other string.

let PORT_ERR = ""

fn port_error() -> str {
  return PORT_ERR
}

fn port_clear_error() {
  PORT_ERR = ""
}

fn port_fail(msg: str) {
  if len(PORT_ERR) == 0 {
    PORT_ERR = msg
  }
}

# ----------------------------------------------------------------------- paths

fn port_is_abs(p: str) -> int {
  if len(p) > 0 && p[0] == 47 {
    return 1
  }
  return 0
}

# The last component, without trailing slashes.  port_base("/") is "/" and
# port_base("dir/") is "dir", matching the useful part of POSIX basename.
fn port_base(p: str) -> str {
  let end = len(p)
  if end == 0 {
    return ""
  }
  while end > 1 && p[end - 1] == 47 {
    end = end - 1
  }
  let start = end
  while start > 0 && p[start - 1] != 47 {
    start = start - 1
  }
  return slice(p, start, end - start)
}

# The directory part, without a trailing slash.  A bare name has "." as its
# directory, and an absolute child such as "/a" has "/" as its directory.
fn port_dir(p: str) -> str {
  let end = len(p)
  if end == 0 {
    return "."
  }
  while end > 1 && p[end - 1] == 47 {
    end = end - 1
  }
  let slash = end
  while slash > 0 && p[slash - 1] != 47 {
    slash = slash - 1
  }
  if slash == 0 {
    return "."
  }
  let n = slash - 1
  if n == 0 {
    return "/"
  }
  return slice(p, 0, n)
}

# The extension including the dot; a leading dot is part of the name, so
# port_ext(".bashrc") is empty and port_ext("a.tar.gz") is ".gz".
fn port_ext(p: str) -> str {
  let b = port_base(p)
  let n = len(b)
  let i = n - 1
  while i > 0 {
    if b[i] == 46 {
      return slice(b, i, n - i)
    }
    i = i - 1
  }
  return ""
}

fn port_join(a: str, b: str) -> str {
  if len(b) == 0 {
    return a
  }
  if len(a) == 0 || port_is_abs(b) == 1 {
    return b
  }
  if a[len(a) - 1] == 47 {
    return a + b
  }
  return a + "/" + b
}

fn port_env_or(name: str, fallback: str) -> str {
  let v = env(name)
  if len(v) == 0 {
    return fallback
  }
  return v
}

# ---------------------------------------------------------------------- lookup

# A regular file with at least one executable bit.  file_mode follows symlinks,
# so a symlink to a program is found too.  The type mask is S_IFMT from Linux;
# directories commonly have execute bits but are not commands.
fn port_exec_ok(p: str) -> int {
  let mode = file_mode(p)
  if mode < 0 {
    return 0
  }
  if (mode & 61440) != 32768 {
    return 0
  }
  if (mode & 73) == 0 {
    return 0
  }
  return 1
}

# Resolve a command the way a shell does.  A name with a slash is used as
# given; otherwise every PATH entry is tried, with an empty entry meaning the
# current directory.  When PATH is unset or empty, use the usual system
# default rather than silently failing in a minimal environment.
fn port_which(cmd: str) -> str {
  PORT_ERR = ""
  if len(cmd) == 0 {
    port_fail("empty command name")
    return ""
  }
  let i = 0
  let n = len(cmd)
  while i < n {
    if cmd[i] == 47 {
      if port_exec_ok(cmd) == 1 {
        return cmd
      }
      port_fail("not executable: " + cmd)
      return ""
    }
    i = i + 1
  }
  let path = env("PATH")
  if len(path) == 0 {
    path = "/usr/local/bin:/usr/bin:/bin"
  }
  i = 0
  n = len(path)
  while i <= n {
    let start = i
    while i < n && path[i] != 58 {
      i = i + 1
    }
    let dir = slice(path, start, i - start)
    let candidate = cmd
    if len(dir) > 0 {
      candidate = port_join(dir, cmd)
    }
    if port_exec_ok(candidate) == 1 {
      return candidate
    }
    i = i + 1
  }
  port_fail("not found on PATH: " + cmd)
  return ""
}

# --------------------------------------------------------------------- process

# Run argv, returning a shell-style status: the exit code (0-255), or 128 plus
# the signal number when the child was killed.  The command is resolved with
# port_which, so `port_run(["make"])` works.  Its environment is inherited, and
# it shares stdin/stdout/stderr with the caller.  This has no shell parsing:
# arguments are passed exactly as the array holds them.
fn port_run(args: str[]) -> int {
  PORT_ERR = ""
  if len(args) == 0 {
    port_fail("no command")
    return 127
  }
  let path = port_which(args[0])
  if len(path) == 0 {
    return 127
  }
  let pid = fork()
  if pid < 0 {
    port_fail("fork failed: " + args[0])
    return 127
  }
  if pid == 0 {
    exec(path, args)
    exit(127)
  }
  let status = waitpid(pid, 0)
  if status < 0 {
    port_fail("waitpid failed: " + args[0])
    return 127
  }
  let signal = status & 127
  if signal != 0 {
    return 128 + signal
  }
  return (status >> 8) & 255
}

# A convenience for the few cases where a shell pipeline really is the right
# interface.  The caller owns quoting; this is not an argument parser.
fn port_shell(command: str) -> int {
  let args = alloc(3, str)
  args[0] = "sh"
  args[1] = "-c"
  args[2] = command
  return port_run(args)
}

# ----------------------------------------------------------------------- stdio

# Read a descriptor to EOF, growing the result as needed.  This is binary-safe:
# the returned string may contain NUL bytes.  Its byte length is not `len()`
# once a NUL is present; the caller reads it with `file_size` when it came from
# a file, or tracks the count it wrote.
fn port_read_fd(fd: int) -> str {
  let cap = 65536
  let buf = newbuf(cap)
  let used = 0
  while 1 == 1 {
    if used + 65536 > cap {
      let next = cap * 2
      buf = realloc(buf, (next + 8) >> 3)
      cap = next
    }
    let n = fd_read(fd, str_offset(buf, used), 65536)
    used = used + n
    if n < 65536 {
      break
    }
  }
  if used >= cap {
    buf = realloc(buf, (cap + 9) >> 3)
  }
  buf[used] = 0
  return buf
}

fn port_stdin() -> str {
  return port_read_fd(0)
}

# Write exactly n bytes and report whether all of them went out.
fn port_write(fd: int, data: str, n: int) -> int {
  if n <= 0 {
    return 1
  }
  if fd_write(fd, data, n) == n {
    return 1
  }
  return 0
}

# ----------------------------------------------------------------------- files

# Copy any regular file byte for byte.  The destination's permissions follow
# the source's low mode bits.  The whole file is not loaded at once.
fn port_copy(src: str, dst: str) -> int {
  PORT_ERR = ""
  if str_eq(src, dst) == 1 {
    port_fail("source and destination are the same: " + src)
    return 0
  }
  let from = open_fd(src, 0)
  if from < 0 {
    port_fail("cannot open " + src)
    return 0
  }
  let to = open_fd(dst, 1 | 64 | 512)
  if to < 0 {
    close_fd(from)
    port_fail("cannot create " + dst)
    return 0
  }
  let buf = newbuf(65536)
  let ok = 1
  while 1 == 1 {
    let n = fd_read(from, buf, 65536)
    if n <= 0 {
      break
    }
    if fd_write(to, buf, n) != n {
      ok = 0
      break
    }
  }
  close_fd(from)
  close_fd(to)
  if ok == 0 {
    unlink(dst)
    port_fail("write failed: " + dst)
    return 0
  }
  let mode = file_mode(src)
  if mode >= 0 {
    chmod(dst, mode & 4095)
  }
  return 1
}

# Rename when possible, otherwise copy and unlink.  This is the usual
# mv behaviour within one filesystem or across two; directories are not moved
# through the copy fallback.
fn port_move(src: str, dst: str) -> int {
  PORT_ERR = ""
  if str_eq(src, dst) == 1 {
    port_fail("source and destination are the same: " + src)
    return 0
  }
  if rename(src, dst) == 0 {
    return 1
  }
  if port_copy(src, dst) == 0 {
    return 0
  }
  if unlink(src) != 0 {
    port_fail("cannot remove " + src)
    return 0
  }
  return 1
}

# Create every missing component of path.  Existing directories are accepted;
# an existing non-directory is an error.  The final component may be omitted
# (a trailing slash) or already present.
fn port_mkdir_p(path: str) -> int {
  PORT_ERR = ""
  let n = len(path)
  if n == 0 {
    port_fail("empty path")
    return 0
  }
  let i = 0
  if path[0] == 47 {
    i = 1
  }
  while i <= n {
    if i == n || path[i] == 47 {
      let part = slice(path, 0, i)
      if len(part) > 0 && is_dir(part) == 0 {
        if mkdir(part, 493) != 0 && is_dir(part) == 0 {
          port_fail("cannot create " + part)
          return 0
        }
      }
      while i < n && path[i] == 47 {
        i = i + 1
      }
      if i == n {
        break
      }
    }
    i = i + 1
  }
  return 1
}

# Remove a file or an empty directory.  Recursive removal is deliberately not
# here: following a symlinked directory would delete outside the tree, and the
# language has no lstat builtin with which to distinguish it.
fn port_remove(path: str) -> int {
  PORT_ERR = ""
  if unlink(path) == 0 {
    return 1
  }
  if is_dir(path) == 1 && rmdir(path) == 0 {
    return 1
  }
  port_fail("cannot remove " + path)
  return 0
}
