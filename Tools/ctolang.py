#!/usr/bin/env python3
"""ctolang — translate a subset of C into tlang source.

    python3 Tools/ctolang.py hello.c            # tlang on stdout
    python3 Tools/ctolang.py hello.c -o hello.tl

This is not a C compiler. It rewrites the part of C that tlang can express
directly into tlang, so existing C programs can be rebuilt by tcomp into
binaries a fraction of the size gcc produces — and so C code has a migration
path that does not start from a blank file.

Supported
  * `int`, `long`, `char`, `float` / `double`, `char *`, `struct X *`,
    one-dimensional arrays, and pointer arithmetic
  * functions, recursion, globals, `main(int argc, char **argv)`
  * `if` / `else` / `while` / `for` / `do` / `switch` / `break` / `continue`
  * `return`, the `+=` family, `++` / `--` (prefix and postfix), `?:`
  * the full C operator set, including bitwise and shifts
  * `printf` / `puts` / `putchar` / `getchar`, `strlen` / `strcmp` / `strcpy` /
    `atoi` / `abs` / `sqrt` / `fabs` / `isdigit` / `isalpha` / `isspace` /
    `toupper` / `tolower`
  * `malloc` / `calloc` (arena allocation) and `free` (a no-op)
  * `struct`, `enum`, object-like `#define`, `#include` (ignored)

Layout policy
  * C object layout is not reproduced.  `sizeof` is accepted only as an
    element size in `malloc`/`calloc` (`malloc(n * sizeof(int))`,
    `calloc(n, sizeof(int))`, `malloc(sizeof(struct S))`), where it becomes
    tlang slot allocation.  Ordinary `sizeof` expressions and
    `sizeof(char)`/`sizeof(float)` allocations are refused rather than
    silently using the wrong size.

Rejected loudly rather than mistranslated
  * pointer arithmetic outside the supported one-level model, pointers to
    pointers other than `char **argv`, function pointers, address-of,
    `sizeof` outside an allocation size
  * `switch` fallthrough, `goto`, `union`, `typedef`
  * more than six parameters (tlang passes arguments in registers)
  * positional `printf` formats such as `%5d` or `%.2s`
  * string literals holding bytes a tlang string cannot represent

Typed pointer arithmetic becomes tlang pointer arithmetic; `char *` arithmetic
becomes `str_offset` / `str_diff`. Anything that cannot be preserved exactly
is refused. A silent semantic change is worse than an error: `s == t` on two
`char *` compares pointers in C and contents in tlang, so it is rejected with
a suggestion to use `strcmp`.
"""

import os
import re
import sys

INT = ("int",)
CHAR = ("char",)
STR = ("str",)
FLOAT = ("float",)
VOID = ("void",)
CHARPP = ("charpp",)


def struct_t(name):
    return ("struct", name)


def arr_t(elem, length=None):
    return ("arr", elem, length)


def ptr_t(elem):
    return ("ptr", elem)


class Unsupported(Exception):
    pass


def fail(msg, tok=None):
    if tok is not None and getattr(tok, "line", 0):
        raise Unsupported(f"line {tok.line}: {msg}")
    raise Unsupported(msg)


# ---------------------------------------------------------------- lexer

PUNCT = [
    "<<=", ">>=", "->", "++", "--", "&&", "||", "<=", ">=", "==", "!=",
    "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<", ">>",
    "+", "-", "*", "/", "%", "&", "|", "^", "~", "!", "<", ">", "=", "?",
    ":", ";", ",", ".", "(", ")", "[", "]", "{", "}",
]

ESCAPES = {
    "n": 10, "t": 9, "r": 13, "0": 0, "a": 7, "b": 8, "f": 12, "v": 11,
    "\\": 92, "'": 39, '"': 34, "?": 63,
}


class Tok:
    __slots__ = ("kind", "text", "value", "line")

    def __init__(self, kind, text, line, value=None):
        self.kind = kind
        self.text = text
        self.value = value
        self.line = line

    def __repr__(self):
        return f"Tok({self.kind}, {self.text!r})"


def isalpha_(ch):
    return ch.isalpha() or ch == "_"


def isalnum_(ch):
    return ch.isalnum() or ch == "_"


class Lexer:
    def __init__(self, src):
        self.src = src
        self.i = 0
        self.n = len(src)
        self.line = 1
        self.toks = []

    def peek(self, k=0):
        # A sentinel rather than "": `"" in "abc"` is True in Python, so an
        # empty string at EOF would make every `in` test succeed and spin.
        j = self.i + k
        return self.src[j] if j < self.n else "\0"

    def advance(self, count=1):
        first = ""
        for _ in range(count):
            if self.i < self.n:
                ch = self.src[self.i]
                if ch == "\n":
                    self.line += 1
                self.i += 1
                if not first:
                    first = ch
        return first

    def push(self, kind, text, value=None):
        self.toks.append(Tok(kind, text, self.line, value))

    def lex(self):
        while self.i < self.n:
            ch = self.peek()
            if ch in " \t\r\n":
                self.advance()
                continue
            if ch == "/" and self.peek(1) == "/":
                while self.i < self.n and self.peek() != "\n":
                    self.advance()
                continue
            if ch == "/" and self.peek(1) == "*":
                self.advance(2)
                while self.i < self.n and not (self.peek() == "*"
                                               and self.peek(1) == "/"):
                    self.advance()
                self.advance(2)
                continue
            if ch.isdigit():
                self.lex_number()
                continue
            if ch == "." and self.peek(1).isdigit():
                self.lex_float()
                continue
            if isalpha_(ch):
                start = self.i
                while self.i < self.n and isalnum_(self.peek()):
                    self.advance()
                self.push("id", self.src[start:self.i])
                continue
            if ch == '"':
                self.lex_string()
                continue
            if ch == "'":
                self.lex_char()
                continue
            for p in PUNCT:
                if self.src.startswith(p, self.i):
                    self.push("punct", p)
                    self.advance(len(p))
                    break
            else:
                fail(f"cannot lex {ch!r}", Tok("punct", ch, self.line))
        self.push("eof", "")
        return self.toks

    def lex_number(self):
        start = self.i
        line = self.line
        if self.peek() == "0" and self.peek(1) in "xX":
            self.advance(2)
            while self.peek() and (self.peek().isdigit()
                                   or self.peek().lower() in "abcdef"):
                self.advance()
            text = self.src[start:self.i]
            value = int(text, 16)
        elif self.peek() == "0" and self.peek(1) in "bB":
            self.advance(2)                # a gcc extension, and gcc is the referee
            while self.peek() in "01":
                self.advance()
            text = self.src[start:self.i]
            value = int(text[2:], 2)
        elif self.peek() == "0" and self.peek(1).isdigit():
            self.advance()
            while self.peek().isdigit():
                self.advance()
            text = self.src[start:self.i]
            value = int(text, 8)          # 0755 is octal in C
        else:
            while self.peek().isdigit():
                self.advance()
            if self.peek() == "." or self.peek() in "eE":
                if self.peek() == ".":
                    self.advance()
                    while self.peek().isdigit():
                        self.advance()
                if self.peek() in "eE":
                    self.advance()
                    if self.peek() in "+-":
                        self.advance()
                    while self.peek().isdigit():
                        self.advance()
                if self.peek() in "fFlL":
                    self.advance()
                text = self.src[start:self.i]
                if text and text[-1] in "fFlL":
                    text = text[:-1]
                if text.endswith("."):
                    text += "0"
                self.toks.append(Tok("float", text, line, text))
                return
            text = self.src[start:self.i]
            value = int(text)
        while self.peek() in "uUlL":       # suffixes carry no meaning here
            self.advance()
        self.toks.append(Tok("num", text, line, value))

    def lex_float(self):
        start = self.i
        line = self.line
        while self.peek().isdigit():
            self.advance()
        if self.peek() == ".":
            self.advance()
            while self.peek().isdigit():
                self.advance()
        if self.peek() in "eE":
            self.advance()
            if self.peek() in "+-":
                self.advance()
            while self.peek().isdigit():
                self.advance()
        if self.peek() in "fFlL":
            self.advance()
        text = self.src[start:self.i]
        if text and text[-1] in "fFlL":
            text = text[:-1]
        if text.startswith("."):
            text = "0" + text
        if text.endswith("."):
            text += "0"
        self.toks.append(Tok("float", text, line, text))

    def read_escape(self):
        ch = self.advance() or ""
        if ch == "\\":
            esc = self.advance() or ""
            if esc in ESCAPES:
                return ESCAPES[esc]
            if esc == "x":
                hexed = ""
                while self.peek() and self.peek().lower() in "0123456789abcdef":
                    hexed += self.advance()
                if not hexed:
                    fail("bad \\x escape", Tok("str", "", self.line))
                return int(hexed, 16) & 255
            if esc.isdigit():
                octed = esc
                while len(octed) < 3 and self.peek() in "01234567":
                    octed += self.advance()
                return int(octed, 8) & 255
            fail(f"unknown escape \\{esc}", Tok("str", "", self.line))
        return ord(ch) & 255

    def lex_string(self):
        line = self.line
        data = bytearray()
        self.advance()                     # opening quote
        while True:
            if self.i >= self.n:
                fail("unterminated string", Tok("str", "", line))
            if self.peek() == '"':
                self.advance()
                break
            data.append(self.read_escape())
        while True:                        # "abc" "def" is one literal in C
            save_i, save_line = self.i, self.line
            while self.peek() in " \t\r\n":
                self.advance()
            if self.peek() == '"':
                self.advance()
                while True:
                    if self.i >= self.n:
                        fail("unterminated string", Tok("str", "", line))
                    if self.peek() == '"':
                        self.advance()
                        break
                    data.append(self.read_escape())
                continue
            self.i, self.line = save_i, save_line
            break
        self.toks.append(Tok("str", "<string>", line, bytes(data)))

    def lex_char(self):
        line = self.line
        self.advance()
        if self.i >= self.n:
            fail("unterminated character literal", Tok("str", "", line))
        value = self.read_escape()
        if self.peek() != "'":
            fail("multi-character literal", Tok("str", "", line))
        self.advance()
        self.toks.append(Tok("chr", "<char>", line, value))


