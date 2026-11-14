# tlang

Version 1.0.0

A small, high-level language that compiles to **very small native Linux binaries**.
Its compiler, **tcomp**, is written in tlang itself. The same language is used
to build `taarch64/`, a user-mode AArch64 interpreter.

```tlang
fn fibonacci(n) {
  if n < 2 { return n }
  return fibonacci(n - 1) + fibonacci(n - 2)
}

fn main() {
  let i = 0
  while i < 10 {
    print_int(fibonacci(i))
    print(" ")
    i = i + 1
  }
  print("\n")
}
```

Measured on x86-64 Linux with binutils 2.47:

| Program | Size | `--no-opt` |
|---|---|---|
| `fn main() {}` | **256 B** | 256 B |
| hello world (`print("hello, tlang\n")`) | **329 B** | 333 B |
| fib (recursion, 10 calls) | 602 B | 669 B |
| fizzbuzz (20 lines of output, branches) | 749 B | 790 B |
| primes, first 20 (functions, loops, calls) | 692 B | 826 B |
| words (stdin, `read_file`, `argv`) | 1,579 B | 1,717 B |
| **tbox** (four tools: `wc`, `head`, `tail`, `grep`) | **7,092 B** | — |
| **tjson** (JSON validate, format, query) | 13,327 B | — |
| **tbf** (Brainfuck interpreter) | 3,612 B | — |
| tcomp, the whole compiler | 106,157 B | — |
| *for comparison:* hello world in C, `gcc -Os -s` | 14,472 B | — |
| *for comparison:* `grep` + `wc` + `head` + `tail` from coreutils | 437 KB | — |

Timings are wall-clock `tcomp build tcomp.tl --asm` on a development machine
(code generation only, without assembling or linking).

Hello world is **44× smaller than the C equivalent**, and an empty `main` is
**256 B** — 232 of which are the ELF header and three program headers. On a
file this small the optimizer only moves a few bytes; its 6–16% shows up in
loop bodies, and in run time.

No libc, no CRT, no dynamic loader, no relocations — `_start` issues its own
syscalls and `ld` writes a single read/execute segment.

