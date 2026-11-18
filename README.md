# tlang

<p align="center">
  <img src="tlang-icon.png" alt="tlang icon" width="112"><br>
  <a href="https://github.com/sloppyman2567/tlang/actions/workflows/ci.yml"><img src="https://github.com/sloppyman2567/tlang/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/version-1.5.0-blue" alt="version 1.5.0">
</p>

Version 1.5.0 — see [CHANGELOG.md](CHANGELOG.md) for release notes.

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

| Program | Size |
|---|---|
| `fn main() {}` | **300 B** |
| hello world (`print("hello, tlang\n")`) | **363 B** |
| fib (recursion, 10 calls) | 582 B |
| fizzbuzz (20 lines of output, branches) | 629 B |
| primes, first 20 (functions, loops, calls) | 642 B |
| words (stdin, `read_file`, `argv`) | 1,572 B |
| **tbox** (four tools: `wc`, `head`, `tail`, `grep`) | **6,767 B** |
| **tjson** (JSON validate, format, query) | 27,728 B |
| **tbf** (Brainfuck interpreter) | 4,464 B |
| tcomp, the whole compiler | 203,157 B |
| *for comparison:* hello world in C, `gcc -Os -s` | 14,472 B |
| *for comparison:* `grep` + `wc` + `head` + `tail` from coreutils | 437 KB |

Sizes include the default bounds checks and come from the single self-hosted
compiler; there is no separate optimizing front end to compare against.

Hello world is **40× smaller than the C equivalent**, and an empty `main` is
**300 B** — most of which is the ELF header and program headers.

No libc, no CRT, no dynamic loader, no relocations — `_start` issues its own
syscalls and `ld` writes a single read/execute segment.

