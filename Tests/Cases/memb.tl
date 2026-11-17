# Unchecked byte-addressed access and bulk copy/fill over newbuf buffers.
fn main() {
  let b = newbuf(32)
  memset(b, 0, 32)
  st16(b, 0, 0x1234)
  st32(b, 4, 0xDEADBEEF)
  print_int(ld16(b, 0))
  print_int(ld32(b, 4))
  print("\n")
  let c = newbuf(32)
  memcpy(c, b, 8)
  print_int(ld32(c, 4))
  print("\n")
}
