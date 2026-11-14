# Twenty 8 MB allocations are 160 MB in total, far beyond the 64 MB arena.
# Each iteration releases back to its mark, so the arena never grows past one
# chunk. Without arena_release this program exits with the OOM message.

fn main() {
  let i = 0
  while i < 20 {
    let mark = arena_mark()
    let chunk = alloc(1000000)
    chunk[0] = i
    arena_release(mark)
    i = i + 1
  }
  print_int(i)
  print("\n")
}