# ------------------------------------------------------- preprocessor (tiny)

def preprocess(src):
    """Drop `#include`, record object-like `#define`, refuse everything else."""
    macros = {}
    lines = []
    for line in src.split("\n"):
        stripped = line.strip()
        if stripped.startswith("#"):
            define = re.match(r"#\s*define\s+([A-Za-z_]\w*)\s+(.+)$", stripped)
            if define:
                macros[define.group(1)] = define.group(2).strip()
                lines.append("")
                continue
            if re.match(r"#\s*include\b", stripped):
                lines.append("")
                continue
            if stripped.startswith("#!"):
                lines.append("")
                continue
            fail(f"preprocessor directive not supported: {stripped}", None)
        lines.append(line)
    return "\n".join(lines), macros


def expand_macros(toks, macros):
    if not macros:
        return toks
    out = []
    for tok in toks:
        if tok.kind == "id" and tok.text in macros:
            expansion = macros[tok.text]
            if expansion in macros:
                fail(f"recursive #define {tok.text}", tok)
            sub = Lexer(expansion).lex()
            for item in sub:
                if item.kind == "eof":
                    break
                out.append(Tok(item.kind, item.text, tok.line, item.value))
            continue
        out.append(tok)
    return out


# ---------------------------------------------------------------- ast

class Node:
    """A generic node: Node("bin", tok, op=..., left=..., right=...)."""

    def __init__(self, kind, tok=None, **fields):
        self.kind = kind
        self.tok = tok
        self.__dict__.update(fields)

    def __repr__(self):
        return f"Node({self.kind})"


TYPE_WORDS = {
    "void", "char", "int", "long", "short", "unsigned", "signed", "const",
    "static", "volatile", "register", "struct", "enum", "typedef", "float",
    "double", "_Bool", "union", "extern",
}

BIN_LEVELS = [
    ["||"],
    ["&&"],
    ["|"],
    ["^"],
    ["&"],
    ["==", "!="],
    ["<", "<=", ">", ">="],
    ["<<", ">>"],
    ["+", "-"],
    ["*", "/", "%"],
]

ASSIGN_OPS = {"=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="}


