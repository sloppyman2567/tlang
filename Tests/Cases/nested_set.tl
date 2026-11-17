struct Pt { x: int, y: int }
struct Box { p: Pt, nums: int[], tags: str[] }

fn main() {
  let ps = alloc(0, Pt)
  ps = append(ps, Pt(1, 2))
  ps = append(ps, Pt(3, 4))
  ps[1].x = 30
  print_int(ps[1].x + ps[0].y)
  print("\n")

  let b = Box(Pt(5, 6), [1, 2, 3], ["a", "b"])
  b.p.y = 60
  b.nums[1] = 20
  b.tags[0] = "z"
  print_int(b.p.x + b.p.y)
  print(" ")
  print_int(b.nums[0] + b.nums[1] + b.nums[2])
  print(" ")
  print(b.tags[0] + b.tags[1])
  print("\n")

  let s = "abcd"
  s[1] = 66
  print(s)
  print("\n")

  let boxes = alloc(0, Box)
  boxes = append(boxes, b)
  boxes[0].p.x = 7
  print_int(boxes[0].p.x)
  print("\n")
}