**Contents:** [Quick start](#quick-start) · [The language](#the-language) ·
[Programs](#programs) · [taarch64](#taarch64-an-aarch64-interpreter) ·
[C to tlang](#c-to-tlang) · [How the binaries get small](#how-the-binaries-get-small) ·
[Architecture](#architecture) · [Tests](#tests) · [Layout](#layout) ·
[Known limitations](#known-limitations) · [Contributing](#contributing) ·
[License](#license)

---

## Quick start

```bash
./tcomp --version                       # tcomp 1.5.0
./tcomp run Examples/hello.tl           # compile and run
./tcomp build Examples/hello.tl         # -> ./hello
./tcomp build Examples/hello.tl --asm   # show the generated assembly
./tcomp build game.tl --no-bounds             # omit index checks (emulator loops)
./tcomp build Examples/hello.tl --keep-sections   # keep ELF section headers
./Kernel/build.sh                       # freestanding kernel: kernel.elf, .bin, .img
```

Requirements: Python 3.9+ (for the driver and generators) and binutils (`as`, `ld`).
The assembler flag `-mx86-used-note=no` needs GNU binutils 2.36 or newer.

### Self-hosted compiler

`tcomp.tl` is the compiler, written in tlang. Rebuild it from the checked-in seed:

```bash
Tools/selfhost.sh --verify     # builds Build/tcomp and proves the fixed point
```

```
stage 1: checked-in seed compiler (Tools/tcomp-seed)
  seed: 203157 bytes
stage 2: tcomp.tl -> Build/tcomp (via the seed)
  Build/tcomp: 203157 bytes
stage 3: tcomp.tl -> Build/tcomp2 (via stage 2)
stage 4: tcomp.tl -> Build/tcomp3 (via stage 3)
fixed point: stage 2 and stage 3 are identical (203157 bytes)
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

* `let NAME = expr` declares; `NAME = expr` assigns. A target can be any
  chain of indices and fields (`a[i].f = v`, `o.a.v = v`), and the value is
  stored where the same chain would read.
* `const NAME = <int or string literal>` names a literal. It has no storage and
  no startup store — every use is the literal itself, so a mask or a token kind
  folds into the instruction that reads it. A function may use a const declared
  further down the file, and assigning to one is a compile error.
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
  a switch needs an arm to be typed as an integer or a string switch. A dense
  integer switch compiles to one range check and a jump table; sparse and
  string switches use a compare chain.
* `NAME += expr`, `-=` `*=` `/=` `%=` `&=` `|=` `^=` `<<=` `>>>=` `>>=` are sugar for
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
returns `0`) becomes the process exit status. A program needs one `fn main()
{ }`, and defining a function, global or struct twice is a compile error.

Calls are checked against the annotations: a string passed
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
| 8 | `<<` `>>` `>>>` |
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
(a negative value stays negative), `>>>` shifts in zeros, and a shift count is
taken modulo 64. `>>>=` is the compound form. `~` is bitwise complement; `!` is
still logical not. `>>>` is what emulator code wants when it extracts an
unsigned field from a value that may have its top bit set:
`word >>> 24` needs no `& 0xFF` afterwards.

```tlang
let flags = 0
flags |= 4                     # set a bit
if flags & 4 { print("on\n") }
flags &= ~4                    # clear it again
print_int(1 << 10)             # 1024
print_int(0x0F & 0b1010)       # 10
```

### Strings

String literals support `\n`, `\t`, `\r`, `\\`, `\"`, `\'`, `\0`, `\e`, and
`\xNN` — exactly two hex digits, so `\x41` is `A` and `\x00` ends the string
like `\0` does. `+` concatenates; an int on either side is converted first:

```tlang
print("n = " + 42 + "\n")     # n = 42
print_int(len("hello"))        # 5
print_int("hello"[1])          # 101  ('e')
print("hello"[0])              # error: print() needs a string
```

`"hello"[i]` yields the byte as an int; assigning to it writes a byte. Only
strings you allocated (`alloc`, `slice`, `input`, `read_file`) should be mutated.

A string literal is the compact way to carry a byte table: `tchip8`'s 80-byte
font is one `\xNN` literal, which costs 80 bytes of data where an int array
literal costs a store per element.

Integer literals can be written in hex (`0xFF`) or binary (`0b1010_1111`), with
`_` as a digit separator.

`len()` is O(n) in the string, but a loop that asks for it does not pay for it
repeatedly: the optimizer hoists an invariant `len()` out of the loop (see
[How the binaries get small](#how-the-binaries-get-small)), so `while i < len(s)` is a
linear scan. The hoist only happens when the loop cannot change the string.

### Arrays

Arrays are allocated as 8-byte slots. Indexing is bounds-checked by default: an
index outside the array is reported and the process exits, rather than reading
or writing past the allocation.

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

Allocations come from a 64 MB arena and are reusable. `free(p)` returns a block
to a size-class free list, and `realloc(p, n)` shrinks in place or grows by
allocating, copying and freeing. A fresh `alloc(n)` has exactly `n` slots of
capacity, as before; a block taken from a free list may have more capacity than
the new request, so `append` can use that spare room. `len()` reports the
requested element count either way. Freeing a double or interior pointer is
undefined, and a pointer outside the arena is reported as `tlang: invalid
free`.

`arena_mark()` returns an opaque offset, and `arena_release(mark)` discards
every allocation made after it (free-list entries above the mark go with it).
This is useful for per-request or per-frame scratch space:

```tlang
fn main() {
  let mark = arena_mark()
  let scratch = alloc(1000)
  # ... temporary work ...
  arena_release(mark)
}
```

Only release a region when no pointer allocated in it escapes into longer-lived
state; tlang does not check lifetimes. Manual `free` is the fine-grained tool,
`arena_release` the bulk one.

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

Globals are initialized in declaration order before `main` runs. A function
may read a global declared later in the file; the compilers collect top-level
names before checking bodies, so declaration order does not restrict use.

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

`Modules/tjson.tl` parses strict JSON into parallel-array nodes and exposes
`json_parse`, `json_get`, `json_pointer`, `json_kind`, `json_text`,
`json_count`, `json_child`, `json_key`, `json_value` and `json_emit`. Object
keys can be selected by dot syntax or by a quoted bracket such as `.["a.b"]`,
and escaped keys are matched after decoding. Array indices may be negative.
`json_pointer` resolves RFC 6901 pointers (`/users/0/name`, `/a~1b`,
`/m~0n`). It keeps number and string tokens as written, so a parse/emit round
trip preserves `1.50` and escapes; query output decodes non-ASCII escapes as
UTF-8. Errors return `-1` with `json_error()` and `json_error_pos()` instead of
exiting.

The building side has `json_new_null`, `json_new_bool`, `json_new_int`,
`json_new_number`, `json_new_string`, `json_new_array`, `json_new_object`,
`json_array_push`/`set`/`remove`, and `json_object_set`/`remove`. Updates return
the node to keep: a child run at the end of the link array is extended in
place, otherwise a new node is allocated. `json_new_string` escapes text,
`json_new_number` validates the JSON number grammar, and updates reject direct
and indirect cycles. `json_parse` resets the shared arrays.
`Modules/tzip.tl` reads and writes ZIP archives: `zip_open`/`zip_name`/
`zip_size`/`zip_crc`/`zip_data`/`zip_extract`, and `zip_create`/`zip_add`/
`zip_add_file`/`zip_finish`. Written entries are stored or DEFLATE-compressed,
whichever is smaller, with a standard CRC-32. Reading supports stored entries
and deflated entries with fixed or dynamic Huffman blocks.
`Modules/tport.tl` holds the portable command-line layer: `port_base`,
`port_dir`, `port_ext`, `port_join`, `port_which`, `port_run`, `port_shell`,
`port_stdin`, `port_write`, `port_copy`, `port_move`, `port_mkdir_p` and
`port_remove`. It searches `PATH`, checks executable bits, inherits the
caller's environment when launching a child, reads stdin to EOF, and copies
files without loading them whole. The module headers document their limits.

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
| `free(p)`, `realloc(p, n)` | return a block to the heap; resize it in place or by copying |
| `arena_mark()`, `arena_release(mark)` | save/rewind the bump arena for scoped reuse |
| `read_file(path)` | whole file as a string (`/dev/stdin` works; `""` on failure) |
| `write_file(path, data)` | write a text file, truncating it; `1` on success |
| `append_file(path, data)` | append text to a file; `1` on success |
| `file_exists(path)` | `1` if the path can be accessed |
| `file_size(path)` | real file length in bytes, even when the data contains NUL |
| `now()` | nanoseconds since the Unix epoch |
| `sleep_ns(n)` | sleep for at least `n` nanoseconds; `0` on success |
| `random_int()` | 64 random bits from `getrandom` |
| `getpid()` | the process id |
| `mkdir(path, mode)`, `unlink(path)`, `rename(old, new)` | directory and file operations; `0` on success |
| `getcwd()` | current directory as a string, or `""` on failure |
| `open_fd(path, flags)` | open a file descriptor; Linux flags (`O_WRONLY`=1, `O_CREAT`=64, `O_TRUNC`=512, `O_APPEND`=1024), mode `0755` when created |
| `close_fd(fd)` | close a descriptor; `0` on success |
| `file_mtime(path)` | modification time in seconds since the epoch, or `-1` on failure |
| `open_dir(path)`, `read_dir(fd)`, `close_dir(fd)` | walk a directory: `read_dir` returns one entry name at a time, `""` at the end |
| `file_mode(path)`, `is_dir(path)`, `is_file(path)` | raw `st_mode`, and the two type tests most callers want |
| `symlink(target, link)`, `readlink(path)`, `chmod(path, mode)` | links and permissions |
| `chdir(path)`, `rmdir(path)` | change directory, or remove an empty one |
| `truncate(path, n)`, `ftruncate(fd, n)` | set a file's length |
| `getuid()`, `geteuid()`, `getgid()`, `getegid()` | process identity |
| `mmap(n)`, `munmap(p, n)`, `mprotect(p, n, prot)` | anonymous byte mappings, `0` on failure; `prot` uses Linux `PROT_*` |
| `tcp_connect(ip, port)`, `tcp_listen(port)`, `tcp_accept(fd)` | blocking TCP over numeric IPv4; ports are 1–65535 |
| `fork()`, `exec(path, argv)`, `waitpid(pid, opts)` | process creation, replacement and reaping; `exec` inherits the environment and `waitpid` returns the raw wait status |
| `pipe(fds)`, `dup2(old, new)`, `kill(pid, sig)`, `getppid()` | pipes, descriptor aliasing, signals and parent pid |
| `sock(path)` | connect a Unix socket; used by the X11 client and the Wayland module |
| `fd_read(fd, buf, n)`, `fd_write(fd, buf, n)` | binary read/write of `n` bytes, retrying short transfers |
| `fd_poll(fd, ms)` | wait up to `ms` for socket readability |
| `newbuf(n)` | zeroed `n`-byte string buffer that can hold NUL bytes |
| `shm(n)` | a `memfd` of `n` bytes, returned as a descriptor (Wayland buffers) |
| `fd_pwrite(fd, off, buf, n)` | write `n` bytes at `off`, rewriting in place |
| `fd_send(fd, buf, n, pass)` | send one message with the descriptor `pass` attached (`SCM_RIGHTS`) |
| `argv(i)`, `argc()` | command-line access (index 0 is the program path) |
| `env(name)` | value of an environment variable; `""` when it is unset |
| `clz(v)`, `rbit(v)` | leading zeros (`64` for `0`) and reversed 64 bits |
| `bswap16(v)`, `bswap32(v)`, `bswap64(v)` | reversed bytes, zero-extended to 64 bits |
| `sext8(v)`, `sext16(v)`, `sext32(v)` | sign-extend the low 8/16/32 bits |
| `udiv(a, b)`, `umod(a, b)` | unsigned 64-bit division and remainder |
| `rol8(v, n)`, `ror8(v, n)` | rotate the low byte; the count is taken modulo 8 |
| `ld8/16/32/64(buf, off)` | unchecked little-endian load from a byte buffer |
| `st8/16/32/64(buf, off, v)` | unchecked little-endian store into a byte buffer |
| `memcpy(dst, src, n)`, `memset(dst, v, n)` | bulk byte copy and fill |
| `memmove(dst, src, n)` | overlap-safe byte copy |
| `memcmp(a, b, n)` | byte comparison: negative, zero or positive |
| `exit(n)` | terminate with status `n` |

These bit primitives are aimed at emulator code, which otherwise rewrites the
same masking, sign-extension and byte-swapping loops in every program. They
compile to short leaf routines in the conditional runtime, so a program that
uses none of them pays nothing.

The `ld*`/`st*` family addresses a `newbuf` buffer by byte offset with no bounds
check and no endian shifting, and `memcpy`/`memset` are the usual `rep movsb` /
`rep stosb` loops. Together they are the primitives an emulator's guest-memory
helpers are built from. `tcomp build --no-bounds` drops the checks from ordinary
array and string indexing as well; the compiler accepts it, and it is meant
for measured hot loops, not general programs. The default remains checked.

### Directories and processes

The directory calls continue the descriptor pattern of `open_fd`: `open_dir`
returns an fd (or `-1`), `read_dir` returns the next name as a string, and
`close_dir` releases it. `read_dir` skips `.` and `..`, returns `""` at the end
of the directory, and copies each name, so names from earlier calls stay
valid. Up to four directories can be walked at once; closing the fd with either
`close_dir` or `close_fd` releases its cursor, and `read_dir` on a fifth active
directory returns `""`. Reaching the end exhausts that cursor, so reopen the
directory to start again.

```tlang
fn main() {
  let d = open_dir(".")
  loop {
    let name = read_dir(d)
    if name == "" { break }
    if is_file(name) { print(name + "\n") }
  }
  close_dir(d)
}
```

`file_mode` returns the raw `st_mode`, so a program can test any file type or
permission bit. `is_dir` and `is_file` are the two common answers already
masked for it; all three return `-1` or `0` respectively when the path cannot
be stat'd. `readlink` returns `""` on failure, and `chmod`/`symlink` return `0`
on success.

Processes are deliberately thin wrappers over the syscalls. `fork` returns
`0` in the child and the child pid in the parent. `exec(path, argv)` takes an
array of strings (at most 128 — a longer array fails with `-1` rather than
being silently truncated) and does not return on success; the caller's
environment is passed through unchanged, so a launched tool keeps `PATH`,
`HOME` and locale. `waitpid(pid, opts)` returns the **raw wait status**:
`(status & 127) == 0` means a normal exit, `(status >> 8) & 255` is the exit
code, and a nonzero low byte means the child was signalled. `pipe(fds)` writes
the read and write descriptors into slots 0 and 1 of a two-element int array.
All of these are hosted-only: a freestanding build rejects them with a named
error, like the other Linux builtins.

```tlang
fn main() {
  let fds = alloc(2)
  pipe(fds)
  let pid = fork()
  if pid == 0 {
    close_fd(fds[0])
    fd_write(fds[1], "hi", 2)
    exit(0)
  }
  close_fd(fds[1])
  let buf = newbuf(8)
  fd_read(fds[0], buf, 8)
  print(buf + "\n")            # hi
  waitpid(pid, 0)
}
```

`Tests/linux_extra_test.py` runs these programs.

### Kernel builtins

`tcomp build --freestanding` compiles a program with no Linux under it: `_start`
calls the entry function and halts instead of exiting, the 64 MB arena and the
stdio buffers are left out, and `print`, `print_char`, `print_int`, `alloc`,
`exit` and the out-of-memory/bounds diagnostics come from the kernel runtime
rather than the syscall runtime. The hosted-only builtins above (`input`,
`read_file`, `argv`, `env`, the `fd_*` family, ...) are rejected with an
error that names the flag, instead of emitting a syscall into a kernel.

The same flag unlocks the machine builtins:

| Call | Effect |
|---|---|
| `peek8/16/32/64(a)`, `poke8/16/32/64(a, v)` | memory read/write at a physical address, byte-granular |
| `outb(port, v)`, `inb(port)`, `io_wait()` | port I/O |
| `hlt()`, `cli()`, `sti()` | idle and interrupt control |
| `lgdt(a)`, `lidt(a)`, `ltr(sel)`, `invlpg(a)` | descriptor tables, TSS, paging flush |
| `read_cr2()`, `read_cr3()`, `write_cr3(v)`, `rdtsc()`, `iretq(frame)` | faults, address space, timing, ring 3 |
| `fb_fill(x, y, w, h, c)`, `fb_text(x, y, c, s)` | rectangles and 8x8 text in the framebuffer |
| `fb_char(x, y, c, ch)` | one glyph, for text held in a buffer |
| `fb_back()`, `fb_present(x0, y0, x1, y1)` | draw off-screen, then copy the damaged rectangle out |
| `fb_clip(x0, y0, x1, y1)` | keep fills inside a rectangle, so a band repaint costs the band |
| `fb_indexed(x, y, scale, buf, w, h)` | blit palette-indexed pixels out of a buffer, whole-pixel scale |
| `console_place(x, y)`, `console_hide()` | move the runtime's text grid, or park it |
| `console_dirty()` | the console cells repainted since the last call: 1 plus four cell coordinates |
| `ata_read(lba, n, addr)`, `ata_write(lba, n, addr)` | PIO sectors of the IDE slave disk |

Each one is a plain `call __k_<name>`. `Kernel/kruntime.s` holds those stubs, the
VBE 1280x1024x32 text console, the COM1 log and the bump allocator;
`Kernel/build.sh` links the result into `Kernel/kernel.elf` and
`Kernel/kernel.bin`.

`Kernel/build.sh` also assembles `Kernel/mbr.s` (the 512-byte boot sector) and
`Kernel/boot.s` (the long-mode trampoline) and writes `Kernel/kernel.img`: boot
sector, then the flat image, ready to boot as a raw disk.

```bash
./Kernel/build.sh
truncate -s 512K fs.img     # the filesystem disk, formatted on first boot
qemu-system-x86_64 -drive file=Kernel/kernel.img,format=raw,if=ide,index=0 \
  -drive file=fs.img,format=raw,if=ide,index=1 \
  -serial stdio
```

`Kernel/main.tl` is an ordinary tlang program, and what it draws is a desktop
at 1280x1024x32: a gradient wallpaper, a column of round app icons, a taskbar
with one button per app, and windows with gradient title bars, round close
buttons and drop shadows. Shapes are filled through `span8`, which blends the
boundary pixels, so circles and rounded corners are antialiased rather than
stepped.

It is a window manager, not a fixed layout: a table of windows in back-to-front
order, focus follows the window you click, a title bar drags a window and
repaints only the band it left and entered, and a close button removes it until
its icon or taskbar button brings it back. Repaints are composed into a back
buffer and then copied out with `fb_present`, so the erase between the two
halves of an update never reaches the screen: every change adds its rectangle to
one damage union, the loop copies that union once per frame, and `fb_clip`
narrows the runtime's fills to the band a drag actually touched. The runtime
paints the terminal's cells as text arrives, so `console_dirty` tells the window
manager which cells to present — and it repaints their band through the
z-order when another window covers the terminal, rather than letting glyphs land
on top of it. Six apps:

| App | What it is |
|---|---|
| terminal | the runtime's text console, placed inside the frame |
| editor | a text buffer with arrows, Backspace, Enter and Ctrl+S |
| files | the directory; click a name to open it in the editor |
| system | the about panel, drawn entirely by `main.tl` |
| paint | a 96x64 canvas of 16 colours, saved to TLFS with Ctrl+S |
| viewer | the saved canvas, read back from TLFS, at 1x to 4x |

Files live on the IDE slave disk in TLFS: a superblock, a 16-entry directory in
sector 1, and fixed 16-sector slots from LBA 2, so a file is at most 8 KiB and
survives a reboot. A save writes the data sectors first and the directory entry
last, so a machine that dies in between keeps the old size instead of a torn
file; a size read back from the directory is clamped to 8 KiB before anything
indexes with it; and a disk that will not read is reported as `[fs] disk error`
rather than formatted over. The writer goes through `ata_read`/`ata_write`; the
master disk holds the kernel image and is never written. The mouse is polled
(there are no interrupts yet), and a packet that loses a byte is dropped once
the controller goes idle, so the next packet starts in step.

The terminal understands:

| Command | Effect |
|---|---|
| `help` | list the commands |
| `about` | version and what the kernel is |
| `echo TEXT` | print TEXT back |
| `clear` | blank the window |
| `ticks` | `rdtsc` count |
| `mouse` | pointer position |
| `ls` | list the files with their sizes |
| `cat NAME` | print a file |
| `write NAME TEXT` | save TEXT as NAME |
| `rm NAME` | delete a file |
| `edit NAME` | open it in the editor |
| `halt` | stop the machine |

Backspace edits the line, Enter runs it, and anything else is reported as an
unknown command. In the editor, Ctrl+S writes the buffer back to the file.
`halt` writes to port `0xf4`, so QEMU's `isa-debug-exit` device turns the run
into an exit status; `Tests/kernel_test.py` drives the mouse and the keyboard
through QEMU's monitor, writes a file, edits it with Ctrl+S, halts, boots again
over the same disk image and checks that the edited file is still there. A QEMU
without GTK/SDL can still show the screen over VNC
(`-display vnc=127.0.0.1:1`).

---

## Programs

Five programs, escalating in what they ask of the language. All of them build
with tcomp.

| Program | Size | |
|---|---|---|
| `Programs/tbox.tl` | 6,767 B | `wc`, `head`, `tail`, `grep` in one binary |
| `Programs/tjson.tl` | 27,728 B | JSON validate / pretty-print / query |
| `Programs/tbf.tl` | 4,464 B | a Brainfuck interpreter — a real bytecode VM |
| `Programs/tchip8.tl` | 18,976 B | a CHIP-8 interpreter with terminal and X11 displays |
| `Programs/tgameboy.tl` | 30,529 B | a Game Boy DMG CPU, joypad and background PPU |

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

It is 50× smaller than the four coreutils binaries it replaces (437 KB), and
the test suite compares its output against theirs byte for byte. A hosted C
equivalent of the same four tools lives in `Programs/tbox.c`; it follows
tbox.tl's output and exit behavior, but is not part of the tcomp build.

### tjson — a JSON processor

```bash
./tcomp build Programs/tjson.tl -o tjson
./tjson fmt package.json                # pretty-print, validating on the way
./tjson fmt --compact package.json      # one line, byte-identical to the input
./tjson get .dependencies.typescript package.json
./tjson get '.["dependencies.typescript"]' package.json
./tjson get --pointer /dependencies/typescript package.json
./tjson get .tags[-1] package.json
./tjson keys .scripts package.json
```

Programs can also build documents with the same tree:

```tlang
let root = json_new_object()
root = json_object_set(root, "name", json_new_string("tlang"))
root = json_object_set(root, "items", json_new_array())
json_emit(root, 1)   # {"name":"tlang","items":[]}
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
  formatting instead of being mangled. `get` and `keys` write decoded
  non-ASCII escapes as UTF-8, including surrogate pairs such as U+1D11E.

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
opcode, an operand stack (here a 30,000-cell tape), a branch table — in 5.0 KB.
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
a Python reference. The X11 path is manual because it needs a
real display; it was checked against the running X server with the demo ROM,
including the title, close protocol, and a 4,096-pixel capture. Frame mode also caught an
`\e` escape bug, fixed by making `asm_esc` in `tcomp.tl` emit `\033`. The hot loop was tuned by inlining
fetch and the timer tick and by computing `y`/`n`/`nn` only in the opcodes that use
them: **130.1 Mcycles/s** (was 92.4).

Reading ROMs exposed a language gap: `read_file` returns a NUL-terminated
string, so `len()` stops at the first zero byte of a binary. `file_size(path)`
(new) asks `lseek` for the real length, and the loader
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
and a byte-exact 23,184-byte PPU frame; all pass.

---

## taarch64: an AArch64 interpreter

`taarch64/` is a separate project written in tlang: a user-mode AArch64
interpreter for small static Linux binaries. It loads an `ET_EXEC` image into a
flat 16 MiB guest address space, executes the scalar integer A64 subset that
`gcc -O2` emits for C (plus the exclusive loads and SIMD moves libc needs), and
translates `svc #0` calls onto the host. `qemu-aarch64` is the reference used to
check new instruction and syscall coverage.

```bash
./taarch64/build.sh

# freestanding guest
aarch64-linux-gnu-gcc -static -nostdlib -O2 -o hello.a64 hello.c
./taarch64/taarch64 hello.a64          # hello, aarch64

# ordinary static musl guest
aarch64-linux-musl-gcc -static -o hello.musl hello.c
./taarch64/taarch64 hello.musl         # hello, musl!
```

A static musl binary runs unmodified: the interpreter builds a real Linux
startup stack (`argc`/`argv`/`envp`/auxv, including `AT_PHDR` and `AT_RANDOM`),
implements `TPIDR_EL0` so libc can install its TLS, and serves `writev`,
`ioctl`, `malloc`'s `brk`/`mmap` and the rest of the calls libc makes. Dynamic
binaries are rejected at load time; a static glibc binary stops on a SIMD
arithmetic instruction the interpreter does not implement. Instruction and
syscall coverage, the memory model, build options and limitations are in
[`taarch64/README.md`](taarch64/README.md). `python3 taarch64/bifrost_test.py`
runs further static guests from a bifrost-emu download when one is available,
comparing each one with `qemu-aarch64`.

Both compiler stages build it: `./taarch64/build.sh --selfhost` produces the
interpreter with `Build/tcomp`, and that build runs the same musl guests. It is
the first tlang program to run a musl AArch64 binary under emulation, compiled
by tlang itself.

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
17,994 B of tlang (14.3×).**

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
2. **Assembler notes off.** `as -mx86-used-note=no` drops the x86 feature note
   and its two program headers, worth 160 bytes of headers.
3. **Section headers removed after linking.** `Bootstrap/elf.py` (the same trick
   as `sstrip`) drops the section headers and string table entirely.
4. **Conditional runtime.** Each helper declares its dependencies, so a program
   that never prints ships no I/O code at all; unreferenced data is not emitted
   either.
5. **Dead-function elimination.** Only functions reachable from the entry are
   emitted.
6. **Peephole rewrites.** `tcomp.tl` emits assembly in one pass, then a
   ten-instruction window folds loads into their consumers, narrows constant
   loads, and fuses compares into branches ("compare-into-branch").
7. **Link flags.** `-s -z noseparate-code --build-id=none`.
8. **`.bss` for buffers.** The 64 MB string arena is NOBITS — it costs 0 file bytes.
9. **Direct syscalls.** `write`, `read`, `open`, `close`, `exit` — no wrappers.

Removing the section headers is the one change that costs something: a stripped
binary no longer works with `objdump`, `readelf -S` or `strip`. `--keep-sections`
keeps them when you need to look inside.

## Architecture

```
tlang source (tcomp.tl + imported generated modules)
   ↓ prescan    top-level names and return annotations
   ↓ lex / parse  single pass, no AST
   ↓ emit       x86-64 assembly with peephole rewrites (tcomp.tl)
   ↓ as, ld     native ELF
   ↓ sstrip     section headers and tail removed          (Bootstrap/elf.py)
```

`Tools/tcomp-seed` is a checked-in build of `tcomp` used only to bootstrap: it
compiles `tcomp.tl` into `Build/tcomp`, which then compiles itself again. The
fixed point is checked by `Tests/fixedpoint.py` and `Tools/selfhost.sh --verify`:
stage 2 and stage 3 must be **byte-identical**. That is what proves the language
can express its own compiler. There is no second, Python implementation of the
language front end; `Bootstrap/` keeps only the runtime, builtin metadata, ELF
trimming and the thin `./tcomp` driver.

The runtime assembly, builtin metadata, kind-compatibility rule and version are
defined once in Python: `Bootstrap/runtime.py` is generated into
`Runtime/runtime_gen.tl`, `Bootstrap/builtin_spec.py` is emitted into the name →
ID table and dispatch by `Tools/gen_builtins.py`, `Tools/gen_kinds.py` emits the
kind rules, and `Tools/gen_version.py` generates the version constant. Plain
builtins listed in `GENERATED_BUILTINS` need only a spec entry, a runtime helper
and regeneration — no hand-written compiler branch.

The compiler emits a fixed 4 KB frame per function and rewrites a ten-line
window of its own output: compare-into-branch, arguments straight into parameter
registers, loads folded into their consumers, constants woven into operations,
and narrower constant loads. A prescan collects top-level names, globals and
return annotations first, so functions and globals may be used before their
declarations. The compiler uses fixed tables (60,000 tokens, 20,000 symbols);
overflow is a diagnostic, not memory corruption.

---

## Tests

```bash
python3 Tests/version_test.py   # the compiler reports tcomp 1.5.0
python3 Tests/run_tests.py      # golden output + exit status + binary size
python3 Tests/programs_test.py  # tbox, against real arguments and real grep
python3 Tests/c_test.py         # C -> tlang translations, against gcc
python3 Tests/chip8_test.py     # CHIP-8 frames against a Python reference
python3 Tests/fixedpoint.py     # self-hosting: stages, byte comparison, suite
python3 Tests/builtins_test.py  # generated builtin metadata and dependency flags
python3 Tests/runtime_test.py   # runtime dependency closure and assembly
python3 Tests/freestanding_test.py     # kernel image: no syscalls, links, refuses misuse
python3 Tests/machine_builtins_test.py # machine builtins and the kernel runtime stubs
python3 Tests/env_test.py       # environment lookup
python3 Tests/portability_test.py # common Linux builtins
python3 Tests/linux_extra_test.py # directory, metadata and process builtins
python3 Tests/linux_more_test.py # filesystem, identity, mmap and TCP builtins
python3 Tests/linux_stress_test.py # many files, mappings and socket round trips
python3 Tests/kernel_test.py   # boots the desktop, clicks and types at it
python3 Tests/errors_test.py    # rejected programs and diagnostic text
python3 Tests/sourcemap_test.py # imported-file errors name the imported file
python3 Tests/bounds_test.py    # checked indexing and runtime safety guards
python3 Tests/io_test.py        # file output and the no-print dependency
python3 Tests/modules_test.py   # recursive imports
python3 Tests/stdlib_test.py    # JSON and ZIP modules against Python
python3 Tests/wayland_test.py   # Wayland input against a fake compositor
python3 Tests/floats_test.py    # float arithmetic, casting, math and printing
python3 Tests/gameboy_test.py   # Game Boy CPU/PPU parity
python3 Benchmarks/float_bench.py  # float vs int vs C, same dependent loop
python3 Tests/stress_test.py    # generated programs vs a Python model
Tools/selfhost.sh --verify      # bootstrap and fixed-point check, step by step
```

CI runs every suite above on each push and pull request, except the float
benchmark, which measures performance rather than correctness.

Cases live in `Tests/Cases/`: `NAME.tl` with optional `NAME.in` (stdin),
`NAME.out` (expected stdout) and `NAME.code` (expected exit status).
`--update` rewrites the golden files — read the diff before trusting it.

---

### Float benchmark

`Benchmarks/float_bench.py` runs a dependent 50-million-iteration recurrence
through tcomp and optimized C. The float loop is dependency-bound and scalar;
these numbers are not a SIMD or transcendental-function benchmark.

## Layout

```
VERSION               the release version, single source of truth
UNLICENSE             public-domain dedication for the whole project
tcomp                 CLI: build / run / --asm / version
tcomp.tl              the compiler, in tlang
tlang-icon.svg/.png   project icon (SVG source and 256px PNG)
CHANGELOG.md          release notes for each version
Bootstrap/            runtime, metadata and the thin CLI driver (Python)
  runtime.py elf.py driver.py cli.py errors.py kindrules_gen.py
  builtin_spec.py     builtin metadata source
  builtins_gen.py     generated builtin tables and IDs
Runtime/              generated modules imported by tcomp.tl
  runtime_gen.tl      assembly runtime, generated from Bootstrap/runtime.py
  kinds_gen.tl        kind-compatibility rule, generated by Tools/gen_kinds.py
  builtins_gen.tl     builtin name -> ID mapping for the self-hosted compiler
  builtins_dispatch_gen.tl  plain builtin dispatch and runtime emission
  version_gen.tl      TLANG_VERSION, generated from VERSION by gen_version.py
Tools/selfhost.sh     thin wrapper around Tools/selfhost.py
Tools/selfhost.py     shared bootstrap, link and fixed-point verifier
Tools/gen_runtime.py  generate Runtime/runtime_gen.tl
Tools/gen_kinds.py    generate the tlang kind rule
Tools/gen_builtins.py generate builtin tables and plain-builtin dispatch
Tools/gen_version.py  generate the tlang version constant from VERSION
Tools/ctolang.py      C -> tlang translator
Tests/version_test.py tlang/tcomp version contract
Tests/run_tests.py    golden-output suite
Tests/programs_test.py  behavioural tests for Programs/
Tests/c_test.py       C -> tlang translation tests, checked against gcc
Tests/chip8_test.py   CHIP-8 frames against a Python reference
Tests/fixedpoint.py   self-hosting stages, byte comparison and golden suite
Tests/builtins_test.py builtin metadata and dependency contract
Tests/runtime_test.py runtime dependency closure and assembly
Tests/freestanding_test.py freestanding build mode and kernel linker script
Tests/machine_builtins_test.py machine builtins and kernel runtime stubs
Tests/env_test.py     environment variable lookup
Tests/portability_test.py  time, entropy and directory builtins
Tests/kernel_test.py  boots the desktop, clicks and types at it, checks the log
Tests/errors_test.py  rejected programs and diagnostics
Tests/sourcemap_test.py imported-file diagnostics name the imported file
Tests/bounds_test.py  checked indexing and runtime safety guards
Tests/io_test.py      file output and self-hosted dependency checks
Tests/modules_test.py recursive import behaviour
Tests/stdlib_test.py  JSON and ZIP modules against Python's json and zipfile
Tests/wayland_test.py twayland keyboard/pointer events against a fake compositor
Tests/floats_test.py  floating-point behaviour
Tests/gameboy_test.py Game Boy CPU and PPU parity
Benchmarks/float_bench.py  float, integer and C performance comparison
Tests/stress_test.py  generated programs, checked against a Python model
.github/workflows/ci.yml  CI: contracts, compiler suites, fixed point
Tests/C/              the C programs those tests translate
Tests/Wayland/        twayland input program driven by the fake compositor
Examples/             hello, fib, fizzbuzz, primes, guess, words, tchip8-demo.ch8,
                      tgameboy-demo.gb, tgameboy-pong.gb, tgameboy-art.gb,
                      tgameboy-screen.gb
Modules/              twayland, tjson, tzip and tport: importable modules
Programs/             tbox, tjson, tbf, tchip8, tgameboy: real programs, not demos
Programs/tbox.c       hosted C equivalent of tbox, for comparison
taarch64/             user-mode AArch64 interpreter for static binaries
Kernel/               freestanding kernel: main.tl, kruntime.s, font8.s, mbr.s,
                      boot.s, kernel.ld, build.sh
```

---

## Known limitations

* Array indexing is bounds-checked at runtime: a bad index writes
  `tlang: index out of bounds` to stderr and exits with status 134. String
  indices are checked for negatives; their upper bound is open because strings
  carry no length and writing at `strlen(s)` is how a NUL-terminated buffer
  grows. Raw/interior pointer arithmetic and struct fields remain unchecked
  (struct fields are fixed compile-time offsets).
* `alloc` rejects negative or oversized counts, and `slice` rejects ranges
  outside its source string. Out-of-range `argv` returns `""`.
* Strings and arrays are arena-allocated with a 16-byte header (capacity and
  length). `free` recycles a block through size-class free lists and `realloc`
  resizes it; `arena_mark()`/`arena_release(mark)` rewind in bulk. A double free
  or an interior pointer is undefined; `free` only rejects values outside the
  arena. The 64 MB arena exits with a message when exhausted.
* `read_file` reads the whole file into the arena rather than streaming, so a
  program that slurps many large files can exhaust it.
* `read_file` returns a NUL-terminated string, so `len()` stops at the first
  zero byte. Use `file_size()` for the real length when indexing binary data
  (as `tchip8` does for ROMs).
* `write_file` and `append_file` write NUL-terminated text only; use
  `fd_write` for binary data.
* `tcp_connect`/`tcp_listen`/`tcp_accept` are blocking stream sockets over a
  numeric `a.b.c.d` address parsed by the runtime: there is no resolver, IPv6,
  UDP or TLS. Addresses must be four non-empty decimal octets of at most three
  digits each, and ports must be 1–65535; out-of-range values return `-1` instead of being truncated, and
  `tcp_listen` does not set `SO_REUSEADDR`. `mmap` is anonymous and private
  only — no file-backed mapping or sharing — and takes lengths in bytes, while
  `munmap`/`mprotect` require page-aligned addresses. `mmap` returns `0` on
  failure rather than a negative errno.
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
* A `const` holds an int or string literal only: there are no const
  expressions and no const arrays. A `\xNN` string is the byte-table form.
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
* `Modules/tjson.tl` handles up to 50,000 values, 200,000 child links and 200
  levels of nesting. `tbf` handles a 30,000-cell tape. These limits are `let`
  constants at the top of the file. `json_pointer` follows RFC 6901, but tlang
  strings are NUL-terminated, so a pointer or path containing U+0000 cannot
  address a member, and URI-fragment percent-encoding is not decoded.
  Duplicate object names are preserved but lookup selects the first member;
  RFC 6901 leaves duplicate-name behavior undefined.
* Building JSON shares the same 50,000-node and 200,000-link limits. Updates
  return the node to keep and may extend in place or allocate a copy; direct
  and indirect cycles are rejected. A value subtree deeper than 200 levels is
  rejected, but total built depth is not otherwise checked, and `json_parse`
  resets every node. Set/remove act on the first duplicate name.
* `Modules/tport.tl` treats paths as bytes and does not normalise `..` or
  repeated slashes. `port_which` accepts any regular file with an executable
  bit; it does not apply `access(2)` or group/other identity checks.
  `port_run` inherits stdio and the environment but does not capture output.
  `port_copy` rejects directories and other non-regular sources and checks the
  copied byte count against the source size. `port_stdin` and `port_copy` use
  the 64 MB arena, so very large inputs are still bounded by it, and
  `port_remove` removes only a file or an empty directory.
* `Modules/tzip.tl` writes stored (method 0) or DEFLATE (fixed Huffman with a
  bounded greedy 32K-window LZ77 search) entries, choosing the smaller form,
  with a fixed 1980-01-01 timestamp and UTF-8 names. Reading supports stored
  and deflated entries with fixed or dynamic Huffman blocks; ZIP64, encryption,
  split archives and methods other than 0 and 8 are rejected. Archives are
  limited to 256 entries and 4 GiB per entry, and the whole file is read into
  memory because `read_file` does not stream.
* Integer division by zero raises SIGFPE.
* At most 6 function parameters.
* Type tracking is syntactic. A return without a `-> type` annotation is
  inferred from the first return that can be typed, using parameter, local and
  global annotations: literals, `str()`/`len()`/`int()`/`float()`, struct
  constructors, and array literals whose elements share one kind. That makes
  `str(f())`, `f().field` and `for x in f()` work without an annotation.
  A prescan also records the return annotations of later functions and infers
  literal returns, so a forward call used in a concat gets its type; recursive
  functions and calls whose return depends on other calls stay untyped. A mixed
  array literal has no element kind.
* The compiler emits straight from the parse with no IR, using a ten-line
  peephole. Its output is trimmed the same way after linking.
* Kinds are checked at call sites, returns and builtin arguments, but not
  through arithmetic: adding a struct to an integer is not rejected, struct
  constructor fields are not checked, and unannotated values are trusted.
* The self-hosted compiler uses fixed tables: 60,000 tokens, 20,000 symbols,
  20,000 string literals, 4,000 functions, 1,000 structs, 256 locals and 512
  frame slots per function, and 500 nested loops. Exceeding a limit is a
  diagnostic, not memory corruption. Imports are
  expanded into a 4 MB source buffer, and a larger expansion is an error.
* Linux x86-64 only. The freestanding kernel boots under QEMU but is early: a
  1280x1024x32 VBE desktop with six apps and a persistent filesystem, a polled
  mouse and keyboard, COM1 output, a bump allocator over a fixed 1 MiB arena, an
  identity map of the first GiB plus the top quarter, no interrupts, and no user
  mode (K2 onwards). Every app runs in ring 0 inside the one address space, and
  a buffer's address has to be coerced with `| 0` to reach a machine builtin,
  because a buffer is not accepted where an integer is wanted.

---

## License

This project is released into the public domain under the
[Unlicense](UNLICENSE). You can use, modify, and redistribute it for any
purpose, with no warranty.

---

## Contributing

The compiler is self-hosting: the language lives in `tcomp.tl`, and the fixed
point must still hold. Language changes usually need a matching metadata change
in `Bootstrap/builtin_spec.py` or `Bootstrap/runtime.py`:

```bash
python3 Tests/version_test.py    # the version contract must hold
python3 Tests/run_tests.py
Tools/selfhost.sh --verify       # stage 2 and stage 3 must be byte-identical
```

The generated modules are checked in. After changing the runtime, the kind
rule, builtin metadata or `VERSION`, rerun `Tools/gen_runtime.py`,
`Tools/gen_kinds.py`, `Tools/gen_builtins.py` and `Tools/gen_version.py`;
`selfhost.sh` refuses to build from stale generated files. A version bump
edits `VERSION` and the changelog, regenerates `Runtime/version_gen.tl`, and
rebuilds `Tools/tcomp-seed` from `tcomp.tl` so stage 1 reports the release
version. Then rerun `Tools/selfhost.sh --verify`.

Keep changes scoped, run the checks that cover them, and update this README when
a size, timing or test count changes. `taarch64` is built separately; its qemu
comparison recipe lives in [`taarch64/README.md`](taarch64/README.md).