**Contents:** [Quick start](#quick-start) · [The language](#the-language) ·
[Programs](#programs) · [taarch64](#taarch64-an-aarch64-interpreter) ·
[C to tlang](#c-to-tlang) · [How the binaries get small](#how-the-binaries-get-small) ·
[Architecture](#architecture) · [Tests](#tests) · [Layout](#layout) ·
[Known limitations](#known-limitations) · [Contributing](#contributing)

---

## Quick start

```bash
./tcomp --version                       # tcomp 1.0.0
./tcomp run Examples/hello.tl           # compile and run
./tcomp build Examples/hello.tl         # -> ./hello
./tcomp build Examples/hello.tl --asm   # show the generated assembly
./tcomp build Examples/hello.tl --ir    # show the optimized three-address IR
./tcomp build Examples/hello.tl --no-opt      # skip IR optimization
./tcomp build Examples/hello.tl --keep-sections   # keep ELF section headers
```

Requirements: Python 3.9+ (for the bootstrap compiler) and binutils (`as`, `ld`).
The assembler flag `-mx86-used-note=no` needs GNU binutils 2.36 or newer.

### Self-hosted compiler

`tcomp.tl` is the compiler, written in tlang. Build it with the bootstrap compiler:

```bash
Tools/selfhost.sh --verify     # builds Build/tcomp and proves the fixed point
```

```
stage 1: tcomp.tl -> Build/tcomp0 (via stage 0)
  Build/tcomp0: 141440 bytes
stage 2: tcomp.tl -> Build/tcomp (via stage 1)
  Build/tcomp: 106157 bytes
stage 3: tcomp.tl -> Build/tcomp2 (via stage 2)
stage 4: tcomp.tl -> Build/tcomp3 (via stage 3)
fixed point: stage 2 and stage 3 are identical (106157 bytes)
```

`Build/tcomp` emits assembly on stdout:

```bash
Build/tcomp hello.tl > hello.s
as --64 -mx86-used-note=no -o hello.o hello.s
ld -s -z noseparate-code --build-id=none -o hello hello.o
python3 -m Bootstrap.elf hello          # same post-link trim the driver does
```

---

## The language

### Values

Three kinds of value:

* **int** — signed 64-bit. Comparisons yield `1`/`0`; `if`/`while` treat `0` as false.
* **str** — a pointer to NUL-terminated bytes.
* **float** — an unboxed IEEE-754 double, carried in one 64-bit slot.

There is no separate boolean type; `float()` and `int()` are explicit conversions.

### Floating point

Decimal literals include a point or exponent: `1.5`, `2.0`, `1e3`, `2.5e-1`.
Arithmetic, comparisons and mixed int/float arithmetic are supported; function
parameters and return types can be `float`:

```tlang
fn average(a: float, b: float) -> float {
  return (a + b) / 2.0
}

fn main() {
  print_float(average(1.0, 2.0))   # 1.500000
  print_float(sqrt(2.0))          # 1.414214
  print_int(int(3.9))             # 3
}
```

`print_float` uses fixed six-decimal formatting. `str(f)` builds a string with
the same digits but trims trailing zeros, so `str(1.5)` is `"1.5"` and
`str(2.0)` is `"2"`. Both split the integer and fractional parts before
scaling, so integer parts up to the 64-bit range print exactly; a larger
magnitude switches to exponent form (`str(1e19)` is `"1e19"`), and
`print_float` prints that same form rather than malformed digits. `sqrt` and
`fabs` are the built-in math library; NaN and infinity are recognized by
comparisons and printed as `nan`/`inf`. An integer passed to a function
expecting `float` must be converted explicitly (`float(i)`).

### Statements

Statements end at a newline (a `;` is also accepted, and optional). Comments are
`#`, `//`, or a non-nesting `/* ... */` block.

```tlang
fn classify(n) {
  if n < 0 { return -1 }
  else if n == 0 { return 0 }
  else { return 1 }
}

fn main() {
  for i in 1..10 {
    if i % 2 == 0 { continue }
    if i > 7 { break }
    print_int(i)
  }
  print("\n")
}
```

* `let NAME = expr` declares; `NAME = expr` assigns.
* `for i in A..B { }` walks `A` up to (not including) `B`. The bound is
  evaluated **once**, before the first iteration, and `continue` still advances
  the counter. A range loop is the common case, so it has its own syntax rather
  than making you write the counter by hand.
* `for x in VALUE { }` walks a string's bytes (as ints) or an array's elements.
  The collection and its length are read once; `continue` moves to the next
  element and `break` leaves the loop.
* `do { ... } while cond` runs the block once before testing the condition.
  `continue` jumps to the condition and `break` leaves the loop.
* `loop { ... }` is an unconditional loop, equivalent to `while 1`, but making
  the intent explicit; it needs a `break` or `return` to finish.
* `i++`, `i--`, `++i`, `--i` are statements, sugar for `i = i + 1` and
  `i = i - 1`. They need a plain variable and cannot be used inside an
  expression.
* `switch VALUE { case 1 { } case 2, 3 { } else { } }` runs the first matching
  arm; there is no fallthrough. `break` leaves the switch, while `continue`
  leaves to the enclosing loop. Case values are number or string literals, and
  a switch needs an arm to be typed as an integer or a string switch.
* `NAME += expr`, `-=` `*=` `/=` `%=` `&=` `|=` `^=` `<<=` `>>=` are sugar for
  `NAME = NAME op expr`. The target is evaluated twice, so it must be a plain
  variable — `a[i] += 1` is rejected rather than silently evaluating the index
  twice.
* `if` / `else if` / `else`, `while`, `break`, `continue`, `return`.
* Blocks are `{ ... }` and nest scopes; inner names may shadow outer ones.

### Functions

Function arguments are passed in registers (`rdi rsi rdx rcx r8 r9`), so a call
takes at most **6** arguments. Parameters and return values may carry optional
type annotations: `int`, `str`, a struct name, or `T[]` for an array of `T`.
Unannotated values are tracked syntactically by the compiler.

```tlang
fn repeat(s: str, n: int) -> str {
  let out = ""
  let i = 0
  while i < n {
    out = out + s
    i = i + 1
  }
  return out
}
```

`main` takes no parameters. Its return value (or falling off its end, which
returns `0`) becomes the process exit status.

Calls are checked against the annotations in both compilers: a string passed
to an `int` parameter, a string returned from an `int` function, or
`print_int(s)` is a compile error. Unannotated values are unknown and are never
rejected. `0` is accepted wherever a pointer, array or struct is wanted,
because it is the language's null; it is *not* accepted as a string.

### Operators

| Level | Operators |
|---|---|
| 1 | `\|\|` |
| 2 | `&&` |
| 3 | `\|` |
| 4 | `^` |
| 5 | `&` |
| 6 | `==` `!=` |
| 7 | `<` `<=` `>` `>=` |
| 8 | `<<` `>>` |
| 9 | `+` `-` |
| 10 | `*` `/` `%` |

The order is C's, so an expression written for C means the same thing here:
`x & 1 == 1` is `x & (1 == 1)`, not `(x & 1) == 1`. `&&` and `||` short-circuit.
`!`, unary `-` and `~` bind tighter than all of them. `==` and `!=` compare
string *contents* when both sides are strings. The other comparisons order two
strings the same way `strcmp` does — byte by byte, with a prefix before the
longer string — so `if a < b` sorts by text rather than by pointer.

Pointer arithmetic works in 8-byte slots for `ptr`, array and struct values:
`p + i`, `p - i`, `i + p`, `p - q` (element difference), plus `+=`, `-=`,
`++` and `--`. A `str` is not a typed pointer: `+` concatenates strings, so
byte movement uses `str_offset(s, n)` and `str_diff(a, b)`.

Bitwise operators see the 64-bit integer the hardware sees: `>>` is arithmetic
(a negative value stays negative), and a shift count is taken modulo 64.
`~` is bitwise complement; `!` is still logical not.

```tlang
let flags = 0
flags |= 4                     # set a bit
if flags & 4 { print("on\n") }
flags &= ~4                    # clear it again
print_int(1 << 10)             # 1024
print_int(0x0F & 0b1010)       # 10
```

### Strings

String literals support `\n`, `\t`, `\r`, `\\`, `\"`, `\'`, `\0`, and `\e`.
`+` concatenates; an int on either side is converted first:

```tlang
print("n = " + 42 + "\n")     # n = 42
print_int(len("hello"))        # 5
print_int("hello"[1])          # 101  ('e')
print("hello"[0])              # error: print() needs a string
```

`"hello"[i]` yields the byte as an int; assigning to it writes a byte. Only
strings you allocated (`alloc`, `slice`, `input`, `read_file`) should be mutated.

Integer literals can be written in hex (`0xFF`) or binary (`0b1010_1111`), with
`_` as a digit separator.

`len()` is O(n) in the string, but a loop that asks for it does not pay for it
repeatedly: the optimizer hoists an invariant `len()` out of the loop (see
[IR optimization](#how-the-binaries-get-small)), so `while i < len(s)` is a
linear scan. The hoist only happens when the loop cannot change the string.

### Arrays

Arrays are allocated as 8-byte slots, indexed without bounds checks:

```tlang
fn main() {
  let nums = [3, 1, 4, 1, 5]
  let sum = 0
  let i = 0
  while i < len(nums) {
    sum = sum + nums[i]
    i = i + 1
  }
  print("sum = " + sum + "\n")

  let grid = alloc(100)        # 100 slots, zeroed
  grid[7] = 42
  print_int(grid[7])
}
```

A literal whose elements share one kind is typed: `[3, 1, 4]` is an `int[]`,
so `for n in nums` and `append` know what a slot holds. A mixed literal stays
untyped. A function without a return annotation keeps that type at the call
site, so `for n in nums()` works without writing `-> int[]`.

Every array carries its length in a header, so `len(a)` is O(1) for a heap
array and for a literal — there is no counter to keep. `append(a, x)` returns
the array with one element added, and doubles the capacity when it is full:

```tlang
fn main() {
  let squares = alloc(0)
  for i in 0..10 {
    squares = append(squares, i * i)
  }
  print_int(len(squares))      # 10
  print_int(squares[9])        # 81
}
```

`append` returns the array rather than updating the variable, because a call
cannot assign to one, so you assign it back. While there is spare capacity it
writes in place; when it grows, it copies into a fresh block, so another
variable still holding the old array keeps the old contents and length.
`alloc(n)` starts with `n` zeroed elements, so `append` onto it adds element
`n`.

Allocations normally last until the process exits. `arena_mark()` returns an
opaque offset, and `arena_release(mark)` discards every allocation made after
it. This is useful for per-request or per-frame scratch space:

```tlang
fn main() {
  let mark = arena_mark()
  let scratch = alloc(1000)
  # ... temporary work ...
  arena_release(mark)
}
```

Only release a region when no pointer allocated in it escapes into longer-lived
state; tlang does not check lifetimes.

Array annotations (`int[]`, `str[]`, `Pair[]`) work on parameters, return
types and struct fields, so a helper can take an array and use `len`, `append`
and indexing on it:

```tlang
fn total(a: int[]) -> int {
  let sum = 0
  for i in 0..len(a) {
    sum = sum + a[i]
  }
  return sum
}
```

`alloc(n, T)` allocates a typed array, so indexing yields `T`:

```tlang
struct Pair { a, b }
let pairs = alloc(10, Pair)
pairs[0] = Pair(3, 4)
print_int(pairs[0].b)          # 4
```

### Structs

Fields are 8-byte slots at fixed offsets; a struct value is a pointer.

```tlang
struct Token { kind, text: str, line }

fn main() {
  let t = Token(7, "let", 12)
  print_int(t.kind)            # 7
  print(t.text)                # let
  t.kind = 9
}
```

Field annotations (`text: str`, `p: Pair`) are optional but let the compiler
keep track of types through field access.

### Globals

```tlang
let counter = 0
let greeting = "hi"

fn bump(by: int) {
  counter = counter + by
}

fn main() {
  bump(3)
  bump(4)
  print(greeting + " " + counter + "\n")   # hi 7
}
```

Globals are initialized in declaration order before `main` runs.

### Modules

A file can import another file at top level:

```tlang
import "mathlib.tl"

fn main() {
  print_int(double_it(21))
}
```

Imports are recursive and relative to the importing file. The imported
file's functions, structs and globals are merged into the same program; there
are no namespaces. A path is loaded once, and a cycle or duplicate import is a
compile error. Imports must be top-level lines, not inside a function.

`Modules/twayland.tl` is a bundled module: it opens a real Wayland window
(`tw_open`, `tw_clear`, `tw_pixel`, `tw_rect`, `tw_present`) and reports
keyboard and pointer input through `tw_poll` (`TW_KEY`, `TW_MOUSE_X`,
`TW_BUTTON`, ...). `Modules/twayland-demo.tl` is a 50-line program that draws
three rectangles and moves one with the arrow keys or WASD. Both are described
in the module headers.

### Builtins

| Call | Effect |
|---|---|
| `print(v)`, `print_err(v)` | write a string or an integer to stdout / stderr |
| `print_int(n)` | write a decimal integer |
| `print_char(c)` | write one byte |
| `len(s)` | string length (O(n), hoisted), or array length (O(1)) |
| `append(a, x)` | array with `x` added at the end; assign it back |
| `input()` | read one line from stdin; the newline is stripped |
| `int(s)` | parse decimal (`-` and leading spaces allowed); `0` if no digits |
| `int(f)` | truncate a float toward zero |
| `float(i)` | convert an integer to a float |
| `print_float(f)` | write a float with six decimal places (`1e19` in exponent form) |
| `sqrt(f)`, `fabs(f)` | square root and absolute value |
| `str(v)` | decimal string of an integer, or of a float with trailing zeros trimmed (exponent form above 64 bits) |
| `slice(s, start, n)` | new string of `n` bytes from `s` |
| `str_eq(a, b)` | content equality, `1`/`0` |
| `str_offset(s, n)` | byte offset `n` into `s`, as a string |
| `str_diff(a, b)` | byte difference between two strings |
| `alloc(n)`, `alloc(n, T)` | zeroed heap block of `n` slots |
| `arena_mark()`, `arena_release(mark)` | save/rewind the bump arena for scoped reuse |
| `read_file(path)` | whole file as a string (`/dev/stdin` works; `""` on failure) |
| `write_file(path, data)` | write a text file, truncating it; `1` on success |
| `append_file(path, data)` | append text to a file; `1` on success |
| `file_exists(path)` | `1` if the path can be accessed |
| `file_size(path)` | real file length in bytes, even when the data contains NUL |
| `sock(path)` | connect a Unix socket; used by the X11 client and the Wayland module |
| `fd_read(fd, buf, n)`, `fd_write(fd, buf, n)` | binary read/write of `n` bytes, retrying short transfers |
| `fd_poll(fd, ms)` | wait up to `ms` for socket readability |
| `newbuf(n)` | zeroed `n`-byte string buffer that can hold NUL bytes |
| `shm(n)` | a `memfd` of `n` bytes, returned as a descriptor (Wayland buffers) |
| `fd_pwrite(fd, off, buf, n)` | write `n` bytes at `off`, rewriting in place |
| `fd_send(fd, buf, n, pass)` | send one message with the descriptor `pass` attached (`SCM_RIGHTS`) |
| `argv(i)`, `argc()` | command-line access (index 0 is the program path) |
| `exit(n)` | terminate with status `n` |

---

## Programs

Five programs, escalating in what they ask of the language. All of them build
with the self-hosted compiler as well as stage 0.

| Program | Size | |
|---|---|---|
| `Programs/tbox.tl` | 7,092 B | `wc`, `head`, `tail`, `grep` in one binary |
| `Programs/tjson.tl` | 13,327 B | JSON validate / pretty-print / query |
| `Programs/tbf.tl` | 3,612 B | a Brainfuck interpreter — a real bytecode VM |
| `Programs/tchip8.tl` | 24,066 B | a CHIP-8 interpreter with terminal and X11 displays |
| `Programs/tgameboy.tl` | 42,265 B | a Game Boy DMG CPU, joypad and background PPU |

### tbox — four tools, one binary

```bash
./tcomp build Programs/tbox.tl -o tbox
printf 'alpha beta\ngamma\n' | ./tbox wc        # 2 3 17
./tbox grep -in delta *.txt                     # file:line:text
./tbox head -n 20 README.md
```

| Command | |
|---|---|
| `tbox wc [file...]` | lines, words and bytes, with a total for several files |
| `tbox head [-n N] [file...]` | first N lines (default 10) |
| `tbox tail [-n N] [file...]` | last N lines |
| `tbox grep [-i] [-n] [-c] [-v] PATTERN [file...]` | `-i` fold case, `-n` line numbers, `-c` count, `-v` invert |

No file argument means stdin, and `grep` keeps the shell contract: exit 0 when
it matched, 1 when it did not, 2 on a usage error. On a 3.4 MB text file `tbox
grep -c` returns the same count as GNU grep in 25 ms (GNU grep: 5 ms).

It is 62× smaller than the four coreutils binaries it replaces (437 KB), and
the test suite compares its output against theirs byte for byte. A hosted C
equivalent of the same four tools lives in `Programs/tbox.c`; it follows
tbox.tl's output and exit behavior, but is not part of the tcomp build.

### tjson — a JSON processor

```bash
./tcomp build Programs/tjson.tl -o tjson
./tjson fmt package.json                # pretty-print, validating on the way
./tjson fmt --compact package.json      # one line, byte-identical to the input
./tjson get .dependencies.typescript package.json
./tjson keys .scripts package.json
```

A JSON document is a tree and tlang has no tagged unions, which is exactly the
sort of thing this language needs to be able to express. The tree lives in five
**parallel arrays** indexed by an int: `KIND` says what a node is, `VAL` holds
its text, and `FIRST`/`COUNT` point into a shared child-index array. Children
end up contiguous because each container collects the indices it parsed on a
stack and appends them in one run when it closes.

Two decisions worth naming:

* **Numbers keep their original text**, so `fmt` re-prints `1.50` and `1e9`
  exactly as written instead of rounding them through an int.
* **Strings are stored raw** (still containing their escapes) and decoded only
  when `get` prints a value. `fmt` therefore reproduces the input byte for byte,
  and escapes that a tlang string cannot hold (`\b`, `\f`, `\uXXXX`) survive
  formatting instead of being mangled.

`Tests/programs_test.py` checks `fmt` against Python's `json.dumps` on 25
generated documents, both pretty and compact — they are byte-identical.

On a 77 KB document (6,000 values) `fmt --compact` takes 21 ms and a single
`get` 3 ms; Python's `json` does the same round trip in 1.5 ms. The first
version took **2.4 s**, because `ok_here()` asked for `len(SRC)` on every
character — the cached length is one line, and worth naming: a 113× difference
that no output comparison would ever have caught. The compiler now hoists that
call by itself, which costs this program 16 bytes of frame and would have saved
the afternoon.

### tbf — a bytecode VM

```bash
./tcomp build Programs/tbf.tl -o tbf
./tbf hello.bf                     # Hello World!
printf 'xyz' | ./tbf cat.bf        # xyz
```

A Brainfuck program is a flat byte string, so execution is a program counter
over that string plus a **precomputed jump table**: scanning forward to the
matching bracket on every loop iteration would make any loop O(n²). Building
the table is one pass with a stack, after which `[` and `]` are a single array
load. That is the same shape as a real bytecode interpreter — dispatch on an
opcode, an operand stack (here a 30,000-cell tape), a branch table — in 3.6 KB.
`[-]` and `[+]` collapse to a single store instead of up to 255 iterations
(35× faster on a clear-loop-heavy program), and a program larger than the
64 KB jump table is rejected instead of writing past it.

### What writing them found

Both defects were fixed in the runtime rather than worked around in the
programs:

* **`read_file` truncated at 1 MB.** It issued one read into the arena. It now
  `lseek`s for the exact size, allocates exactly that and loops until EOF;
  pipes, which cannot seek, get a 1 MB window. The arena went 16 MB → 64 MB
  (still `.bss`, still 0 file bytes).
* **`len()` is `strlen`**, so `while i < len(s)` re-walks the string on every
  byte and makes a scan quadratic. That was a trap in the language rather than a
  bug in the runtime, and it is now fixed in the compiler: an invariant `len()`
  is hoisted out of its loop, so the manual length caching in `tbox`'s
  `line_end` is no longer needed (it does no harm).

And one bug in the programs themselves that the tests caught immediately: an
object stores keys and values alternately, so it has **half** as many pairs as
child slots. Printing `COUNT` entries instead of `COUNT/2` invented keys, which
is precisely the sort of thing a byte-exact comparison against `json.dumps`
exposes in one run.

---

### tchip8 — a CHIP-8 interpreter

```bash
./tcomp build Programs/tchip8.tl -o tchip8
./tchip8 ibm.ch8 50000          # run 50,000 instructions, print the frame
./tchip8 game.ch8 20000 1       # hold key 0 (decimal bitmask)
./tchip8 Examples/tchip8-demo.ch8 500 0 8    # redraw every 8 instructions
./tchip8 Examples/tchip8-demo.ch8 x11        # native 512x256 X11 window
```

The 64x32 display is printed as `#`/`.` rows. One instruction is one cycle, the
timers tick every ten instructions, and the optional mask holds keys for
`EX9E`/`EXA1` and `FX0A`. CHIP-8 has no clock or exit instruction, so this is a
headless tester rather than an interactive player: by default it runs a fixed
instruction count and prints one frame at the end. A fourth `frame=N` argument
clears the terminal and redraws every N instructions (ANSI), which makes the
shipped `Examples/tchip8-demo.ch8` — one 8x8 green block moving diagonally —
animate; its loop is exactly eight instructions, so every frame ends on a
completed draw. All 35 opcodes are implemented; `FX55`/`FX65` leave I unchanged and
`8XY6`/`8XYE` shift VX in place (original CHIP-8 behaviour).

`x11` mode is a native window, not a terminal trick: tchip8 parses the MIT
cookie from `$XAUTHORITY` (or `~/.Xauthority`), speaks the X11 protocol over
`/tmp/.X11-unix/X0`, creates a 512x256 window, and paints lit cells as green
rectangles over a black background. `1`/`2`/`3`/`4`, `q`/`w`/`e`/`r`,
`a`/`s`/`d`/`f` and `z`/`x`/`c`/`v` map to `1`/`2`/`3`/`C`,
`4`/`5`/`6`/`D`, `7`/`8`/`9`/`E` and `A`/`0`/`B`/`F`. The loop runs
exactly eight instructions per frame at roughly 60 fps. The display is
bitmap-exact at 8x8 pixels per cell, the window title is `tchip8`, and
`WM_DELETE_WINDOW` closes it cleanly.

`Tests/chip8_test.py` assembles seven ROMs (drawing, BCD/font, collision, key
skips, frame mode, the shipped demo) and compares the frame byte-for-byte with
a Python reference in both compilers. The X11 path is manual because it needs a
real display; it was checked against the running X server with the demo ROM,
including the title, close protocol, and a 4,096-pixel capture. Frame mode also caught a compiler
divergence: stage 0 decoded `\e` to ESC, while the self-hosted compiler emitted
a literal `e`. `asm_esc` in `tcomp.tl` now emits `\033`, and both agree. The hot loop was tuned by inlining fetch and the timer tick and by
computing `y`/`n`/`nn` only in the opcodes that use them: **74.5 Mcycles/s** on
stage 0 (was 67.0) and **130.1 Mcycles/s** self-hosted (was 92.4).

Reading ROMs exposed a language gap: `read_file` returns a NUL-terminated
string, so `len()` stops at the first zero byte of a binary. `file_size(path)`
(new, in both compilers) asks `lseek` for the real length, and the loader
indexes that many bytes of the read buffer.

### tgameboy — a Game Boy core with a background PPU

```bash
./tcomp build Programs/tgameboy.tl -o tgameboy
./tgameboy Examples/tgameboy-demo.gb 50       # CPU state: GBDMG at 0xC000
./tgameboy Examples/tgameboy-pong.gb frame    # 160x144 playfield
./tgameboy Examples/tgameboy-pong.gb x11      # playable 480x432 Pong
./tgameboy Examples/tgameboy-art.gb x11       # static art demo
./tgameboy ROM 300 regs                       # PC/SP/AF/BC/DE/HL
./tgameboy ROM keys 36 50                     # held-joypad test hook
```

This is a DMG Game Boy core: the SM83 CPU, the memory map, MBC1 banking, and a
background PPU. Execution starts at `0x0100` with the post-boot register
state, so no Nintendo boot ROM is needed. The base and CB-prefixed opcode sets
are implemented, along with IE/IF/IME interrupt dispatch and returns. The CPU
dump prints the 32 bytes at `0xC000`; `regs` adds PC/SP/AF/BC/DE/HL.

The PPU renders the background from VRAM, including both tile-data modes, both
tile maps, `SCX`/`SCY`, and `BGP`, into a 160x144 framebuffer. `LY` advances one
line per 456 cycles and VBlank raises `IF` bit 0; the frame is rendered at
VBlank rather than per scanline. `frame` prints the four shades as ` .oO`;
`x11` opens a 3x (480x432) native window with four DMG greens. The window is
titled `tgameboy` and closes via `WM_DELETE_WINDOW`.

The joypad register at `FF00` now reports the selected direction/button group
active-low. In `x11`, arrows or WASD move, Z/Space is A, X is B, Enter is Start,
and Backspace is Select. `Examples/tgameboy-pong.gb` is a playable
background-only Pong: the left paddle is yours, the right paddle chases the
ball, and the score digits update at the top.

Still missing: sprites, the window layer, timer, audio, CGB, and exact PPU
timing. CPU cycle counts are approximate.

The shipped `Examples/tgameboy-demo.gb` writes `GBDMG` to `0xC000`.
`Examples/tgameboy-pong.gb` is the playable game; `Tools/make_tgameboy_pong.py`
assembles it from a tiny SM83 helper. `Examples/tgameboy-art.gb` remains the
static border/checker/GB demo, and `Examples/tgameboy-screen.gb` is the
deterministic stripe ROM used by the headless frame test. `Tests/gameboy_test.py`
generates seven ROMs covering ALU flags, loads, calls/stack, CB-prefixed ops,
interrupts, MBC1 banking and the CPU demo, plus one held-joypad register case
and a byte-exact 23,184-byte PPU frame; all pass in both compilers.

---

## taarch64: an AArch64 interpreter

`taarch64/` is a separate project written in tlang: a user-mode AArch64
interpreter for small static Linux binaries. It loads an `ET_EXEC` image into a
flat 16 MiB guest address space, executes the scalar integer A64 subset that
`gcc -O2` emits for freestanding C (plus the 128-bit `ldr q`/`str q` copies it
uses for small blocks), and translates `svc #0` calls onto the host.
`qemu-aarch64` is the reference used to check new instruction coverage.

```bash
./taarch64/build.sh
aarch64-linux-gnu-gcc -static -nostdlib -O2 -o hello.a64 hello.c
./taarch64/taarch64 hello.a64          # hello, aarch64
```

Dynamic binaries are rejected at load time; a fully static glibc binary stops
on a NEON instruction the interpreter does not implement. Instruction and
syscall coverage, the memory model, build options and limitations are in
[`taarch64/README.md`](taarch64/README.md).

---

## C to tlang

`Tools/ctolang.py` translates a subset of C into tlang, so a program that
already exists can be rebuilt by tcomp:

```bash
python3 Tools/ctolang.py hello.c -o hello.tl
./tcomp build hello.tl -o hello
```

It is not a C compiler and does not try to be one. It rewrites what tlang
expresses exactly and refuses — with a message naming the construct — anything
it cannot preserve, because a silent semantic change is worse than an error.

`Tests/c_test.py` builds every program in `Tests/C/` twice: once with
`gcc -O1`, once through the translator, and then rebuilds each translation with
the self-hosted compiler. All three must agree on stdout and exit status.
**16 programs, byte-identical output; 256,816 B of gcc binaries against
16,896 B of tlang (15.2×).**

| C | tlang |
|---|---|
| `printf("%d\n", x)` | `print_int(x)` then `print("\n")` |
| `while ((c = getchar()) != EOF)` | a byte reader over `read_file("/dev/stdin")` |
| `char buf[64]` | `slice("   ...", 0, 64)` — a mutable byte buffer |
| `char *s = "hi"` | `let s = "hi"` |
| `double x = 1.5` | `let x = 1.5` |
| `malloc(n * sizeof(int))`, `calloc(n, sizeof(int))` | `alloc(n)` |
| `p + 1`, `p - q` on `int *` | pointer offset and element difference |
| `s + 1`, `s - t` on `char *` | `str_offset(s, 1)`, `str_diff(s, t)` |
| `struct Node *p = malloc(sizeof(struct Node))` | `let p = Node(0, 0)` |
| `p->next` | `p.next` |
| `switch (x) { case A: ... }` | an `if`/`else if` chain over a copy of `x` |
| `n += x & 1` | `n = n + (x & 1)` — same thing, tlang has `&` |
| `case 1: case 2: body` | one `if` with `x == 1 \|\| x == 2` |
| `for (...; ...; i++) continue` | a `while` whose `continue` runs the step first |

Two translations are worth calling out. A `for` loop becomes a `while` loop,
which would make `continue` skip the step — the step is therefore emitted into
the `continue` path, so the loop still advances. And a compound assignment
parenthesises its right side, because `n += x & 1` is `n = n + (x & 1)` and
`&` binds looser than `+` in both languages.

Refused by the C translator on purpose: `typedef`, `union`, `goto`, `switch`
fallthrough, function pointers, address-of, pointers deeper than one level
(except `char **argv`), more than six parameters, `printf` field widths
(`%5d`), `sizeof` outside an allocation size, and `s == t` on two strings — that
compares pointers in C and contents in tlang, so the message suggests `strcmp`.
Typed pointer arithmetic and `char *` arithmetic are translated; the latter uses
`str_offset` / `str_diff`.

`sizeof` is deliberately not a C object-layout implementation. It is accepted
only as an element size in `malloc`/`calloc`, where it becomes tlang slot
allocation; ordinary `sizeof` expressions and `sizeof(char)`/`sizeof(float)`
allocations are rejected instead of silently using the wrong byte size.

## How the binaries get small

1. **No libc, no CRT.** `_start` calls `main` and issues `exit` itself. Nothing
   is linked in; every runtime facility is hand-written assembly.
2. **Assembler notes off.** GNU `as` adds a 48-byte `.note.gnu.property` (the
   x86 ISA/feature bits) and two program headers that point at it. No loader
   reads either, and `as -mx86-used-note=no` drops both: 160 bytes of headers,
   and 165 bytes once hello world's alignment is counted (494 B → 329 B). A
   larger program can lose the gain again to the page boundary in front of
   `.data`.
3. **Section headers removed after linking.** The kernel runs a binary from its
   program headers alone; the 320 bytes of section headers and the 28-byte
   section-name table are pure weight in a file this size. Dropping them
   (`Bootstrap/elf.py`, the same trick as `sstrip`) takes hello world from
   680 B to 329 B.
4. **Conditional runtime.** Each helper declares its dependencies, so a program
   that never prints ships no I/O code at all; unreferenced data such as the
   out-of-memory message is not emitted either.
5. **Dead-function elimination.** Only functions reachable from `main` are emitted.
6. **IR optimization.** Loop-invariant `len()` hoisting, constant folding,
   immediate operands, copy coalescing, compare-into-branch fusion and
   dead-temporary removal (`Bootstrap/optir.py`). Every pass judges a temporary
   by its straight-line interval, not by a whole-function read count: IR temps
   are reused from statement to statement, so "read once in the function" is
   almost never true. That is what lets `cmp`+`setcc`+store+`jz` collapse into
   one `cmp`+`jcc`. Worth **6–16% of the file** — the bytes barely move on the
   smallest programs because the file is dominated by fixed ELF overhead, but
   the loop bodies do — and **1.75×** the run speed on the original passes,
   **2.09×** on a loop whose body is mostly conditions.
7. **Link flags.** `-s -z noseparate-code --build-id=none`: a do-nothing
   program is 185 B after the post-link trim, versus 4,616 B with plain `ld`.
8. **`.bss` for buffers.** The 64 MB string arena is NOBITS — it costs 0 file bytes.
9. **Direct syscalls.** `write`, `read`, `open`, `close`, `exit` — no wrappers.

The templates in `isa.py` are written for clarity, so a naive expansion of
`x = x + 1` is three instructions and an unused call result is stored anyway.
`optir.py` takes that slack back before selection runs:

```
imm t1, 1              add QWORD PTR [rbp-8], 1
bin add t1, x, t1  ->  # one instruction, no temporary
mov x, t1
```

A comparison used only to branch never becomes a value:

```
cmp lt t, a, b         mov rax, [a]
jz t, .Lelse      ->   cmp rax, [b]
                       jge .Lelse

# and with a constant operand, one comparison against memory:
cmpk lt t, a, 5        cmp QWORD PTR [rbp-8], 5
jz t, .Lelse      ->   jge .Lelse
```

`len()` is the one call worth moving across control flow. A condition like
`while i < len(s)` re-walks the whole string on every iteration, so a scan
becomes quadratic — over a 32 KB string that loop took **248 ms**, and **0.2 ms**
once the call is computed in front of the loop label. `--no-opt` still takes
both the 248 ms path and the recompute-every-iteration path, and
`Tests/diff_test.py` checks that the two builds agree. The pass refuses any loop
that writes the string, calls a function (a global's `len()` could have
changed) or stores a byte into it — storing `\0` would move the end.

The rest of the passes are deliberately local: a rewrite only fires when the
adjacent instruction makes it provably equivalent. `Tests/diff_test.py` checks
that compiling every case, every example and 150 generated programs with and
without optimization produces identical output.

### What it costs

| | |
|---|---|
| Compile time, `Examples/fizzbuzz.tl` | 49.9 ms optimized, 50.2 ms with `--no-opt` |
| Compile time, `tcomp.tl` (4,142 lines + 1,505 generated) | 395 ms optimized, 346 ms with `--no-opt` |
| Run time, 20M-iteration loop + `fib(27)` | 64.1 ms with `--no-opt` → **36.6 ms** |

Removing the section headers is the one change that costs something: a stripped
binary no longer works with `objdump`, `readelf -S` or `strip`. `--keep-sections`
keeps them when you need to look inside.

---

## Architecture

```
tlang source
   ↓ lexer      tokens, with newline -> ';' insertion
   ↓ parser     AST (fmt: file:line:col on every node)
   ↓ lower      three-address IR with virtual registers
   ↓ optimize   hoist / fold / coalesce / dead-definition elimination (optir.py)
   ↓ select     IR op -> instruction template (table-driven)
   ↓ peephole   local rewrites
   ↓ emit       x86-64 assembly (Intel syntax)
   ↓ as, ld     native ELF
   ↓ sstrip     section headers and tail removed                 (elf.py)
```

Code generation never mentions a register from language logic: every IR op is
expanded by a template in `Bootstrap/isa.py`, with typed operands (`Reg`, `Mem`,
`Imm`, `RipMem`) formatting themselves. A new operator is one table entry.

### Two compilers, one language

| | |
|---|---|
| `Bootstrap/` | stage 0: a compiler in Python. Exists only to build stage 1. |
| `tcomp.tl` | the real compiler, written in tlang, single-pass, emitting assembly directly. |

The fixed point is checked by `Tests/fixedpoint.py`: stage 1 compiles
`tcomp.tl` into stage 2, stage 2 compiles it into stage 3, and stage 2 and
stage 3 must be **byte-identical** — that is what proves the language can
express its own compiler. Both compilers pass the same behavioral suite.

The runtime assembly, builtin metadata and kind-compatibility rule are defined
once: `Bootstrap/runtime.py` is generated into `Runtime/runtime_gen.tl`,
`Bootstrap/builtin_spec.py` is emitted into tables for both compilers by
`Tools/gen_builtins.py`, and `Tools/gen_kinds.py` emits both kind-rule
implementations. Neither compiler keeps a hand-maintained second copy of these
tables. `Tools/selfhost.py` is the single bootstrap/link/fixed-point verifier
used by the shell command, `Tests/fixedpoint.py` and CI.

The self-hosted compiler is deliberately simpler than stage 0: it emits a fixed
4 KB frame per function and compiles in a single pass without an AST. It has no
IR, so its rewrites — compare-into-branch, placing up to three plain arguments
straight into their parameter registers, folding a load into the copy that
consumes it, weaving a small constant or a memory operand into the operation, and
narrowing a constant load — run as a peephole over a ten-line window of its
output.

---

## Tests

```bash
python3 Tests/version_test.py   # stage 0 and tcomp.tl report tcomp 1.0.0
python3 Tests/run_tests.py      # golden output + exit status + binary size
python3 Tests/diff_test.py      # optimizer must not change behaviour
python3 Tests/programs_test.py  # tbox, against real arguments and real grep
python3 Tests/c_test.py         # C -> tlang translations, against gcc
python3 Tests/chip8_test.py     # CHIP-8 frames against a Python reference
python3 Tests/fixedpoint.py     # self-hosting: stages, byte comparison, suite
python3 Tests/builtins_test.py  # one generated builtin contract for both compilers
python3 Tests/runtime_test.py   # runtime dependency closure and assembly
python3 Tests/errors_test.py    # both compilers must reject bad programs
python3 Tests/compare_test.py   # stage 0 and self-hosted compiler must agree
python3 Tests/sourcemap_test.py # imported-file errors name the imported file
python3 Tests/io_test.py        # file output and the no-print dependency
python3 Tests/modules_test.py   # recursive imports through both compilers
python3 Tests/wayland_test.py   # Wayland input against a fake compositor
python3 Tests/floats_test.py    # float arithmetic, casting, math and printing
python3 Tests/gameboy_test.py   # Game Boy CPU/PPU parity
python3 Benchmarks/float_bench.py  # float vs int vs C, same dependent loop
python3 Tests/stress_test.py    # generated programs vs a Python model
Tools/selfhost.sh --verify      # bootstrap and fixed-point check, step by step
```

Cases live in `Tests/Cases/`: `NAME.tl` with optional `NAME.in` (stdin),
`NAME.out` (expected stdout) and `NAME.code` (expected exit status).
`--update` rewrites the golden files — read the diff before trusting it.

---

### Float benchmark

`Benchmarks/float_bench.py` runs a dependent 50-million-iteration recurrence
through stage 0, the self-hosted compiler, and optimized C. Results on an AMD
Ryzen 7 5800X3D with GCC 16.2.1:

| Build | Median | Mops/s |
|---|---:|---:|
| tlang float, stage 0 | 0.171 s | 586 |
| tlang float, self-hosted | 0.248 s | 403 |
| C `double -O2` | 0.069 s | 1,450 |
| tlang int, stage 0 | 0.055 s | 1,830 |
| C `uint64_t -O2` | 0.046 s | 2,166 |

The float loop is dependency-bound and scalar; these numbers are not a SIMD or
transcendental-function benchmark. Inlining and multiply-add fusion made stage 0
25% faster and self-hosted 13% faster than the pre-optimization versions, but C
remains about 2.5× faster than stage 0 for this recurrence.

## Layout

```
tcomp                 CLI: build / run / --asm / --ir / version
tcomp.tl              the compiler, in tlang
Bootstrap/            stage-0 compiler (Python)
  lexer.py parser.py ast_nodes.py lower.py ir.py optir.py isa.py emit.py
  opt.py runtime.py elf.py driver.py cli.py errors.py kindrules_gen.py
  builtin_spec.py     builtin metadata source
  builtins_gen.py     generated stage-0 builtin tables
Runtime/              generated modules imported by both compilers
  runtime_gen.tl      assembly runtime, generated from Bootstrap/runtime.py
  kinds_gen.tl        kind-compatibility rule, generated by Tools/gen_kinds.py
  builtins_gen.tl     builtin name -> ID mapping for the self-hosted compiler
Tools/selfhost.sh     thin wrapper around Tools/selfhost.py
Tools/selfhost.py     shared bootstrap, link and fixed-point verifier
Tools/gen_runtime.py  generate Runtime/runtime_gen.tl
Tools/gen_kinds.py    generate the kind rule for both compilers
Tools/gen_builtins.py generate builtin tables for both compilers
Tools/ctolang.py      C -> tlang translator
Tests/version_test.py tlang/tcomp version contract
Tests/run_tests.py    golden-output suite
Tests/diff_test.py    optimized vs unoptimized differential test
Tests/programs_test.py  behavioural tests for Programs/
Tests/c_test.py       C -> tlang translation tests, checked against gcc
Tests/chip8_test.py   CHIP-8 frames against a Python reference
Tests/fixedpoint.py   self-hosting stages, byte comparison and golden suite
Tests/builtins_test.py builtin metadata contract across both compilers
Tests/runtime_test.py runtime dependency closure and assembly
Tests/errors_test.py  programs both compilers are expected to reject
Tests/compare_test.py stage 0 vs self-hosted differential test
Tests/sourcemap_test.py imported-file diagnostics name the imported file
Tests/io_test.py      file output and self-hosted dependency checks
Tests/modules_test.py recursive import behaviour in both compilers
Tests/wayland_test.py twayland keyboard/pointer events against a fake compositor
Tests/floats_test.py  floating-point behaviour in both compilers
Tests/gameboy_test.py Game Boy CPU and PPU parity
Benchmarks/float_bench.py  float, integer and C performance comparison
Tests/stress_test.py  generated programs, checked against a Python model
.github/workflows/ci.yml  CI: contracts, compiler suites, fixed point
Tests/C/              the C programs those tests translate
Tests/Wayland/        twayland input program driven by the fake compositor
Examples/             hello, fib, fizzbuzz, primes, guess, words, tchip8-demo.ch8,
                      tgameboy-demo.gb, tgameboy-pong.gb, tgameboy-art.gb,
                      tgameboy-screen.gb
Programs/             tbox, tjson, tbf, tchip8, tgameboy: real programs, not demos
Programs/tbox.c       hosted C equivalent of tbox, for comparison
taarch64/             user-mode AArch64 interpreter for static binaries
```

---

## Known limitations

* No bounds checking on arrays or struct fields; out-of-range access is UB.
* Strings and arrays are arena-allocated. Individual blocks are never freed;
  `arena_mark()`/`arena_release(mark)` can rewind to an earlier allocation
  point. The 64 MB arena exits with a message when exhausted. Every allocation
  has a 16-byte header.
* `read_file` reads the whole file into the arena rather than streaming, so a
  program that slurps many large files can exhaust it.
* `read_file` returns a NUL-terminated string, so `len()` stops at the first
  zero byte. Use `file_size()` for the real length when indexing binary data
  (as `tchip8` does for ROMs).
* `write_file` and `append_file` write NUL-terminated text only; use
  `fd_write` for binary data.
* The X11 backend is fixed to display `:0` through `/tmp/.X11-unix/X0`, with a
  hardcoded X keycode map; there is no scaling or window-manager close protocol
  there (Ctrl+C exits the emulator).
* The Wayland client in `Modules/twayland.tl` opens a window from
  `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`, draws through a two-buffer `wl_shm` pool,
  reports keyboard and pointer events from `wl_seat`, and closes when the
  compositor asks. Keys are raw evdev codes — there is no xkb keymap parsing,
  touch, scroll, clipboard, cursor or frame-callback support, and no scaling.
* `len()` of a string is O(n); of an array it is O(1) (a header load). The
  string version is hoisted out of a loop when the compiler can prove the
  string is untouched there; a `len()` that a loop *does* re-take (because the
  string is rebuilt, or because the loop calls a function) is still quadratic.
* `append` copies the array when it grows, so aliases taken before a growth
  keep pointing at the old block and do not see later elements.
* No closures or generics.
* `print_float` and `str(float)` use six fractional digits. `str` trims
  trailing zeros (`str(2.0)` is `"2"`), so magnitudes below `1e-6` print as
  `0` (or `-0`). Integer parts up to the 64-bit range are exact; beyond that,
  both switch to exponent notation (`1e19`), and `print_float` uses that form
  instead of fixed decimals. The mantissa keeps six fractional digits, so very
  large values still lose digits in that formatter.
* There are no trigonometric, logarithmic or power functions. Arithmetic is
  inline scalar SSE2, including a fused multiply-add sequence; the compiler
  does not vectorize float code.
* Float `switch`, `%`, bitwise operators and `!`/`~` are rejected. Use explicit
  comparisons or `int()` instead.
* Decimal float literals are expanded through runtime power-of-ten scaling, so
  they are not guaranteed to be correctly rounded for every long literal.
  Mantissas are limited to a signed 64-bit integer.
* Imports have no namespaces or privacy: every imported declaration joins the
  same top-level scope. Duplicate imports and cycles are errors.
* Strings cannot hold arbitrary bytes from an expression: `\n`, `\t`, `\r`,
  `\\`, `\0` and `\e` are available in literals, but there is no way to build a
  string containing (say) byte 8 at runtime — print it with `print_char`
  instead (`tjson` decodes escapes this way).
* `tjson` handles up to 50,000 values and `tbf` a 30,000-cell tape; both limits
  are `let` constants at the top of the file.
* Integer division by zero raises SIGFPE.
* At most 6 function parameters.
* Type tracking is syntactic. A return without a `-> type` annotation is
  inferred from the first return that can be typed, using parameter, local and
  global annotations: literals, `str()`/`len()`/`int()`/`float()`, struct
  constructors, and array literals whose elements share one kind. That makes
  `str(f())`, `f().field` and `for x in f()` work without an annotation.
  Recursive functions and calls to functions declared later stay untyped, and
  a mixed array literal has no element kind.
* The self-hosted compiler assigns to `name`, `name[…]` and `name.field` only;
  nested targets such as `a[i].f = x` need the stage-0 compiler.
* Stage 0 optimizes at the IR level; the self-hosted compiler emits straight
  from the parse with no IR, so its output is usually larger (hello: 386 B
  versus 329 B). A five-line peephole over its output recovers the comparison
  tail and the operand push/pop, which is enough to beat stage 0 on branchy code
  (fizzbuzz: 652 B versus 749 B). Both binaries are trimmed the same way after
  linking.
* Kinds are checked at call sites, returns and builtin arguments, but not
  through arithmetic: adding a struct to an integer is not rejected, struct
  constructor fields are not checked, and unannotated values are trusted.
* The self-hosted compiler uses fixed tables: 60,000 tokens, 20,000 symbols,
  20,000 string literals, 4,000 functions, 1,000 structs, 256 locals and 512
  frame slots per function, and 500 nested loops. Exceeding a limit is a
  diagnostic, not memory corruption; stage 0 grows dynamically. Imports are
  expanded into a 4 MB source buffer, and a larger expansion is an error.
* Linux x86-64 only.

---

## Contributing

The compiler is self-hosting, so a language change must land in both
`Bootstrap/` (stage 0) and `tcomp.tl` (stage 1+), and the fixed point must still
hold:

```bash
python3 Tests/version_test.py    # the version contract must hold
python3 Tests/run_tests.py
python3 Tests/diff_test.py       # optimized and --no-opt builds must agree
python3 Tests/compare_test.py    # stage 0 and stage 1 must agree
Tools/selfhost.sh --verify       # stage 2 and stage 3 must be byte-identical
```

The generated modules are checked in. After changing the runtime, the kind
rule or builtin metadata, rerun `Tools/gen_runtime.py`, `Tools/gen_kinds.py` and
`Tools/gen_builtins.py`; `selfhost.sh` refuses to build from stale generated
files.

Keep changes scoped, run the checks that cover them, and update this README when
a size, timing or test count changes. `taarch64` is built separately; its qemu
comparison recipe lives in [`taarch64/README.md`](taarch64/README.md).
