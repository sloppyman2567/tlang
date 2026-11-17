# A fresh alloc(n) has exactly n slots of capacity, so append still grows (and
# copies) at the same point it always did.  A freed block is reused by the next
# request of its size class, and a reused block may have spare capacity.
struct Pair { a, b }

fn main() {
  let base = arena_mark()
  let a = alloc(3)
  a[0] = 11
  a[1] = 22
  free(a)
  let b = alloc(3)
  b[0] = 33
  print_int(arena_mark() - base)      # one 3-slot block: 3*8 + 16 = 40
  print(" ")
  print_int(b[0])
  print("\n")

  # realloc beyond the capacity copies the elements into a new block; shrinking
  # keeps the block and reports the new length.
  let c = alloc(2)
  c[0] = 7
  c[1] = 8
  c = realloc(c, 4)
  c[2] = 9
  c[3] = 10
  print_int(c[0] + c[1] + c[2] + c[3])
  print(" ")
  c = realloc(c, 1)
  print_int(len(c))
  print(" ")
  print_int(c[0])
  print("\n")

  # realloc(0, n) is alloc(n); free(0) is a no-op.
  let d = realloc(0, 2)
  d[0] = 5
  print_int(len(d) + d[0])
  free(0)
  print("\n")

  # A fresh block is exactly full, so append grows it and the alias keeps the
  # old length and contents.
  let g = alloc(3)
  let h = g
  g = append(g, 9)
  print_int(len(h))
  print(" ")
  print_int(len(g))
  print("\n")

  # Freeing below a mark keeps the block reusable after the release; only the
  # free-list nodes at or above the mark are dropped.
  let p = alloc(4)
  free(p)
  let mark = arena_mark()
  let q = alloc(8)
  free(q)
  arena_release(mark)
  let r = alloc(4)
  print_int(arena_mark() - mark)
  print("\n")

  # A zero-slot block has no payload slot to link, so free is a safe no-op.
  let z = alloc(0)
  free(z)
  print("zero")
  print("\n")

  # realloc keeps a struct's field type, so field access still type-checks.
  let s = Pair(4, 5)
  s = realloc(s, 2)
  print_int(s.a + s.b)
  print("\n")

  # realloc keeps a string buffer a string, so print() still accepts it.
  let sb = newbuf(3)
  sb = realloc(sb, 8)
  st8(sb, 0, 65)
  st8(sb, 1, 0)
  print(sb)
  print("\n")
}