class Parser:
    def __init__(self, toks):
        self.toks = toks
        self.pos = 0
        self.enums = {}          # enumerator name -> value, for case labels

    @property
    def tok(self):
        return self.toks[self.pos]

    def peek(self, k=1):
        j = self.pos + k
        return self.toks[j] if j < len(self.toks) else self.toks[-1]

    def at(self, text):
        return self.tok.text == text and self.tok.kind in ("punct", "id")

    def advance(self):
        tok = self.tok
        if tok.kind != "eof":
            self.pos += 1
        return tok

    def expect(self, text):
        if not self.at(text):
            fail(f"expected {text!r}, found {self.tok.text!r}", self.tok)
        return self.advance()

    def accept(self, text):
        return self.advance() if self.at(text) else None

    # -- types ------------------------------------------------------------
    def is_type_start(self, tok=None):
        tok = tok or self.tok
        return tok.kind == "id" and tok.text in TYPE_WORDS

    def parse_declspec(self):
        words = []
        while self.tok.kind == "id" and self.tok.text in TYPE_WORDS:
            words.append(self.advance().text)
        if not words:
            fail(f"expected a type, found {self.tok.text!r}", self.tok)
        if "struct" in words:
            tag = self.advance()
            if tag.kind != "id":
                fail("expected a struct tag", tag)
            return struct_t(tag.text)
        if "enum" in words:
            if self.tok.kind == "id":
                self.advance()
            return INT
        if "float" in words or "double" in words:
            return FLOAT
        if "union" in words:
            fail("tlang has no unions", self.tok)
        if "typedef" in words:
            fail("typedef is not supported", self.tok)
        if "char" in words:
            return CHAR
        if "void" in words:
            return VOID
        return INT

    def parse_declarator(self, base):
        """Stars, name and an array suffix -> (name, ctype)."""
        stars = 0
        while self.accept("*"):
            stars += 1
        if self.at("("):
            fail("function pointers are not supported", self.tok)
        name_tok = self.advance()
        if name_tok.kind != "id":
            fail(f"expected a name, found {name_tok.text!r}", name_tok)
        dims = []
        while self.accept("["):
            length = None
            if not self.at("]"):
                length = self.constant_of(self.parse_assignment())
                if length is None:
                    fail(f"array size of '{name_tok.text}' must be constant",
                         name_tok)
            self.expect("]")
            dims.append(length)
        if len(dims) > 1:
            fail("only one array dimension is supported", name_tok)

        ctype = base
        if stars == 1:
            if base == CHAR:
                ctype = STR
            elif base[0] == "struct":
                ctype = base        # a tlang struct value already is a pointer
            elif base == INT:
                ctype = ptr_t(INT)
            elif base == FLOAT:
                ctype = ptr_t(FLOAT)
            elif base == VOID:
                ctype = ptr_t(VOID)
            else:
                fail("this pointer type is not supported", name_tok)
        elif stars == 2 and base == CHAR:
            ctype = CHARPP
        elif stars:
            fail("pointers deeper than one level are not supported", name_tok)
        if dims:
            ctype = arr_t(ctype, dims[0])
        return name_tok.text, ctype

    CONSTANT_BIN = {
        "+": lambda a, b: a + b, "-": lambda a, b: a - b,
        "*": lambda a, b: a * b,
        "/": lambda a, b: int(a / b) if b else None,
        "%": lambda a, b: a - int(a / b) * b if b else None,
        "<<": lambda a, b: a << b, ">>": lambda a, b: a >> b,
        "&": lambda a, b: a & b, "|": lambda a, b: a | b,
        "^": lambda a, b: a ^ b,
    }

    def constant_of(self, node):
        if node.kind == "num":
            return node.value
        if node.kind == "id":
            return self.enums.get(node.name)
        if node.kind == "un":
            inner = self.constant_of(node.operand)
            if inner is None:
                return None
            if node.op == "-":
                return -inner
            if node.op == "+":
                return inner
            if node.op == "~":
                return ~inner
            if node.op == "!":
                return 0 if inner else 1
            return None
        if node.kind == "bin" and node.op in self.CONSTANT_BIN:
            left = self.constant_of(node.left)
            right = self.constant_of(node.right)
            if left is None or right is None:
                return None
            return self.CONSTANT_BIN[node.op](left, right)
        return None

    # -- top level --------------------------------------------------------
    def parse_unit(self):
        decls = []
        while self.tok.kind != "eof":
            if self.accept(";"):
                continue
            if self.at("struct") and self.peek().kind == "id" \
                    and self.peek(2).text == "{":
                decls.append(self.parse_struct())
                continue
            if self.at("enum"):
                decls.append(self.parse_enum())
                continue
            base = self.parse_declspec()
            if self.accept(";"):                 # `struct X;`
                continue
            name, ctype = self.parse_declarator(base)
            if self.at("("):
                decls.append(self.parse_function(name, ctype))
                continue
            decls.extend(self.parse_global_rest(base, name, ctype))
        return decls

    def parse_struct(self):
        tok = self.expect("struct")
        tag = self.advance()
        if tag.kind != "id":
            fail("expected a struct tag", tag)
        self.expect("{")
        fields = []
        while not self.at("}"):
            if self.tok.kind == "eof":
                fail("unterminated struct", tok)
            base = self.parse_declspec()
            while True:
                name, ctype = self.parse_declarator(base)
                if ctype[0] == "arr":
                    fail(f"array field '{name}' is not supported", tok)
                fields.append((name, ctype))
                if not self.accept(","):
                    break
            self.expect(";")
        self.expect("}")
        self.accept(";")
        return Node("struct", tok, name=tag.text, fields=fields)

    def parse_enum(self):
        tok = self.expect("enum")
        if self.tok.kind == "id":
            self.advance()
        self.expect("{")
        values = []
        nxt = 0
        while not self.at("}"):
            name = self.advance()
            if name.kind != "id":
                fail("expected an enumerator", name)
            if self.accept("="):
                value = self.constant_of(self.parse_assignment())
                if value is None:
                    fail("enumerator values must be constant", name)
                nxt = value
            values.append((name.text, nxt))
            self.enums[name.text] = nxt
            nxt += 1
            if not self.accept(","):
                break
        self.expect("}")
        self.accept(";")
        return Node("enum", tok, values=values)

    def parse_global_rest(self, base, name, ctype):
        decls = [Node("global", None, name=name, ctype=ctype,
                      init=self.parse_init_opt())]
        while self.accept(","):
            more_name, more_type = self.parse_declarator(base)
            decls.append(Node("global", None, name=more_name, ctype=more_type,
                              init=self.parse_init_opt()))
        self.expect(";")
        return decls

    def parse_init_opt(self):
        return self.parse_initializer() if self.accept("=") else None

    def parse_initializer(self):
        if self.accept("{"):
            items = []
            while not self.at("}"):
                items.append(self.parse_initializer())
                if not self.accept(","):
                    break
            self.expect("}")
            return Node("init_list", None, items=items)
        return self.parse_assignment()

    def parse_function(self, name, ret):
        self.expect("(")
        params = []
        if not self.at(")"):
            if self.at("void") and self.peek().text == ")":
                self.advance()
            else:
                while True:
                    base = self.parse_declspec()
                    pname, ptype = self.parse_declarator(base)
                    params.append((pname, ptype))
                    if not self.accept(","):
                        break
        self.expect(")")
        if self.accept(";"):
            return Node("proto", None, name=name, ret=ret, params=params)
        if len(params) > 6:
            fail(f"'{name}' has {len(params)} parameters; tlang allows 6", self.tok)
        body = self.parse_block()
        return Node("func", None, name=name, ret=ret, params=params, body=body)

    # -- statements -------------------------------------------------------
    def parse_block(self):
        tok = self.expect("{")
        stmts = []
        while not self.at("}"):
            if self.tok.kind == "eof":
                fail("unterminated block", tok)
            stmts.append(self.parse_statement())
        self.expect("}")
        return Node("block", tok, stmts=stmts)

    def parse_statement(self):
        tok = self.tok
        if self.at("{"):
            return self.parse_block()
        if self.at(";"):
            self.advance()
            return Node("empty", tok)
        if tok.kind == "id":
            word = tok.text
            if word == "if":
                self.advance()
                self.expect("(")
                cond = self.parse_expression()
                self.expect(")")
                then = self.parse_statement()
                els = None
                if self.at("else"):
                    self.advance()
                    els = self.parse_statement()
                return Node("if", tok, cond=cond, then=then, els=els)
            if word == "while":
                self.advance()
                self.expect("(")
                cond = self.parse_expression()
                self.expect(")")
                return Node("while", tok, cond=cond, body=self.parse_statement())
            if word == "do":
                self.advance()
                body = self.parse_statement()
                self.expect("while")
                self.expect("(")
                cond = self.parse_expression()
                self.expect(")")
                self.expect(";")
                return Node("do", tok, cond=cond, body=body)
            if word == "for":
                return self.parse_for()
            if word == "switch":
                self.advance()
                self.expect("(")
                subject = self.parse_expression()
                self.expect(")")
                return Node("switch", tok, subject=subject,
                            cases=self.parse_switch_body())
            if word == "case":
                fail("'case' outside a switch", tok)
            if word == "default":
                fail("'default' outside a switch", tok)
            if word == "break":
                self.advance()
                self.expect(";")
                return Node("break", tok)
            if word == "continue":
                self.advance()
                self.expect(";")
                return Node("continue", tok)
            if word == "return":
                self.advance()
                value = None
                if not self.at(";"):
                    value = self.parse_expression()
                self.expect(";")
                return Node("return", tok, value=value)
            if word == "goto":
                fail("goto is not supported", tok)
            if self.is_type_start():
                return self.parse_local_decl()
        expr = self.parse_expression()
        self.expect(";")
        return Node("expr", tok, value=expr)

    def parse_switch_body(self):
        tok = self.expect("{")
        cases = []
        current = None
        while not self.at("}"):
            if self.tok.kind == "eof":
                fail("unterminated switch", tok)
            if self.at("case"):
                case_tok = self.advance()
                value = self.constant_of(self.parse_conditional())
                if value is None:
                    fail("case labels must be constant", case_tok)
                self.expect(":")
                current = [value, []]
                cases.append(current)
                continue
            if self.at("default"):
                self.advance()
                self.expect(":")
                current = [None, []]
                cases.append(current)
                continue
            if current is None:
                fail("statement before the first case label", self.tok)
            current[1].append(self.parse_statement())
        self.expect("}")
        if not cases:
            fail("switch with no cases", tok)
        return [(value, body) for value, body in cases]

    def parse_for(self):
        tok = self.expect("for")
        self.expect("(")
        if self.accept(";"):
            init = None
        elif self.is_type_start():
            init = self.parse_local_decl()
        else:
            init = Node("expr", tok, value=self.parse_expression())
            self.expect(";")
        cond = None
        if not self.at(";"):
            cond = self.parse_expression()
        self.expect(";")
        step = None
        if not self.at(")"):
            step = self.parse_expression()
        self.expect(")")
        body = self.parse_statement()
        return Node("for", tok, init=init, cond=cond, step=step, body=body)

    def parse_local_decl(self):
        base = self.parse_declspec()
        items = []
        while True:
            name, ctype = self.parse_declarator(base)
            init = self.parse_init_opt()
            items.append((name, ctype, init))
            if not self.accept(","):
                break
        self.expect(";")
        return Node("decl", None, items=items)

    # -- expressions ------------------------------------------------------
    def parse_expression(self):
        node = self.parse_assignment()
        while self.at(","):
            tok = self.advance()
            node = Node("comma", tok, left=node, right=self.parse_assignment())
        return node

    def parse_assignment(self):
        left = self.parse_conditional()
        if self.tok.kind == "punct" and self.tok.text in ASSIGN_OPS:
            tok = self.advance()
            return Node("assign", tok, op=tok.text, target=left,
                        value=self.parse_assignment())
        return left

    def parse_conditional(self):
        cond = self.parse_binary(0)
        if self.at("?"):
            tok = self.advance()
            then = self.parse_expression()
            self.expect(":")
            return Node("ternary", tok, cond=cond, then=then,
                        els=self.parse_conditional())
        return cond

    def parse_binary(self, level):
        if level == len(BIN_LEVELS):
            return self.parse_unary()
        left = self.parse_binary(level + 1)
        while self.tok.kind == "punct" and self.tok.text in BIN_LEVELS[level]:
            tok = self.advance()
            left = Node("bin", tok, op=tok.text, left=left,
                        right=self.parse_binary(level + 1))
        return left

    def parse_unary(self):
        tok = self.tok
        if tok.kind == "punct" and tok.text in ("!", "~", "-", "+", "*", "&"):
            self.advance()
            return Node("un", tok, op=tok.text, operand=self.parse_unary())
        if tok.kind == "punct" and tok.text in ("++", "--"):
            self.advance()
            return Node("preinc", tok, op=tok.text,
                        operand=self.parse_unary())
        if tok.kind == "id" and tok.text == "sizeof":
            self.advance()
            if self.at("(") and self.is_type_start(self.peek()):
                self.advance()
                base = self.parse_declspec()
                while self.accept("*"):
                    base = ptr_t(base)
                self.expect(")")
                return Node("sizeof_type", tok, ctype=base)
            return Node("sizeof_expr", tok, operand=self.parse_unary())
        if self.at("(") and self.is_type_start(self.peek()):
            self.advance()
            base = self.parse_declspec()
            stars = 0
            while self.accept("*"):
                stars += 1
            self.expect(")")
            inner = self.parse_unary()
            if stars:
                fail("pointer casts are not supported", tok)
            return Node("cast", tok, ctype=base, operand=inner)
        return self.parse_postfix()

    def parse_postfix(self):
        node = self.parse_primary()
        while True:
            if self.at("["):
                tok = self.advance()
                index = self.parse_expression()
                self.expect("]")
                node = Node("index", tok, base=node, index=index)
            elif self.at("("):
                tok = self.advance()
                args = []
                if not self.at(")"):
                    while True:
                        args.append(self.parse_assignment())
                        if not self.accept(","):
                            break
                self.expect(")")
                node = Node("call", tok, callee=node, args=args)
            elif self.at(".") or self.at("->"):
                tok = self.advance()
                name = self.advance()
                if name.kind != "id":
                    fail("expected a field name", name)
                node = Node("field", tok, base=node, name=name.text)
            elif self.tok.kind == "punct" and self.tok.text in ("++", "--"):
                tok = self.advance()
                node = Node("postinc", tok, op=tok.text, operand=node)
            else:
                return node

    def parse_primary(self):
        tok = self.tok
        if tok.kind == "num":
            self.advance()
            return Node("num", tok, value=tok.value)
        if tok.kind == "float":
            self.advance()
            return Node("float", tok, text=tok.text)
        if tok.kind == "chr":
            self.advance()
            return Node("num", tok, value=tok.value)
        if tok.kind == "str":
            self.advance()
            return Node("str", tok, value=tok.value)
        if tok.kind == "id":
            self.advance()
            return Node("id", tok, name=tok.text)
        if tok.kind == "punct" and tok.text == "(":
            self.advance()
            inner = self.parse_expression()
            self.expect(")")
            return inner
        fail(f"expected an expression, found {tok.text!r}", tok)


