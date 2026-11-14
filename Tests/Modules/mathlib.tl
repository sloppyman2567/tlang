import "base.tl"

struct Pair {
  a: int,
  b: int,
}

fn pair_sum(p: Pair) -> int {
  return p.a + p.b + module_bias()
}

fn double_it(x: int) -> int {
  return x * 2
}
