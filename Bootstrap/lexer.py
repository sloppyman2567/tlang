"""Lexer for tlang.

Statements are terminated by a newline (Go-style automatic semicolons) or by an
explicit ';'.  A synthetic ';' token is inserted at a newline when the previous
token could end a statement.
"""

from .errors import TlangError

KEYWORDS = {
    "fn", "let", "if", "else", "while", "do", "loop", "for", "in",
    "return", "break", "continue", "true", "false", "struct", "switch",
    "case",
}

# Longest first: the lexer takes the first entry that matches.
PUNCT = [
    "<<=", ">>=", "->", "==", "!=", "<=", ">=", "&&", "||", "+=", "-=",
    "*=", "/=", "%=", "&=", "|=", "^=", "<<", ">>", "..", "++", "--",
    "(", ")", "{", "}", "[", "]", ",", ".", ":", "=", "+", "-", "*", "/",
    "%", "<", ">", "!", "&", "|", "^", "~", ";",
]

# Tokens after which a newline terminates the statement.
TERMINATORS = {"int", "float", "str", "ident", ")", "]", "}", "++", "--"}
KW_TERMINATORS = {"return", "break", "continue", "true", "false"}


class Token:
    __slots__ = ("kind", "val", "line", "col")

    def __init__(self, kind, val, line, col):
        self.kind = kind
        self.val = val
        self.line = line
        self.col = col

    def __repr__(self):
        return f"Token({self.kind!r}, {self.val!r}, {self.line}:{self.col})"


class Lexer:
    def __init__(self, src, filename="<input>"):
        self.src = src
        self.n = len(src)
        self.i = 0
        self.line = 1
        self.col = 1
        self.filename = filename
        self.tokens = []

    # -- position helpers -------------------------------------------------
    def error(self, msg):
        raise TlangError(msg, self.filename, self.line, self.col)

    def peek(self, k=0):
        j = self.i + k
        return self.src[j] if j < self.n else ""

    def advance(self):
        ch = self.src[self.i]
        self.i += 1
        if ch == "\n":
            self.line += 1
            self.col = 1
        else:
            self.col += 1
        return ch

    def push(self, kind, val=None, line=None, col=None):
        self.tokens.append(
            Token(kind, val, self.line if line is None else line,
                  self.col if col is None else col)
        )

    def last_is_terminator(self):
        if not self.tokens:
            return False
        t = self.tokens[-1]
        if t.kind in TERMINATORS:
            return True
        return t.kind == "kw" and t.val in KW_TERMINATORS

    # -- main loop --------------------------------------------------------
    def tokenize(self):
        while self.i < self.n:
            ch = self.peek()

            if ch in " \t\r":
                self.advance()
                continue

            if ch == "\n":
                if self.last_is_terminator():
                    self.push(";")
                self.advance()
                continue

            if ch == "#" or (ch == "/" and self.peek(1) == "/"):
                while self.i < self.n and self.peek() != "\n":
                    self.advance()
                continue

            if ch == "/" and self.peek(1) == "*":
                line, col = self.line, self.col
                self.advance()
                self.advance()
                while True:
                    if self.i >= self.n:
                        raise TlangError("unterminated block comment",
                                         self.filename, line, col)
                    if self.peek() == "*" and self.peek(1) == "/":
                        self.advance()
                        self.advance()
                        break
                    # A newline inside a comment still ends the statement, as
                    # it would if the comment were not there.
                    if self.peek() == "\n" and self.last_is_terminator():
                        self.push(";")
                    self.advance()
                continue

            if ch.isdigit():
                self.lex_number()
                continue

            if ch == '"':
                self.lex_string()
                continue

            if ch == "'":
                self.lex_char()
                continue

            if ch.isalpha() or ch == "_":
                self.lex_word()
                continue

            for p in PUNCT:
                if self.src.startswith(p, self.i):
                    line, col = self.line, self.col
                    for _ in p:
                        self.advance()
                    self.push(p, p, line, col)
                    break
            else:
                self.error(f"unexpected character {ch!r}")

        if self.last_is_terminator():
            self.push(";")
        self.push("eof", None)
        return self.tokens

    # -- token kinds ------------------------------------------------------
    def lex_number(self):
        line, col = self.line, self.col
        start = self.i
        if self.peek() == "0" and self.peek(1) in "xX":
            self.advance()
            self.advance()
            while self.peek().isalnum() or self.peek() == "_":
                self.advance()
            text = self.src[start:self.i].replace("_", "")
            try:
                value = int(text, 16)
            except ValueError:
                self.error(f"bad hex literal {text!r}")
            self.push("int", value, line, col)
            return
        if self.peek() == "0" and self.peek(1) in "bB":
            self.advance()
            self.advance()
            while self.peek() in "01_":
                self.advance()
            text = self.src[start:self.i].replace("_", "")
            try:
                value = int(text, 2)
            except ValueError:
                self.error(f"bad binary literal {text!r}")
            self.push("int", value, line, col)
            return

        while self.peek().isdigit() or self.peek() == "_":
            self.advance()
        is_float = False
        if self.peek() == "." and self.peek(1).isdigit():
            is_float = True
            self.advance()
            while self.peek().isdigit() or self.peek() == "_":
                self.advance()
        if self.peek() in "eE":
            k = 1
            if self.peek(k) in "+-":
                k += 1
            if self.peek(k).isdigit():
                is_float = True
                self.advance()
                if self.peek() in "+-":
                    self.advance()
                while self.peek().isdigit() or self.peek() == "_":
                    self.advance()
        text = self.src[start:self.i].replace("_", "")
        if not is_float:
            self.push("int", int(text), line, col)
            return
        exp = 0
        epos = max(text.find("e"), text.find("E"))
        if epos >= 0:
            exp = int(text[epos + 1:])
            text = text[:epos]
        if "." in text:
            whole, frac = text.split(".", 1)
            exp -= len(frac)
            text = whole + frac
        self.push("float", (int(text), exp), line, col)

    ESCAPES = {
        "n": 10, "t": 9, "r": 13, "\\": 92, '"': 34, "'": 39, "0": 0, "e": 27,
    }

    def read_escaped(self):
        """Read one (possibly escaped) character; the quote is already consumed."""
        ch = self.advance()
        if ch == "\\":
            esc = self.advance()
            if esc not in self.ESCAPES:
                self.error(f"unknown escape '\\{esc}'")
            return self.ESCAPES[esc]
        return ord(ch)

    def lex_string(self):
        line, col = self.line, self.col
        self.advance()  # opening quote
        chars = []
        while True:
            if self.i >= self.n:
                self.error("unterminated string literal")
            ch = self.peek()
            if ch == '"':
                self.advance()
                break
            if ch == "\n":
                self.error("unterminated string literal")
            chars.append(self.read_escaped())
        self.push("str", bytes(chars), line, col)

    def lex_char(self):
        line, col = self.line, self.col
        self.advance()  # opening quote
        if self.i >= self.n:
            self.error("unterminated character literal")
        value = self.read_escaped()
        if self.peek() != "'":
            self.error("character literal must hold exactly one character")
        self.advance()
        self.push("int", value, line, col)

    def lex_word(self):
        line, col = self.line, self.col
        start = self.i
        while self.peek().isalnum() or self.peek() == "_":
            self.advance()
        word = self.src[start:self.i]
        kind = "kw" if word in KEYWORDS else "ident"
        self.push(kind, word, line, col)


def tokenize(src, filename="<input>"):
    return Lexer(src, filename).tokenize()
