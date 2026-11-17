"""Recursive-descent parser for tlang."""

from . import ast_nodes as A
from .errors import TlangError
from .lexer import tokenize

# Binary operator precedence, loosest first (same order as C).
LEVELS = [
    ["||"],
    ["&&"],
    ["|"],
    ["^"],
    ["&"],
    ["==", "!="],
    ["<", "<=", ">", ">="],
    ["<<", ">>>", ">>"],
    ["+", "-"],
    ["*", "/", "%"],
]

MAX_PARAMS = 6

# `x += 1` is sugar for `x = x + 1`; the target is evaluated twice, so it is
# restricted to a plain variable (no index or field to recompute).
COMPOUND = {"+=": "+", "-=": "-", "*=": "*", "/=": "/", "%=": "%",
            "&=": "&", "|=": "|", "^=": "^", "<<=": "<<", ">>>=": ">>>",
            ">>=": ">>"}


class Parser:
    def __init__(self, tokens, filename="<input>"):
        self.toks = tokens
        self.pos = 0
        self.filename = filename

    # -- token helpers ----------------------------------------------------
    @property
    def tok(self):
        return self.toks[self.pos]

    def peek(self, k=0):
        j = self.pos + k
        return self.toks[j] if j < len(self.toks) else self.toks[-1]

    def at(self, kind):
        return self.tok.kind == kind

    def at_kw(self, word):
        t = self.tok
        return t.kind == "kw" and t.val == word

    def advance(self):
        t = self.tok
        if t.kind != "eof":
            self.pos += 1
        return t

    def error(self, msg, tok=None):
        t = tok or self.tok
        raise TlangError(msg, self.filename, t.line, t.col)

    def expect(self, kind, what):
        if not self.at(kind):
            self.error(f"expected {what}, found {self.describe(self.tok)}")
        return self.advance()

    def expect_kw(self, word):
        if not self.at_kw(word):
            self.error(f"expected '{word}', found {self.describe(self.tok)}")
        return self.advance()

    @staticmethod
    def describe(t):
        if t.kind == "eof":
            return "end of file"
        if t.kind == "kw":
            return f"'{t.val}'"
        if t.kind == "ident":
            return f"identifier '{t.val}'"
        if t.kind == "int":
            return f"number {t.val}"
        if t.kind == "float":
            return "floating-point literal"
        if t.kind == "str":
            return "string literal"
        return f"'{t.kind}'"

    def skip_semis(self):
        while self.at(";"):
            self.advance()

    # -- program ----------------------------------------------------------
    def parse(self):
        structs = []
        funcs = []
        globals_list = []
        consts = []
        while not self.at("eof"):
            self.skip_semis()
            if self.at("eof"):
                break
            if self.at_kw("struct"):
                structs.append(self.parse_struct())
            elif self.at_kw("fn"):
                funcs.append(self.parse_func())
            elif self.at_kw("let"):
                node = self.parse_let()
                globals_list.append(A.Global(name=node.name, expr=node.expr,
                                             line=node.line, col=node.col))
            elif self.at_kw("const"):
                consts.append(self.parse_const())
            else:
                self.error(
                    "expected 'fn', 'struct', a global 'let' or a 'const', "
                    f"found {self.describe(self.tok)}"
                )
        return A.Program(structs=structs, funcs=funcs, globals=globals_list,
                         consts=consts)

    def parse_const(self):
        """`const NAME = <int or string literal>`; the name has no storage."""
        start = self.expect_kw("const")
        name = self.expect("ident", "a const name")
        self.expect("=", "'=' after a const name")
        sign = None
        if self.at("-"):
            sign = self.advance()
        if self.at("int"):
            tok = self.advance()
            value = -tok.val if sign is not None else tok.val
            return A.Const(name=name.val, expr=A.Num(value=value, line=tok.line,
                                                    col=tok.col),
                           line=start.line, col=start.col)
        if sign is None and self.at("str"):
            tok = self.advance()
            return A.Const(name=name.val, expr=A.Str(value=tok.val, line=tok.line,
                                                    col=tok.col),
                           line=start.line, col=start.col)
        self.error(f"const '{name.val}' needs an int or string literal",
                   sign or self.tok)

    def parse_type_name(self, what):
        """A scalar type name, or `T[]` for an array of T."""
        name = self.expect("ident", what).val
        if self.at("["):
            self.advance()
            self.expect("]", "']' after an array type")
            name += "[]"
        return name

    def parse_struct(self):
        start = self.expect_kw("struct")
        name = self.expect("ident", "a struct name")
        self.expect("{", "'{'")
        fields = []
        if not self.at("}"):
            while True:
                self.skip_semis()
                fname = self.expect("ident", "a field name")
                ftype = ""
                if self.at(":"):
                    self.advance()
                    ftype = self.parse_type_name("a type name")
                fields.append((fname.val, ftype))
                self.skip_semis()
                if not self.at(","):
                    break
                self.advance()
                self.skip_semis()
                if self.at("}"):
                    break
        self.expect("}", "'}'")
        return A.StructDecl(name=name.val,
                            fields=[f[0] for f in fields],
                            field_types=[f[1] for f in fields],
                            line=start.line, col=start.col)

    def parse_func(self):
        start = self.expect_kw("fn")
        name = self.expect("ident", "a function name")
        self.expect("(", "'('")
        params = []
        ptypes = []
        if not self.at(")"):
            while True:
                pname = self.expect("ident", "a parameter name")
                ptype = ""
                if self.at(":"):
                    self.advance()
                    ptype = self.parse_type_name("a type name")
                params.append(pname)
                ptypes.append(ptype)
                if not self.at(","):
                    break
                self.advance()
        self.expect(")", "')'")
        if len(params) > MAX_PARAMS:
            self.error(
                f"'{name.val}' has {len(params)} parameters; "
                f"at most {MAX_PARAMS} are supported",
                name,
            )
        ret_type = ""
        if self.at("->"):
            self.advance()
            ret_type = self.parse_type_name("a return type")
        body = self.parse_block()
        return A.Func(name=name.val, params=[p.val for p in params],
                      param_types=ptypes, ret_type=ret_type,
                      body=body, line=start.line, col=start.col)

    def parse_block(self):
        start = self.expect("{", "'{'")
        stmts = []
        while True:
            self.skip_semis()
            if self.at("}") or self.at("eof"):
                break
            stmts.append(self.parse_stmt())
        self.expect("}", "'}'")
        return A.Block(stmts=stmts, line=start.line, col=start.col)

    # -- statements -------------------------------------------------------
    def parse_stmt(self):
        t = self.tok
        if t.kind == "kw":
            if t.val == "let":
                return self.parse_let()
            if t.val == "if":
                return self.parse_if()
            if t.val == "while":
                return self.parse_while()
            if t.val == "do":
                return self.parse_do()
            if t.val == "loop":
                return self.parse_loop()
            if t.val == "for":
                return self.parse_for()
            if t.val == "switch":
                return self.parse_switch()
            if t.val == "return":
                return self.parse_return()
            if t.val == "break":
                self.advance()
                return A.Break(line=t.line, col=t.col)
            if t.val == "continue":
                self.advance()
                return A.Continue(line=t.line, col=t.col)
            if t.val in ("fn", "struct", "else", "case"):
                self.error(f"'{t.val}' is not allowed here")

        if t.kind in ("++", "--"):
            self.advance()
            name = self.expect("ident", f"a variable after '{t.kind}'")
            return self.inc_dec(name, t)

        expr = self.parse_expr()
        if self.tok.kind in ("++", "--"):
            op = self.advance()
            if not isinstance(expr, A.Name):
                self.error(f"'{op.kind}' needs a plain variable")
            return self.inc_dec(expr, op)
        if self.at("="):
            self.advance()
            value = self.parse_expr()
            return A.Assign(target=expr, expr=value, line=t.line, col=t.col)
        if self.tok.kind in COMPOUND:
            op = self.advance()
            if not isinstance(expr, A.Name):
                self.error(f"'{op.kind}' needs a plain variable on the left")
            value = self.parse_expr()
            return A.Assign(
                target=expr,
                expr=A.Bin(op=COMPOUND[op.kind], left=expr, right=value,
                           line=op.line, col=op.col),
                line=t.line, col=t.col)
        return A.ExprStmt(expr=expr, line=t.line, col=t.col)

    def inc_dec(self, name, tok):
        """`i++`, `i--`, `++i`, `--i` as a statement: sugar for `i = i +- 1`."""
        if not isinstance(name, A.Name):
            name = A.Name(name=name.val, line=name.line, col=name.col)
        one = A.Num(value=1, line=tok.line, col=tok.col)
        return A.Assign(
            target=name,
            expr=A.Bin(op="+" if tok.kind == "++" else "-", left=name,
                       right=one, line=tok.line, col=tok.col),
            line=tok.line, col=tok.col)

    def parse_let(self):
        t = self.expect_kw("let")
        name = self.expect("ident", "a variable name")
        self.expect("=", "'='")
        expr = self.parse_expr()
        return A.Let(name=name.val, expr=expr, line=t.line, col=t.col)

    def parse_if(self):
        t = self.expect_kw("if")
        cond = self.parse_expr()
        then = self.parse_block()
        self.skip_semis()
        els = None
        if self.at_kw("else"):
            self.advance()
            if self.at_kw("if"):
                els = self.parse_if()
            else:
                els = self.parse_block()
        return A.If(cond=cond, then=then, els=els, line=t.line, col=t.col)

    def parse_while(self):
        t = self.expect_kw("while")
        cond = self.parse_expr()
        body = self.parse_block()
        return A.While(cond=cond, body=body, line=t.line, col=t.col)

    def parse_do(self):
        t = self.expect_kw("do")
        body = self.parse_block()
        # A newline after `}` becomes ';', so allow `} while ...` on its own line.
        self.skip_semis()
        self.expect_kw("while")
        cond = self.parse_expr()
        return A.DoWhile(cond=cond, body=body, line=t.line, col=t.col)

    def parse_loop(self):
        t = self.expect_kw("loop")
        body = self.parse_block()
        return A.Loop(body=body, line=t.line, col=t.col)

    def parse_for(self):
        t = self.expect_kw("for")
        name = self.expect("ident", "a loop variable")
        self.expect_kw("in")
        first = self.parse_expr()
        if self.at(".."):
            self.advance()
            end = self.parse_expr()
            body = self.parse_block()
            return A.For(name=name.val, start=first, end=end, body=body,
                         line=t.line, col=t.col)
        # No `..`: walk a string or an array element by element.
        body = self.parse_block()
        return A.ForEach(name=name.val, items=first, body=body,
                         line=t.line, col=t.col)

    def parse_switch(self):
        t = self.expect_kw("switch")
        selector = self.parse_expr()
        self.skip_semis()
        self.expect("{", "'{' after the switch value")
        cases = []
        default = None
        while True:
            self.skip_semis()
            if self.at("}") or self.at("eof"):
                break
            if self.at_kw("case"):
                ct = self.advance()
                if default is not None:
                    self.error("'case' cannot follow 'else' in a switch")
                values = [self.parse_case_value()]
                while self.at(","):
                    self.advance()
                    values.append(self.parse_case_value())
                self.skip_semis()
                body = self.parse_block()
                cases.append(A.Case(values=values, body=body,
                                    line=ct.line, col=ct.col))
                continue
            if self.at_kw("else"):
                et = self.advance()
                if default is not None:
                    self.error("switch has two 'else' branches", et)
                self.skip_semis()
                default = self.parse_block()
                continue
            self.error("expected 'case' or 'else' in a switch")
        self.expect("}", "'}'")
        return A.Switch(expr=selector, cases=cases, default=default,
                        line=t.line, col=t.col)

    def parse_case_value(self):
        t = self.tok
        if t.kind == "str":
            self.advance()
            return A.Str(value=t.val, line=t.line, col=t.col)
        neg = False
        if t.kind == "-":
            neg = True
            self.advance()
        n = self.expect("int", "a number or string literal after 'case'")
        return A.Num(value=-n.val if neg else n.val, line=n.line, col=n.col)

    def parse_return(self):
        t = self.expect_kw("return")
        if self.at(";") or self.at("}") or self.at("eof"):
            return A.Return(expr=None, line=t.line, col=t.col)
        return A.Return(expr=self.parse_expr(), line=t.line, col=t.col)

    # -- expressions ------------------------------------------------------
    def parse_expr(self):
        return self.parse_level(0)

    def parse_level(self, level):
        if level == len(LEVELS):
            return self.parse_unary()
        left = self.parse_level(level + 1)
        while self.tok.kind in LEVELS[level]:
            op = self.advance()
            right = self.parse_level(level + 1)
            left = A.Bin(op=op.kind, left=left, right=right,
                         line=op.line, col=op.col)
        return left

    def parse_unary(self):
        if self.at("-") or self.at("!") or self.at("~"):
            op = self.advance()
            operand = self.parse_unary()
            return A.Un(op=op.kind, expr=operand, line=op.line, col=op.col)
        return self.parse_postfix()

    def parse_postfix(self):
        node = self.parse_primary()
        while True:
            if self.at("["):
                t = self.advance()
                idx = self.parse_expr()
                self.expect("]", "']'")
                node = A.Index(base=node, idx=idx, line=t.line, col=t.col)
            elif self.at("."):
                t = self.advance()
                name = self.expect("ident", "a field name")
                node = A.Field(base=node, name=name.val, line=t.line, col=t.col)
            else:
                return node

    def parse_primary(self):
        t = self.tok
        if t.kind == "int":
            self.advance()
            return A.Num(value=t.val, line=t.line, col=t.col)
        if t.kind == "float":
            self.advance()
            return A.Float(mantissa=t.val[0], exp=t.val[1],
                           line=t.line, col=t.col)
        if t.kind == "str":
            self.advance()
            return A.Str(value=t.val, line=t.line, col=t.col)
        if t.kind == "kw" and t.val in ("true", "false"):
            self.advance()
            return A.Num(value=1 if t.val == "true" else 0,
                         line=t.line, col=t.col)
        if t.kind == "ident":
            self.advance()
            if self.at("("):
                self.advance()
                args = []
                if not self.at(")"):
                    args.append(self.parse_expr())
                    while self.at(","):
                        self.advance()
                        args.append(self.parse_expr())
                self.expect(")", "')'")
                return A.Call(name=t.val, args=args, line=t.line, col=t.col)
            return A.Name(name=t.val, line=t.line, col=t.col)
        if t.kind == "(":
            self.advance()
            inner = self.parse_expr()
            self.expect(")", "')'")
            return inner
        if t.kind == "[":
            self.advance()
            items = []
            if not self.at("]"):
                items.append(self.parse_expr())
                while self.at(","):
                    self.advance()
                    items.append(self.parse_expr())
            self.expect("]", "']'")
            return A.ArrayLit(items=items, line=t.line, col=t.col)
        self.error(f"expected an expression, found {self.describe(t)}")


def parse(src, filename="<input>"):
    return Parser(tokenize(src, filename), filename).parse()
