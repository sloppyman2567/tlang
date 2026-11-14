# tbf -- a Brainfuck interpreter, and therefore a tiny bytecode VM.
#
#   tbf PROGRAM.bf [INPUT]
#
# The program is read from a file; INPUT is the text its `,` instructions
# consume (stdin if it is omitted). Anything that is not one of the eight
# instructions is a comment, which is what makes annotated Brainfuck readable.
#
# A Brainfuck program is a flat byte string, so execution is a program counter
# over that string plus a precomputed jump table: scanning forward to the
# matching bracket every time would turn any loop into O(n²) work. Building the
# table is one pass with a stack, and `[`/`]` then become a single array load.
#
# The tape is a heap array of TAPE_SIZE bytes, wrapping at both ends as the
# original specification allows.

let TAPE_SIZE = 30000

# Cached lengths: len() is strlen, and asking for it per input byte would make
# a long input quadratic.
let PROG = ""
let IN = ""
let IN_LEN = 0
let IN_POS = 0

let TAPE = alloc(TAPE_SIZE)
let JUMPS = alloc(65536)

let PC = 0
let PTR = 0
let STEPS = 0

fn fail(msg: str) {
  print_err("tbf: ")
  print_err(msg)
  print_err("\n")
  exit(2)
}

# `[` and `]` both get an entry: the instruction jumps to its partner whenever
# the loop condition says so, so one table serves both directions.
fn link_brackets() {
  if len(PROG) > 65536 {
    fail("program too large (limit 65536 bytes)")
  }
  let stack = alloc(65536)
  let depth = 0
  for i in 0..len(PROG) {
    if PROG[i] == 91 {
      stack[depth] = i
      depth = depth + 1
    } else if PROG[i] == 93 {
      if depth == 0 { fail("unmatched ']'") }
      depth = depth - 1
      JUMPS[stack[depth]] = i
      JUMPS[i] = stack[depth]
    }
  }
  if depth != 0 { fail("unmatched '['") }
}

fn next_input() -> int {
  if IN_POS >= IN_LEN {
    return 0
  }
  IN_POS = IN_POS + 1
  return IN[IN_POS - 1]
}

fn run() {
  let size = len(PROG)
  PC = 0
  PTR = 0
  STEPS = 0
  while PC < size {
    let op = PROG[PC]
    if op == 62 {
      PTR = PTR + 1
      if PTR >= TAPE_SIZE { PTR = 0 }
    } else if op == 60 {
      if PTR == 0 { PTR = TAPE_SIZE - 1 } else { PTR = PTR - 1 }
    } else if op == 43 {
      TAPE[PTR] = TAPE[PTR] + 1
      if TAPE[PTR] > 255 { TAPE[PTR] = 0 }
    } else if op == 45 {
      if TAPE[PTR] == 0 { TAPE[PTR] = 255 } else { TAPE[PTR] = TAPE[PTR] - 1 }
    } else if op == 46 {
      print_char(TAPE[PTR])
    } else if op == 44 {
      TAPE[PTR] = next_input()
    } else if op == 91 {
      if TAPE[PTR] == 0 {
        PC = JUMPS[PC]
      } else if PC + 2 < size && PROG[PC + 1] == 45 && PROG[PC + 2] == 93 {
        # `[-]`: a decrement-until-zero loop can only finish at zero.
        TAPE[PTR] = 0
        PC = JUMPS[PC]
      } else if PC + 2 < size && PROG[PC + 1] == 43 && PROG[PC + 2] == 93 {
        # `[+]`: the same, wrapping through all 256 cell values.
        TAPE[PTR] = 0
        PC = JUMPS[PC]
      }
    } else if op == 93 {
      if TAPE[PTR] != 0 { PC = JUMPS[PC] }
    }
    PC = PC + 1
    STEPS = STEPS + 1
  }
}

fn main() {
  if argc() < 2 {
    print("usage: tbf PROGRAM.bf [INPUT]\n")
    print("\n")
    print("  INPUT is the text consumed by ',' instructions (default: stdin)\n")
    exit(2)
  }
  PROG = read_file(argv(1))
  if len(PROG) == 0 { fail("cannot read the program") }
  if argc() > 2 {
    IN = argv(2)
  } else {
    IN = read_file("/dev/stdin")
  }
  IN_LEN = len(IN)
  link_brackets()
  run()
}