# ---------------------------------------------------------------- runtime

# Emitted into the tlang output, and only when the program uses them.
HELPER_GLOBALS = {
    "getchar": ['let ct_in = ""', "let ct_pos = 0", "let ct_loaded = 0"],
}

HELPERS = {
    "getchar": """fn ct_getchar() -> int {
  if ct_loaded == 0 {
    ct_in = read_file("/dev/stdin")
    ct_loaded = 1
  }
  if ct_pos >= len(ct_in) {
    return -1
  }
  let c = ct_in[ct_pos]
  ct_pos = ct_pos + 1
  return c
}""",
    "strcmp": """fn ct_strcmp(a: str, b: str) -> int {
  let i = 0
  let na = len(a)
  let nb = len(b)
  while i < na && i < nb {
    let x = a[i]
    let y = b[i]
    if x != y {
      return x - y
    }
    i = i + 1
  }
  return na - nb
}""",
    "strcpy": """fn ct_strcpy(dst: str, src: str) {
  let i = 0
  let n = len(src)
  while i < n {
    dst[i] = src[i]
    i = i + 1
  }
  dst[i] = 0
}""",
    "abs": """fn ct_abs(x: int) -> int {
  if x < 0 {
    return -x
  }
  return x
}""",
    "isdigit": """fn ct_isdigit(c: int) -> int {
  return c >= 48 && c <= 57
}""",
    "isalpha": """fn ct_isalpha(c: int) -> int {
  return (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
}""",
    "isspace": """fn ct_isspace(c: int) -> int {
  return c == 32 || (c >= 9 && c <= 13)
}""",
    "toupper": """fn ct_toupper(c: int) -> int {
  if c >= 97 && c <= 122 {
    return c - 32
  }
  return c
}""",
    "tolower": """fn ct_tolower(c: int) -> int {
  if c >= 65 && c <= 90 {
    return c + 32
  }
  return c
}""",
}

# C name -> (tlang target, result type, required argument type or None)
LIBRARY = {
    "strlen": ("len", INT, "str"),
    "strcmp": ("ct_strcmp", INT, ("str", "str")),
    "strcpy": ("ct_strcpy", INT, ("str", "str")),
    "atoi": ("int", INT, "str"),
    "abs": ("ct_abs", INT, "int"),
    "labs": ("ct_abs", INT, "int"),
    "sqrt": ("sqrt", FLOAT, "float"),
    "fabs": ("fabs", FLOAT, "float"),
    "isdigit": ("ct_isdigit", INT, "int"),
    "isalpha": ("ct_isalpha", INT, "int"),
    "isspace": ("ct_isspace", INT, "int"),
    "toupper": ("ct_toupper", INT, "int"),
    "tolower": ("ct_tolower", INT, "int"),
    "putchar": ("print_char", INT, "int"),
    "getchar": ("ct_getchar", INT, None),
    "exit": ("exit", INT, "int"),
}

# tlang keywords and builtins a C identifier may collide with. `main` is not
# here: it has to keep its name for tcomp to use it as the entry point.
RESERVED = {
    "len", "input", "int", "str", "slice", "alloc", "print", "print_int",
    "print_char", "print_err", "str_eq", "read_file", "exit", "argv", "argc",
    "struct", "fn", "let", "if", "else", "while", "for", "in", "return",
    "break", "continue", "true", "false",
}


def tl_string(data, tok=None):
    """A tlang string literal for `data`."""
    out = ['"']
    for byte in data:
        if byte == 0x22:
            out.append('\\"')
        elif byte == 0x5C:
            out.append("\\\\")
        elif byte == 10:
            out.append("\\n")
        elif byte == 9:
            out.append("\\t")
        elif byte == 13:
            out.append("\\r")
        elif 32 <= byte < 127:
            out.append(chr(byte))
        else:
            fail(f"tlang strings cannot hold byte {byte}; "
                 f"print it with putchar instead", tok)
    out.append('"')
    return "".join(out)


