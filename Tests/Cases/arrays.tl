fn main() {
  let nums = [3, 1, 4, 1, 5, 9, 2, 6]
  let sum = 0
  let i = 0
  while i < len(nums) {
    sum = sum + nums[i]
    i = i + 1
  }
  print("len=" + len(nums) + " sum=" + sum + "\n")
  nums[0] = 100
  print_int(nums[0] + nums[7])
  print("\n")
}
