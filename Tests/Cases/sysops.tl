fn main() {
  # Working directory and identity are process-wide and stable within one run.
  print_int(chdir("/") == 0)
  print(" ")
  print_int(str_eq(getcwd(), "/"))
  print(" ")
  print_int(getuid() >= 0)
  print(" ")
  print_int(geteuid() >= 0)
  print(" ")
  print_int(getgid() >= 0)
  print(" ")
  print_int(getegid() >= 0)
  print("\n")

  # A page of anonymous memory is a byte buffer: ld/st and mprotect agree.
  let p = mmap(4096)
  print_int(p != 0)
  print(" ")
  st64(p, 0, 12345)
  st8(p, 500, 7)
  print_int(ld64(p, 0) + ld8(p, 500))
  print(" ")
  print_int(mprotect(p, 4096, 3))
  print(" ")
  print_int(munmap(p, 4096))
  print("\n")

  # Failure is the null value, not a negative errno: a byte buffer cannot be
  # compared against zero otherwise.
  print_int(mmap(0) == 0)
  print(" ")
  print_int(mmap(1 << 60) == 0)
  print("\n")

  # A private directory named after the pid, so a repeated run starts clean.
  let d = "/tmp/tlang_sysops_" + getpid()
  print_int(mkdir(d, 493))
  print(" ")
  print_int(chdir(d) == 0)
  print(" ")
  write_file("f", "abcdef")
  print_int(truncate("f", 3) == 0)
  print(" ")
  print_int(file_size("f"))
  print(" ")
  unlink("f")
  print_int(chdir("/") == 0)
  print(" ")
  print_int(rmdir(d) == 0)
  print("\n")
}