def split_format(data, tok=None):
    """printf format -> [("text", bytes) | ("int",) | ("str",) | ("char",)]."""
    parts = []
    text = bytearray()
    i = 0
    while i < len(data):
        if data[i] != 37:                  # '%'
            text.append(data[i])
            i += 1
            continue
        i += 1
        while i < len(data) and data[i] in b"lLh":
            i += 1
        if i < len(data) and data[i] in b"-+ 0#0123456789.'":
            fail("printf field widths and precision are not supported", tok)
        if i >= len(data):
            fail("printf format ends inside a conversion", tok)
        conv = chr(data[i])
        i += 1
        if conv == "%":
            text.append(37)
            continue
        if conv in "diu":
            kind = "int"
        elif conv == "f":
            kind = "float"
        elif conv == "s":
            kind = "str"
        elif conv == "c":
            kind = "char"
        else:
            fail(f"printf conversion %{conv} is not supported", tok)
        if text:
            parts.append(("text", bytes(text)))
            text = bytearray()
        parts.append((kind,))
    if text:
        parts.append(("text", bytes(text)))
    return parts


# ---------------------------------------------------------------- emitter

class Emitter:
    def __init__(self):
        self.lines = []
        self.indent = 0
        self.scopes = [{}]
        self.globals = {}
        self.structs = {}
        self.func_ret = {}
        self.helpers = set()
        self.loop_stack = []      # per loop: step lines for `continue`, or None
        self.pre = []             # [(extra indent, text)] pending statements
        self.tmpn = 0
        self.argc_argv = False

    # -- output -----------------------------------------------------------
    def line(self, text, indent=None):
        self.lines.append("  " * (self.indent if indent is None else indent) + text)

    def blank(self):
        self.lines.append("")

    def pre_line(self, text, extra=0):
        self.pre.append((extra, text))

    def render(self, pre, base=None):
        base = self.indent if base is None else base
        for extra, text in pre:
            self.lines.append("  " * (base + extra) + text)

    def flush(self):
        if self.pre:
            self.render(self.pre)
            self.pre = []

    def newtmp(self):
        self.tmpn += 1
        return f"ct_t{self.tmpn}"

    def use(self, helper):
        self.helpers.add(helper)

    # -- names and types --------------------------------------------------
    def declare(self, name, ctype):
        self.scopes[-1][self.name_of(name)] = ctype

    def lookup(self, name):
        key = self.name_of(name)
        for scope in reversed(self.scopes):
            if key in scope:
                return scope[key]
        return self.globals.get(key)

    def name_of(self, name):
        """C identifiers that collide with tlang keywords/builtins are renamed."""
        return "ct_" + name if name in RESERVED else name

    def is_string(self, ctype):
        """True for `char *` and for a `char` array, which is a byte buffer."""
        return ctype == STR or (ctype[0] == "arr" and ctype[1] == CHAR)

    def is_pointer_type(self, ctype):
        return ctype[0] in ("arr", "ptr") or ctype[0] == "struct"

    def convert(self, text, ctype, want):
        if want == FLOAT and ctype != FLOAT:
            return f"float({text})"
        if want in (INT, CHAR) and ctype == FLOAT:
            return f"int({text})"
        return text

    def incdec_text(self, place, ctype, op):
        if self.is_string(ctype):
            return f"str_offset({place}, {1 if op == '+' else -1})"
        return f"{place} {op} 1"

    def compound_text(self, place, ctype, op, value):
        if self.is_string(ctype) and op in ("+=", "-="):
            sign = "" if op == "+=" else "-"
            return f"{place} = str_offset({place}, {sign}({value}))"
        if self.is_pointer_type(ctype) and op in ("+=", "-="):
            return f"{place} = {place} {op[0]} ({value})"
        return f"{place} = {place} {op[:-1]} ({value})"

    def annotation(self, ctype):
        if ctype in (INT, CHAR):
            return "int"
        if ctype == FLOAT:
            return "float"
        if ctype == STR:
            return "str"
        if ctype[0] == "struct":
            return ctype[1]
        if ctype[0] == "ptr":
            elem = ctype[1]
            if elem == INT:
                return "int[]"
            if elem == FLOAT:
                return "float[]"
            if elem[0] == "struct":
                return elem[1] + "[]"
            return ""
        if ctype[0] == "arr":
            elem = ctype[1]
            if elem in (CHAR, STR):
                return "str"
            if elem == INT:
                return "int[]"
            if elem == FLOAT:
                return "float[]"
            if elem[0] == "struct":
                return elem[1] + "[]"
        return ""

    # -- program ----------------------------------------------------------
    def program(self, decls):
        structs = [d for d in decls if d.kind == "struct"]
        enums = [d for d in decls if d.kind == "enum"]
        globals_ = [d for d in decls if d.kind == "global"]
        funcs = [d for d in decls if d.kind == "func"]

        for node in structs:
            self.structs[node.name] = node.fields
        for node in globals_:
            self.globals[self.name_of(node.name)] = node.ctype

        head = []
        for node in structs:
            fields = []
            for fname, ftype in node.fields:
                note = self.annotation(ftype)
                tl = self.name_of(fname)
                fields.append(f"{tl}: {note}" if note and note != "int" else tl)
            head.append(f"struct {node.name} {{ {', '.join(fields)} }}")
        if head:
            head.append("")
        for node in enums:
            for name, value in node.values:
                self.globals[self.name_of(name)] = INT
                head.append(f"let {self.name_of(name)} = {value}")
            head.append("")

        self.lines = head
        for node in globals_:
            self.global_var(node)
        if globals_:
            self.blank()

        preamble = self.lines
        body = []
        for node in funcs:
            self.lines = []
            self.function(node)
            body.extend(self.lines)
        self.lines = preamble + body

        if self.helpers:
            self.blank()
            for name in sorted(self.helpers):
                for text in HELPER_GLOBALS.get(name, []):
                    self.line(text)
            self.blank()
            for name in sorted(self.helpers):
                for text in HELPERS[name].split("\n"):
                    self.lines.append(text)
                self.blank()

        text = "\n".join(self.lines).rstrip() + "\n"
        return re.sub(r"\n{3,}", "\n\n", text)

    def global_var(self, node):
        name = self.name_of(node.name)
        if node.ctype[0] == "arr":
            length = node.ctype[2]
            if node.init is not None and node.init.kind == "init_list":
                length = len(node.init.items)
            if length is None:
                fail(f"global array '{node.name}' needs a size")
            self.line(self.array_decl(name, node.ctype[1], length))
            if node.init is not None and node.init.kind == "init_list":
                for index, item in enumerate(node.init.items):
                    text, itype = self.expr(item)
                    self.flush()
                    text = self.convert(text, itype, node.ctype[1])
                    self.line(f"{name}[{index}] = {text}")
                self.blank()
            return
        value = "0.0" if node.ctype == FLOAT else "0"
        if node.init is not None:
            self.pre = []
            value, itype = self.expr(node.init)
            self.flush()
            value = self.convert(value, itype, node.ctype)
        self.line(f"let {name} = {value}")

    def array_decl(self, name, elem, length):
        if elem in (CHAR, STR):
            # A byte buffer: slice() hands back a mutable string of exactly
            # `length` bytes (padded with spaces), so buf[i] reads and writes a
            # byte and strlen works on it.
            return f'let {name} = slice("{(" " * length)}", 0, {length})'
        if elem == FLOAT:
            return f"let {name} = alloc({length}, float)"
        return f"let {name} = alloc({length})"

    # -- functions --------------------------------------------------------
    def function(self, node):
        self.scopes = [{}]
        is_main = node.name == "main"
        params = []
        for pname, ptype in node.params:
            self.declare(pname, ptype)
            note = self.annotation(ptype)
            tl = self.name_of(pname)
            params.append(f"{tl}: {note}" if note else tl)
        self.argc_argv = is_main and len(node.params) == 2
        if self.argc_argv:
            params = []                    # tlang's main takes no parameters
        ret = self.annotation(node.ret)
        head = f"fn {self.name_of(node.name)}({', '.join(params)})"
        if ret and ret != "int":
            head += f" -> {ret}"
        self.line(head + " {")
        self.indent += 1
        if self.argc_argv:
            self.declare(node.params[0][0], INT)
            self.declare(node.params[1][0], CHARPP)
        self.stmts(node.body.stmts)
        self.flush()
        self.indent -= 1
        self.line("}")
        self.blank()

    # -- statements -------------------------------------------------------
    def stmts(self, stmts):
        for stmt in stmts:
            self.stmt(stmt)

    def stmt(self, node):
        self.pre = []
        handler = getattr(self, "stmt_" + node.kind, None)
        if handler is None:
            fail(f"cannot translate statement '{node.kind}'", node.tok)
        handler(node)

    def stmt_empty(self, node):
        pass

    def stmt_block(self, node):
        self.stmts(node.stmts)

    def stmt_in_block(self, node):
        if node.kind == "block":
            self.stmts(node.stmts)
        else:
            self.stmt(node)

    def stmt_expr(self, node):
        self.emit_expr_statement(node.value)

    def emit_expr_statement(self, expr):
        self.pre = []
        if expr.kind in ("postinc", "preinc"):
            self.emit_incdec_stmt(expr)
            self.flush()
            return
        if expr.kind == "assign":
            self.emit_assign_stmt(expr)
            self.flush()
            return
        if expr.kind == "comma":
            self.emit_expr_statement(expr.left)
            self.emit_expr_statement(expr.right)
            return
        text, _ = self.expr(expr)
        self.flush()
        if text:
            self.line(text)

    def place_of(self, node):
        """The assignable text for an lvalue, plus its type."""
        if node.kind == "index":
            base, _ = self.expr(node.base)
            index, _ = self.expr(node.index)
            btype = self.lookup(node.base.name) if node.base.kind == "id" else None
            elem = INT
            if btype is not None:
                if btype[0] == "arr":
                    elem = btype[1]
                elif btype[0] == "ptr":
                    elem = btype[1]
            return f"{base}[{index}]", elem
        text, ctype = self.expr(node)
        return text, ctype

    def emit_incdec_stmt(self, node):
        place, ctype = self.place_of(node.operand)
        op = "+" if node.op == "++" else "-"
        self.flush()
        self.line(f"{place} = {self.incdec_text(place, ctype, op)}")

    def emit_assign_stmt(self, node):
        value, vtype = self.expr(node.value)
        place, ctype = self.place_of(node.target)
        self.flush()
        if node.op == "=":
            value = self.convert(value, vtype, ctype)
            self.line(f"{place} = {value}")
            return
        # `n += x & 1` must become `n = n + (x & 1)`: tlang's `&` binds looser
        # than `+`, so the expansion has to keep the right operand intact.
        self.line(self.compound_text(place, ctype, node.op, value))

    def stmt_decl(self, node):
        for name, ctype, init in node.items:
            self.declare(name, ctype)
            tl = self.name_of(name)
            if ctype[0] == "arr":
                length = ctype[2]
                if init is not None and init.kind == "init_list":
                    length = len(init.items)
                if length is None:
                    fail(f"array '{name}' needs a size or an initializer",
                         node.tok)
                self.line(self.array_decl(tl, ctype[1], length))
                if init is not None and init.kind == "init_list":
                    for index, item in enumerate(init.items):
                        text, itype = self.expr(item)
                        self.flush()
                        text = self.convert(text, itype, ctype[1])
                        self.line(f"{tl}[{index}] = {text}")
                continue
            if ctype[0] == "struct" and (init is None or
                                         (init.kind == "call"
                                          and init.callee.name == "malloc")):
                fields = self.structs.get(ctype[1])
                if fields is None:
                    fail(f"unknown struct type '{ctype[1]}'", node.tok)
                zeros = ", ".join("0" for _ in fields)
                self.line(f"let {tl} = {ctype[1]}({zeros})")
                continue
            if init is None:
                if ctype == STR:
                    self.line(f'let {tl} = ""')
                elif ctype == FLOAT:
                    self.line(f"let {tl} = 0.0")
                else:
                    self.line(f"let {tl} = 0")
                continue
            text, itype = self.expr(init)
            self.flush()
            text = self.convert(text, itype, ctype)
            self.line(f"let {tl} = {text}")

    def stmt_if(self, node):
        cond, _ = self.expr(node.cond)
        self.flush()
        self.line(f"if {cond} {{")
        self.indent += 1
        self.stmt_in_block(node.then)
        self.indent -= 1
        els = node.els
        while els is not None and els.kind == "if":
            cond, _ = self.expr(els.cond)
            self.flush()
            self.line(f"}} else if {cond} {{")
            self.indent += 1
            self.stmt_in_block(els.then)
            self.indent -= 1
            els = els.els
        if els is not None:
            self.line("} else {")
            self.indent += 1
            self.stmt_in_block(els)
            self.indent -= 1
        self.line("}")

    def stmt_while(self, node):
        cond, _ = self.expr(node.cond)
        pre = self.pre
        self.pre = []
        if pre:
            # A condition that needs statements (an assignment or ?:) has to
            # run them inside the loop, once per test.
            self.line("while 1 {")
            self.indent += 1
            self.loop_stack.append(None)
            self.render(pre)
            self.line(f"if !({cond}) {{")
            self.indent += 1
            self.line("break")
            self.indent -= 1
            self.line("}")
            self.stmt_in_block(node.body)
            self.loop_stack.pop()
            self.indent -= 1
            self.line("}")
            return
        self.line(f"while {cond} {{")
        self.indent += 1
        self.loop_stack.append(None)
        self.stmt_in_block(node.body)
        self.loop_stack.pop()
        self.indent -= 1
        self.line("}")

    def stmt_do(self, node):
        self.line("while 1 {")
        self.indent += 1
        self.loop_stack.append(None)
        self.stmt_in_block(node.body)
        cond, _ = self.expr(node.cond)
        self.flush()
        self.line(f"if !({cond}) {{")
        self.indent += 1
        self.line("break")
        self.indent -= 1
        self.line("}")
        self.loop_stack.pop()
        self.indent -= 1
        self.line("}")

    def stmt_for(self, node):
        if node.init is not None:
            self.stmt(node.init)
        cond = "1"
        if node.cond is not None:
            cond, _ = self.expr(node.cond)
        pre = self.pre
        self.pre = []
        step_lines = []
        if node.step is not None:
            saved, self.lines = self.lines, step_lines
            saved_indent = self.indent
            self.indent = 0
            self.emit_expr_statement(node.step)
            self.indent = saved_indent
            self.lines = saved
        self.loop_stack.append(step_lines)
        self.line("while 1 {" if pre else f"while {cond} {{")
        self.indent += 1
        if pre:
            self.render(pre)
            self.line(f"if !({cond}) {{")
            self.indent += 1
            self.line("break")
            self.indent -= 1
            self.line("}")
        self.stmt_in_block(node.body)
        for text in step_lines:
            self.line(text.strip())
        self.indent -= 1
        self.line("}")
        self.loop_stack.pop()

    def stmt_break(self, node):
        self.line("break")

    def stmt_continue(self, node):
        steps = self.loop_stack[-1] if self.loop_stack else None
        for text in steps or []:
            self.line(text.strip())
        self.line("continue")

    def stmt_return(self, node):
        if node.value is None:
            self.line("return 0")
            return
        text, _ = self.expr(node.value)
        self.flush()
        self.line(f"return {text}")

    def stmt_switch(self, node):
        """`switch` becomes an if/else-if chain over a copy of the subject.

        `case 1: case 2: body` is one label list, because C falls through the
        empty label into the next body. `default` is emitted last as `else`
        wherever it appears in the source, which is when C would reach it.
        """
        subject, _ = self.expr(node.subject)
        self.flush()
        tmp = self.newtmp()
        self.line(f"let {tmp} = {subject}")

        groups = []                    # (values, is_default, body)
        values = []
        is_default = False
        for value, body in node.cases:
            if value is None:
                is_default = True
            else:
                values.append(value)
            if body:
                groups.append((values, is_default, body))
                values, is_default = [], False
        if values or is_default:
            groups.append((values, is_default, []))
        if not groups:
            return

        labels = [g for g in groups if not g[1]]
        default = next((g for g in groups if g[1]), None)
        if not labels:
            self.case_body(default[2], True)
            return

        for index, (values_, _, body) in enumerate(labels):
            cond = " || ".join(f"{tmp} == {value}" for value in values_)
            self.line(f"if {cond} {{" if index == 0
                      else f"}} else if {cond} {{")
            self.indent += 1
            last = default is None and index == len(labels) - 1
            self.case_body(body, last)
            self.indent -= 1
        if default is not None:
            self.line("} else {")
            self.indent += 1
            self.case_body(default[2], True)
            self.indent -= 1
        self.line("}")

    def case_body(self, body, is_last):
        stmts = list(body)
        if stmts and stmts[-1].kind == "break":
            stmts = stmts[:-1]         # the chain ends here anyway
        elif stmts and stmts[-1].kind == "return":
            pass
        elif stmts and not is_last:
            fail("switch fallthrough is not supported", stmts[-1].tok)
        for stmt in stmts:
            if stmt.kind == "break":
                fail("switch fallthrough is not supported", stmt.tok)
            self.stmt(stmt)

    # -- expressions ------------------------------------------------------
    def expr(self, node):
        kind = node.kind
        if kind == "num":
            return str(node.value), INT
        if kind == "float":
            return node.text, FLOAT
        if kind == "str":
            return tl_string(node.value, node.tok), STR
        if kind == "id":
            return self.expr_id(node)
        if kind == "bin":
            return self.expr_bin(node)
        if kind == "un":
            return self.expr_un(node)
        if kind == "assign":
            return self.expr_assign(node)
        if kind == "call":
            return self.expr_call(node)
        if kind == "index":
            return self.expr_index(node)
        if kind == "field":
            return self.expr_field(node)
        if kind == "ternary":
            return self.expr_ternary(node)
        if kind == "postinc":
            return self.expr_incdec(node, post=True)
        if kind == "preinc":
            return self.expr_incdec(node, post=False)
        if kind == "cast":
            text, itype = self.expr(node.operand)
            if node.ctype == CHAR:
                return text, INT
            if node.ctype == INT:
                if itype == FLOAT:
                    return f"int({text})", INT
                return text, INT
            if node.ctype == FLOAT:
                if itype == INT:
                    return f"float({text})", FLOAT
                return text, FLOAT
            return text, node.ctype
        if kind == "sizeof_type":
            return str(self.sizeof_type(node.ctype, node.tok)), INT
        if kind == "sizeof_expr":
            return str(self.sizeof_expr(node.operand)), INT
        if kind == "comma":
            self.emit_expr_statement(node.left)
            return self.expr(node.right)
        if kind == "init_list":
            fail("an initializer list is only supported in a declaration",
                 node.tok)
        fail(f"cannot translate expression '{kind}'", node.tok)

    def expr_id(self, node):
        name = node.name
        if name == "NULL":
            return "0", INT
        if name == "EOF":
            return "-1", INT
        if self.argc_argv and name == "argc":
            return "argc()", INT
        ctype = self.lookup(name)
        if ctype is None:
            fail(f"unknown identifier '{name}'", node.tok)
        return self.name_of(name), ctype

    def is_zero(self, node):
        if node.kind == "num":
            return node.value == 0
        if node.kind == "id":
            return node.name in ("NULL", "0")
        return False

    def expr_bin(self, node):
        op = node.op
        left, ltype = self.expr(node.left)
        right, rtype = self.expr(node.right)
        lstr, rstr = self.is_string(ltype), self.is_string(rtype)

        if lstr and rstr:
            if op == "-":
                return f"str_diff({left}, {right})", INT
            if op in ("==", "!="):
                fail("comparing two strings with == compares pointers in C and "
                     "contents in tlang; use strcmp", node.tok)
            fail("'%s' on a string is pointer arithmetic in C" % op, node.tok)

        if lstr or rstr:
            if op in ("+", "-"):
                if lstr:
                    ptr, index = left, right
                    index_type = rtype
                    sign = op
                else:
                    if op != "+":
                        fail("cannot subtract from a character pointer", node.tok)
                    ptr, index = right, left
                    index_type = ltype
                    sign = "+"
                if index_type not in (INT, CHAR):
                    fail("character pointer arithmetic needs an integer",
                         node.tok)
                if sign == "-":
                    return f"str_offset({ptr}, -({index}))", STR
                return f"str_offset({ptr}, {index})", STR
            zero = node.right if rstr else node.left
            if op in ("==", "!=") and self.is_zero(zero):
                return f"({left} {op} {right})", INT
            fail(f"comparing {op} a string with an integer", node.tok)

        if ltype == FLOAT or rtype == FLOAT:
            if op in ("%", "&", "|", "^", "<<", ">>"):
                fail(f"'{op}' is not defined on floats", node.tok)
            if op in ("+", "-", "*", "/"):
                return f"({left} {op} {right})", FLOAT
            if op in ("==", "!=", "<", "<=", ">", ">="):
                return f"({left} {op} {right})", INT
            fail(f"cannot translate '{op}' on a float", node.tok)

        lptr, rptr = self.is_pointer_type(ltype), self.is_pointer_type(rtype)
        if op in ("+", "-") and (lptr or rptr):
            if lptr and rptr:
                if op == "-":
                    return f"({left} - {right})", INT
                fail("cannot add two pointers", node.tok)
            if lptr:
                if rtype not in (INT, CHAR):
                    fail("pointer arithmetic needs an integer", node.tok)
                return f"({left} {op} {right})", ltype
            if op != "+" or ltype not in (INT, CHAR):
                fail("pointer arithmetic needs an integer", node.tok)
            return f"({left} + {right})", rtype
        if lptr or rptr:
            if op in ("==", "!=", "<", "<=", ">", ">="):
                return f"({left} {op} {right})", INT
            fail(f"cannot translate '{op}' on a pointer", node.tok)
        return f"({left} {op} {right})", INT

    def expr_un(self, node):
        op = node.op
        if op == "&":
            fail("taking an address is not supported", node.tok)
        if op == "*":
            if node.operand.kind in ("id", "call"):
                return self.expr(node.operand)
            fail("dereferencing is only supported on a struct pointer", node.tok)
        text, ctype = self.expr(node.operand)
        if op in ("-", "~") and self.is_string(ctype):
            fail(f"unary '{op}' on a string", node.tok)
        if op == "+":
            return text, ctype
        if op == "-" and ctype == FLOAT:
            return f"-{text}", FLOAT
        return f"{op}{text}", INT

    def expr_assign(self, node):
        # An assignment used as a value: do the store, then read it back.
        tmp = self.newtmp()
        self.pre_line(f"let {tmp} = 0")
        value, vtype = self.expr(node.value)
        place, ctype = self.place_of(node.target)
        if node.op == "=":
            value = self.convert(value, vtype, ctype)
            self.pre_line(f"{place} = {value}")
        else:
            self.pre_line(self.compound_text(place, ctype, node.op, value))
        self.pre_line(f"{tmp} = {place}")
        return tmp, ctype

    def expr_incdec(self, node, post):
        op = "+" if node.op == "++" else "-"
        place, ctype = self.place_of(node.operand)
        step = self.incdec_text(place, ctype, op)
        if post:
            tmp = self.newtmp()
            self.pre_line(f"let {tmp} = {place}")
            self.pre_line(f"{place} = {step}")
            return tmp, ctype
        self.pre_line(f"{place} = {step}")
        return place, ctype

    def expr_ternary(self, node):
        """`c ? a : b` with no ternary in tlang: a temp and a branch.

        Statements a branch needs must run *inside* that branch, not before the
        test, so each branch's prelude is captured separately.
        """
        cond, _ = self.expr(node.cond)
        before = list(self.pre)
        self.pre = []
        then, ttype = self.expr(node.then)
        then_pre = self.pre
        self.pre = []
        els, _ = self.expr(node.els)
        els_pre = self.pre
        self.pre = before

        tmp = self.newtmp()
        if not els_pre:
            # The else side is a single expression: it can initialise the temp.
            self.pre_line(f"let {tmp} = {els}")
            self.pre_line(f"if {cond} {{")
            self.pre.extend((extra + 1, text) for extra, text in then_pre)
            self.pre_line(f"{tmp} = {then}", 1)
            self.pre_line("}")
            return tmp, ttype
        self.pre_line(f"let {tmp} = 0")
        self.pre_line(f"if {cond} {{")
        self.pre.extend((extra + 1, text) for extra, text in then_pre)
        self.pre_line(f"{tmp} = {then}", 1)
        self.pre_line("} else {")
        self.pre.extend((extra + 1, text) for extra, text in els_pre)
        self.pre_line(f"{tmp} = {els}", 1)
        self.pre_line("}")
        return tmp, ttype

    def expr_index(self, node):
        if self.argc_argv and node.base.kind == "id" and node.base.name == "argv":
            index, _ = self.expr(node.index)
            return f"argv({index})", STR
        base, btype = self.expr(node.base)
        index, _ = self.expr(node.index)
        if btype[0] == "arr":
            elem = btype[1]
            if elem == STR:
                return f"{base}[{index}]", STR
            if elem == FLOAT:
                return f"{base}[{index}]", FLOAT
            return f"{base}[{index}]", INT
        if btype == STR:
            return f"{base}[{index}]", INT
        if btype[0] == "ptr":
            return f"{base}[{index}]", btype[1]
        fail("cannot index a value of this type", node.tok)

    def expr_field(self, node):
        base, btype = self.expr(node.base)
        if btype[0] != "struct":
            fail("field access on a non-struct value", node.tok)
        fields = dict(self.structs.get(btype[1], []))
        if node.name not in fields:
            fail(f"struct '{btype[1]}' has no field '{node.name}'", node.tok)
        return f"{base}.{self.name_of(node.name)}", fields[node.name]

    def expr_call(self, node):
        callee = node.callee
        if callee.kind != "id":
            fail("only named functions can be called", node.tok)
        name = callee.name

        if name == "printf":
            return self.emit_printf(node)
        if name in ("fprintf", "sprintf", "snprintf"):
            fail(f"{name} is not supported; use printf", node.tok)
        if name == "puts":
            text, _ = self.expr(node.args[0])
            self.pre_line(f"print({text})")
            self.pre_line('print("\\n")')
            return "", INT
        if name in ("malloc", "calloc"):
            return self.emit_alloc(node, name)
        if name == "free":
            return "", INT

        if name in LIBRARY:
            target, ret, argtypes = LIBRARY[name]
            if name in HELPERS:
                self.use(name)
            if isinstance(argtypes, str):
                argtypes = tuple(argtypes for _ in node.args)
            args = []
            for index, arg in enumerate(node.args):
                text, ctype = self.expr(arg)
                want = argtypes[index] if argtypes and index < len(argtypes) else None
                if want == "str" and not self.is_string(ctype):
                    fail(f"{name}() needs a string argument", node.tok)
                if want == "int" and self.is_string(ctype):
                    fail(f"{name}() needs an integer argument", node.tok)
                if want == "float":
                    if ctype == FLOAT:
                        pass
                    elif ctype in (INT, CHAR):
                        text = f"float({text})"
                    else:
                        fail(f"{name}() needs a float argument", node.tok)
                args.append(text)
            if name == "strcpy":
                self.pre_line(f"ct_strcpy({', '.join(args)})")
                return "", INT
            if name == "putchar" and args:
                return f"print_char({args[0]})", INT
            return f"{target}({', '.join(args)})", ret

        if name not in self.func_ret:
            fail(f"unknown function '{name}'", node.tok)
        args = [self.expr(arg)[0] for arg in node.args]
        return f"{self.name_of(name)}({', '.join(args)})", self.func_ret[name]

    def struct_zero(self, name, tok):
        fields = self.structs.get(name)
        if fields is None:
            fail(f"unknown struct type '{name}'", tok)
        return f"{name}({', '.join('0' for _ in fields)})"

    def emit_alloc(self, node, name):
        if name == "calloc":
            count, size = node.args[0], node.args[1]
        else:
            arg = node.args[0]
            if arg.kind == "bin" and arg.op == "*":
                count, size = arg.left, arg.right
                # Accept both `n * sizeof(T)` and `sizeof(T) * n`.
                if count.kind == "sizeof_type" and size.kind != "sizeof_type":
                    count, size = size, count
            else:
                count, size = arg, None
        if size is not None and size.kind == "sizeof_type":
            if size.ctype[0] == "struct":
                if count.kind == "num" and count.value == 1:
                    return (self.struct_zero(size.ctype[1], node.tok),
                            size.ctype)
                fail("sizeof(struct) with a count is not supported; "
                     "allocate one struct at a time", node.tok)
            if size.ctype == INT:
                text, _ = self.expr(count)
                return f"alloc({text})", ptr_t(INT)
            fail("sizeof(...) is only supported for an int element count "
                 "or one struct; C char/float layout is not modelled",
                 node.tok)
        if size is None and count.kind == "sizeof_type":
            if count.ctype[0] == "struct":
                return self.struct_zero(count.ctype[1], node.tok), count.ctype
            fail("sizeof(...) needs an element count in malloc/calloc; "
                 "C object layout is not modelled", node.tok)
        text, _ = self.expr(count)
        return f"alloc({text})", ptr_t(INT)

    def emit_printf(self, node):
        if not node.args:
            fail("printf needs a format string", node.tok)
        fmt = node.args[0]
        if fmt.kind != "str":
            fail("printf needs a literal format string", node.tok)
        parts = split_format(fmt.value, node.tok)
        args = [self.expr(arg) for arg in node.args[1:]]
        used = 0
        pending = ""
        for part in parts:
            if part[0] == "text":
                pending += tl_string(part[1], node.tok)[1:-1]
                continue
            if pending:
                self.pre_line(f'print("{pending}")')
                pending = ""
            text, ctype = args[used]
            used += 1
            if part[0] == "int":
                if self.is_string(ctype) or ctype == FLOAT:
                    fail("printf %d with a non-integer argument", node.tok)
                self.pre_line(f"print_int({text})")
            elif part[0] == "float":
                if ctype not in (FLOAT, INT, CHAR):
                    fail("printf %f needs a numeric argument", node.tok)
                if ctype != FLOAT:
                    text = f"float({text})"
                self.pre_line(f"print_float({text})")
            elif part[0] == "char":
                if self.is_string(ctype) or ctype == FLOAT:
                    fail("printf %c needs an integer argument", node.tok)
                self.pre_line(f"print_char({text})")
            else:
                if not self.is_string(ctype):
                    fail("printf %s needs a string argument", node.tok)
                self.pre_line(f"print({text})")
        if pending:
            self.pre_line(f'print("{pending}")')
        if used != len(args):
            fail("printf has more arguments than conversions", node.tok)
        return "", INT          # a statement, not a value

    def sizeof_type(self, ctype, tok):
        fail("sizeof(...) is only supported as an allocation size in "
             "malloc/calloc; C object layout is not modelled", tok)

    def sizeof_expr(self, node):
        fail("sizeof(...) is only supported as an allocation size in "
             "malloc/calloc; C object layout is not modelled", node.tok)


# ---------------------------------------------------------------- driver

def translate(src, filename="<input>"):
    text, macros = preprocess(src)
    toks = expand_macros(Lexer(text).lex(), macros)
    decls = Parser(toks).parse_unit()
    emitter = Emitter()
    for node in decls:
        if node.kind == "func":
            emitter.func_ret[node.name] = node.ret
    body = emitter.program(decls)
    header = f"# generated by Tools/ctolang.py from {os.path.basename(filename)}\n"
    return header + body


def main(argv):
    if not argv:
        print(__doc__.strip())
        return 1
    path = argv[0]
    out = argv[argv.index("-o") + 1] if "-o" in argv else None
    with open(path) as fh:
        src = fh.read()
    try:
        result = translate(src, path)
    except Unsupported as exc:
        print(f"ctolang: {path}: {exc}", file=sys.stderr)
        return 1
    if out:
        with open(out, "w") as fh:
            fh.write(result)
    else:
        sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
