"""Lowering: AST -> three-address IR.

This is the only place that knows about scopes, struct layout, short-circuiting
and the kinds ("int", "str", "arr", "ptr", or a struct name) used to decide how
an operator behaves.
"""

from dataclasses import fields, is_dataclass

from . import ast_nodes as A
from .errors import TlangError
from .builtins_gen import BUILTIN_ARGS, BUILTINS
from .ir import FuncIR, Module, TEMP_BASE
from .kindrules_gen import compatible, is_array
from .optir import optimize_module
from .runtime import CONCAT_SYMBOL, STRLEN_SYMBOL

INT, STR, FLOAT, PTR, ARR, UNKNOWN = "int", "str", "float", "ptr", "arr", "unknown"
KIND_NAMES = {INT: "an integer", STR: "a string", FLOAT: "a float",
              PTR: "a pointer", ARR: "an array", UNKNOWN: "an unknown value"}


def type_kind(name, structs):
    """Map an annotation to an internal kind; None means it is not a type."""
    if name == "":
        return UNKNOWN
    if name in (INT, STR, FLOAT) or name in structs:
        return name
    if name.endswith("[]"):
        base = name[:-2]
        if base in (INT, STR, FLOAT) or base in structs:
            return "arr_of:" + base
    return None

ARITH = {"+": "add", "-": "sub", "*": "mul", "/": "div", "%": "mod"}
CMP = {"==": "eq", "!=": "ne", "<": "lt", "<=": "le", ">": "gt", ">=": "ge"}
# Shifts and bitwise operators are integers-only: they have no string meaning.
BITS = {"&": "and", "|": "or", "^": "xor", "<<": "shl", ">>": "shr"}
BIN_OPS = dict(ARITH, **BITS)
UNARY = {"-": "neg", "!": "not", "~": "bnot"}


def is_pointer_kind(kind, structs):
    """Arrays and structs are addresses too, so `+`/`-` step over slots."""
    return (kind in (ARR, PTR) or kind.startswith("arr_of:")
            or kind in structs)


def kind_name(kind):
    if kind.startswith("arr_of:"):
        return kind[len("arr_of:"):] + "[]"
    return {"int": "int", "str": "str", "float": "float",
            "arr": "array", "ptr": "array",
            "unknown": "unknown"}.get(kind, kind)


class Val:
    __slots__ = ("slot", "kind")

    def __init__(self, slot, kind=UNKNOWN):
        self.slot = slot
        self.kind = kind


class Context:
    def __init__(self, structs, funcs, ret_kinds, filename, field_kinds=None):
        self.structs = structs
        self.funcs = funcs
        self.ret_kinds = ret_kinds
        self.filename = filename
        self.field_kinds = field_kinds or {}
        self.offsets = {name: {f: i * 8 for i, f in enumerate(fs)}
                        for name, fs in structs.items()}


def walk(node):
    yield node
    if is_dataclass(node):
        for f in fields(node):
            v = getattr(node, f.name)
            if is_dataclass(v):
                yield from walk(v)
            elif isinstance(v, list):
                for item in v:
                    if is_dataclass(item):
                        yield from walk(item)


def infer_expr_kind(node, scope, ctx):
    """Kind of an expression, given the kinds of the locals in scope.

    This mirrors the lowerer's own rules and is used only to type unannotated
    returns. A form it cannot see through is UNKNOWN, which leaves the caller
    untyped rather than guessing.
    """
    if isinstance(node, A.Num):
        return INT
    if isinstance(node, A.Float):
        return FLOAT
    if isinstance(node, A.Str):
        return STR
    if isinstance(node, A.Name):
        return scope.get(node.name, UNKNOWN)
    if isinstance(node, A.ArrayLit):
        kinds = {infer_expr_kind(item, scope, ctx) for item in node.items}
        if len(kinds) == 1:
            elem = kinds.pop()
            if elem in (INT, STR, FLOAT) or elem in ctx.structs:
                return "arr_of:" + elem
        return ARR
    if isinstance(node, A.Bin):
        if node.op in ("&&", "||"):
            return INT
        left = infer_expr_kind(node.left, scope, ctx)
        right = infer_expr_kind(node.right, scope, ctx)
        if node.op == "+" and (left == STR or right == STR):
            return STR
        if (node.op in ("+", "-") and right == INT
                and is_pointer_kind(left, ctx.structs)):
            return PTR
        if (node.op == "+" and left == INT
                and is_pointer_kind(right, ctx.structs)):
            return PTR
        if (node.op == "-" and is_pointer_kind(left, ctx.structs)
                and is_pointer_kind(right, ctx.structs)):
            return INT
        if left == FLOAT or right == FLOAT:
            if node.op in CMP:
                return INT
            if node.op in ("+", "-", "*", "/"):
                return FLOAT
            return UNKNOWN
        return INT
    if isinstance(node, A.Un):
        if (node.op == "-"
                and infer_expr_kind(node.expr, scope, ctx) == FLOAT):
            return FLOAT
        return INT
    if isinstance(node, A.Call):
        if (node.name == "alloc" and len(node.args) == 2
                and isinstance(node.args[1], A.Name)
                and (node.args[1].name in ctx.structs
                     or node.args[1].name in (INT, STR, FLOAT))):
            return "arr_of:" + node.args[1].name
        if node.name == "alloc" and len(node.args) == 1:
            return ARR
        if node.name == "float":
            return FLOAT
        if node.name == "int":
            return INT
        if node.name == "len":
            return INT
        if node.name == "append" and node.args:
            return infer_expr_kind(node.args[0], scope, ctx)
        if node.name in ctx.structs:
            return node.name
        if node.name in BUILTINS:
            return BUILTINS[node.name][1]
        return ctx.ret_kinds.get(node.name, UNKNOWN)
    if isinstance(node, A.Field):
        base = infer_expr_kind(node.base, scope, ctx)
        return ctx.field_kinds.get(base, {}).get(node.name, UNKNOWN)
    if isinstance(node, A.Index):
        base = infer_expr_kind(node.base, scope, ctx)
        if base == STR:
            return INT
        if base.startswith("arr_of:"):
            return base[len("arr_of:"):]
        if base in (ARR, PTR):
            return INT
        return UNKNOWN
    return UNKNOWN


def infer_ret_kind(fn, ctx, base_scope=None):
    """Kind of the first return whose expression can be typed.

    Functions are inferred in declaration order, so a call to an earlier
    function already has a kind; recursion and forward calls stay untyped.
    Globals are in scope, since every function can read them.
    """
    scope = dict(base_scope or {})
    for name, tname in zip(fn.params, fn.param_types):
        scope[name] = type_kind(tname, ctx.structs) if tname else UNKNOWN
    found = UNKNOWN

    def walk_stmt(node, sc):
        nonlocal found
        if found != UNKNOWN:
            return
        if isinstance(node, A.Block):
            for stmt in node.stmts:
                walk_stmt(stmt, sc)
        elif isinstance(node, A.Return):
            if node.expr is not None:
                kind = infer_expr_kind(node.expr, sc, ctx)
                if kind != UNKNOWN:
                    found = kind
        elif isinstance(node, A.Let):
            sc[node.name] = infer_expr_kind(node.expr, sc, ctx)
        elif isinstance(node, A.Assign):
            if isinstance(node.target, A.Name):
                sc[node.target.name] = infer_expr_kind(node.expr, sc, ctx)
        elif isinstance(node, A.If):
            walk_stmt(node.then, dict(sc))
            if node.els is not None:
                walk_stmt(node.els, dict(sc))
        elif isinstance(node, A.While):
            walk_stmt(node.body, dict(sc))
        elif isinstance(node, A.DoWhile):
            walk_stmt(node.body, dict(sc))
        elif isinstance(node, A.Loop):
            walk_stmt(node.body, dict(sc))
        elif isinstance(node, A.For):
            inner = dict(sc)
            inner[node.name] = INT
            walk_stmt(node.body, inner)
        elif isinstance(node, A.ForEach):
            inner = dict(sc)
            items = infer_expr_kind(node.items, sc, ctx)
            if items.startswith("arr_of:"):
                inner[node.name] = items[len("arr_of:"):]
            else:
                inner[node.name] = INT
            walk_stmt(node.body, inner)
        elif isinstance(node, A.Switch):
            for case in node.cases:
                walk_stmt(case.body, dict(sc))
            if node.default is not None:
                walk_stmt(node.default, dict(sc))

    walk_stmt(fn.body, scope)
    return found


class Lowerer:
    def __init__(self, ctx, strings, runtime_used, base_scope=None):
        self.ctx = ctx
        self.strings = strings
        self.runtime_used = runtime_used
        self.base_scope = base_scope or {}
        self.fname = ""
        self.ins = []
        self.nperm = 0
        self.ntemp = 0
        self.max_temp = 0
        self.scopes = [dict(self.base_scope)]
        self.loops = []
        self.label_n = 0
        self.cur_ret = UNKNOWN

    # -- helpers ----------------------------------------------------------
    def error(self, msg, node=None):
        raise TlangError(msg, self.ctx.filename,
                         getattr(node, "line", 0), getattr(node, "col", 0))

    def emit(self, *ins):
        self.ins.append(ins)

    def temp(self):
        self.ntemp += 1
        if self.ntemp > self.max_temp:
            self.max_temp = self.ntemp
        return TEMP_BASE + self.ntemp - 1

    def label(self):
        self.label_n += 1
        return f".L{self.fname}_{self.label_n}"

    def use(self, symbol):
        self.runtime_used.add(symbol)

    def intern(self, data):
        # The label counter is shared by the whole module: numbering per function
        # would let two functions' literals overwrite each other in .data.
        for label, existing in self.strings.items():
            if existing == data:
                return label
        label = f".Lstr{len(self.strings) + 1}"
        self.strings[label] = data
        return label

    def declare(self, name, slot, kind):
        self.scopes[-1][name] = [slot, kind]

    def is_pointer(self, kind):
        return is_pointer_kind(kind, self.ctx.structs)

    def lookup(self, name, node):
        for scope in reversed(self.scopes):
            if name in scope:
                entry = scope[name]
                return Val(entry[0], entry[1])
        self.error(f"unknown variable '{name}'", node)

    def new_perm(self):
        slot = self.nperm
        self.nperm += 1
        return slot

    # -- statements -------------------------------------------------------
    def stmt(self, node):
        self.ntemp = 0
        if isinstance(node, A.Block):
            self.scopes.append({})
            for s in node.stmts:
                self.stmt(s)
            self.scopes.pop()
        elif isinstance(node, A.Let):
            v = self.expr(node.expr)
            slot = self.new_perm()
            self.emit("mov", slot, v.slot)
            self.declare(node.name, slot, v.kind)
        elif isinstance(node, A.Assign):
            self.assign(node)
        elif isinstance(node, A.If):
            self.if_stmt(node)
        elif isinstance(node, A.While):
            self.while_stmt(node)
        elif isinstance(node, A.DoWhile):
            self.do_while_stmt(node)
        elif isinstance(node, A.Loop):
            self.loop_stmt(node)
        elif isinstance(node, A.For):
            self.for_stmt(node)
        elif isinstance(node, A.ForEach):
            self.for_each(node)
        elif isinstance(node, A.Switch):
            self.switch_stmt(node)
        elif isinstance(node, A.Return):
            if node.expr is None:
                self.emit("ret0")
            else:
                v = self.expr(node.expr)
                if not compatible(self.cur_ret, v.kind):
                    self.error(
                        f"'{self.fname}' returns {kind_name(self.cur_ret)}, "
                        f"but this return gives {kind_name(v.kind)}", node)
                self.emit("ret", v.slot)
        elif isinstance(node, A.Break):
            if not self.loops:
                self.error("'break' outside of a loop", node)
            self.emit("jmp", self.loops[-1][0])
        elif isinstance(node, A.Continue):
            target = None
            for entry in reversed(self.loops):
                if entry[1]:
                    target = entry[1]
                    break
            if target is None:
                self.error("'continue' outside of a loop", node)
            self.emit("jmp", target)
        elif isinstance(node, A.ExprStmt):
            self.expr(node.expr)
        else:
            self.error("unsupported statement", node)

    def if_stmt(self, node):
        cond = self.expr(node.cond)
        else_label = self.label()
        end_label = self.label()
        self.emit("jz", cond.slot, else_label)
        self.stmt(node.then)
        if node.els is not None:
            self.emit("jmp", end_label)
            self.emit("lab", else_label)
            self.stmt(node.els)
            self.emit("lab", end_label)
        else:
            self.emit("lab", else_label)

    def while_stmt(self, node):
        top = self.label()
        end = self.label()
        self.emit("lab", top)
        cond = self.expr(node.cond)
        self.emit("jz", cond.slot, end)
        self.loops.append((end, top))
        self.stmt(node.body)
        self.loops.pop()
        self.emit("jmp", top)
        self.emit("lab", end)

    def do_while_stmt(self, node):
        """`do { } while cond`: body first, then the test.

        `continue` jumps to the condition, not the body, and `break` leaves the
        loop, matching the other loop forms.
        """
        top = self.label()
        cont = self.label()
        end = self.label()
        self.emit("lab", top)
        self.loops.append((end, cont))
        self.stmt(node.body)
        self.loops.pop()
        self.emit("lab", cont)
        cond = self.expr(node.cond)
        self.emit("jnz", cond.slot, top)
        self.emit("lab", end)

    def loop_stmt(self, node):
        """`loop { }`: unconditional; `break` leaves, `continue` starts over."""
        top = self.label()
        end = self.label()
        self.emit("lab", top)
        self.loops.append((end, top))
        self.stmt(node.body)
        self.loops.pop()
        self.emit("jmp", top)
        self.emit("lab", end)

    def for_stmt(self, node):
        """`for i in a..b`: the upper bound is evaluated once, before the loop.

        `continue` jumps to the increment, not to the condition, so a loop body
        that continues early still advances its counter.
        """
        start = self.expr(node.start)
        end = self.expr(node.end)

        self.scopes.append({})
        slot = self.new_perm()
        self.emit("mov", slot, start.slot)
        self.declare(node.name, slot, INT)
        end_slot = self.new_perm()
        self.emit("mov", end_slot, end.slot)

        top = self.label()
        step = self.label()
        done = self.label()
        self.emit("lab", top)
        cond = self.temp()
        self.emit("cmp", "lt", cond, slot, end_slot)
        self.emit("jz", cond, done)
        self.loops.append((done, step))
        self.stmt(node.body)
        self.loops.pop()
        self.emit("lab", step)
        one = self.temp()
        self.emit("imm", one, 1)
        self.emit("bin", "add", slot, slot, one)
        self.emit("jmp", top)
        self.emit("lab", done)
        self.scopes.pop()

    def for_each(self, node):
        """`for x in value`: the collection and its length are read once.

        The loop variable is loaded from the collection each iteration, so
        `continue` skips to the next element and `break` leaves the loop -- the
        same shape as the range loop above.
        """
        coll = self.expr(node.items)
        self.scopes.append({})
        ptr_slot = self.new_perm()
        self.emit("mov", ptr_slot, coll.slot)
        len_slot = self.new_perm()
        if coll.kind == STR:
            self.use(STRLEN_SYMBOL)
            self.emit("bcall", len_slot, STRLEN_SYMBOL, (ptr_slot,))
            elem_kind = INT
            load = "ldb"
        elif coll.kind in (ARR, PTR) or coll.kind.startswith("arr_of:"):
            self.use("__t_alen")
            self.emit("bcall", len_slot, "__t_alen", (ptr_slot,))
            elem_kind = (coll.kind[len("arr_of:"):]
                         if coll.kind.startswith("arr_of:") else INT)
            load = "ld8"
        else:
            self.error("for-each needs a string or an array", node)
        idx = self.new_perm()
        self.emit("imm", idx, 0)
        var = self.new_perm()
        self.declare(node.name, var, elem_kind)
        top = self.label()
        step = self.label()
        done = self.label()
        self.emit("lab", top)
        cond = self.temp()
        self.emit("cmp", "lt", cond, idx, len_slot)
        self.emit("jz", cond, done)
        self.emit(load, var, ptr_slot, idx)
        self.loops.append((done, step))
        self.stmt(node.body)
        self.loops.pop()
        self.emit("lab", step)
        one = self.temp()
        self.emit("imm", one, 1)
        self.emit("bin", "add", idx, idx, one)
        self.emit("jmp", top)
        self.emit("lab", done)
        self.scopes.pop()

    def switch_stmt(self, node):
        """`switch v { case 1 { } case 2, 3 { } else { } }` -- no fallthrough.

        Matching the first arm wins. A `break` leaves the switch (it is pushed
        as an exit target), while `continue` keeps walking outwards to an
        enclosing loop, which is what C programmers expect of both.
        """
        sel = self.expr(node.expr)
        value_kinds = set()
        for case in node.cases:
            for value in case.values:
                if isinstance(value, A.Num):
                    value_kinds.add(INT)
                elif isinstance(value, A.Str):
                    value_kinds.add(STR)
                else:
                    self.error("switch case values must be literals", case)
        if len(value_kinds) > 1:
            self.error("switch mixes string and integer case values", node)
        if value_kinds:
            vkind = value_kinds.pop()
        elif sel.kind == UNKNOWN:
            vkind = INT          # an empty switch tells us nothing
        else:
            vkind = sel.kind
        if sel.kind == FLOAT:
            self.error("switch does not support float values", node)
        if vkind not in (INT, STR):
            self.error("switch needs integer or string case values", node)
        if not compatible(vkind, sel.kind):
            self.error(
                f"switch on {kind_name(sel.kind)} cannot match "
                f"{kind_name(vkind)} case values", node)

        end = self.label()
        arms = []
        for case in node.cases:
            body_label = self.label()
            for value in case.values:
                val = self.expr(value)
                cond = self.temp()
                if vkind == STR:
                    self.use("__t_str_eq")
                    self.emit("bcall", cond, "__t_str_eq", (sel.slot, val.slot))
                    self.emit("jnz", cond, body_label)
                else:
                    self.emit("cmp", "eq", cond, sel.slot, val.slot)
                    self.emit("jnz", cond, body_label)
            arms.append((case, body_label))

        default_label = self.label() if node.default is not None else None
        self.emit("jmp", default_label or end)
        for case, body_label in arms:
            self.emit("lab", body_label)
            self.loops.append((end, ""))
            self.stmt(case.body)
            self.loops.pop()
            self.emit("jmp", end)
        if node.default is not None:
            self.emit("lab", default_label)
            self.loops.append((end, ""))
            self.stmt(node.default)
            self.loops.pop()
        self.emit("lab", end)

    def assign(self, node):
        target = node.target
        if isinstance(target, A.Name):
            slot = self.lookup(target.name, target)
            v = self.expr(node.expr)
            self.emit("mov", slot.slot, v.slot)
            for scope in reversed(self.scopes):
                if target.name in scope:
                    entry = scope[target.name]
                    if v.kind != UNKNOWN:
                        entry[1] = v.kind
                    break
        elif isinstance(target, A.Index):
            base = self.expr(target.base)
            idx = self.expr(target.idx)
            v = self.expr(node.expr)
            if base.kind == STR:
                self.check_string_index(idx)
                self.emit("stb", base.slot, idx.slot, v.slot)
            else:
                self.check_array_index(base, idx)
                self.emit("st8", base.slot, idx.slot, v.slot)
        elif isinstance(target, A.Field):
            base = self.expr(target.base)
            v = self.expr(node.expr)
            off = self.field_offset(base, target)
            self.emit("fst", base.slot, off, v.slot)
        else:
            self.error("cannot assign to this expression", node)

    def field_offset(self, base, node):
        if base.kind in self.ctx.structs:
            offsets = self.ctx.offsets[base.kind]
            if node.name not in offsets:
                self.error(
                    f"struct '{base.kind}' has no field '{node.name}'", node)
            return offsets[node.name]
        self.error(
            f"cannot read field '{node.name}' of "
            f"{KIND_NAMES.get(base.kind, base.kind)}", node)

    def field_kind(self, base_kind, field):
        return self.ctx.field_kinds.get(base_kind, {}).get(field, UNKNOWN)

    def check_array_index(self, base, idx):
        """Abort before an out-of-range array access.

        Arrays carry their length in the header, so this is a load and two
        branches. Interior pointers have no header and stay unchecked; they
        are represented by PTR, while whole arrays are ARR/arr_of.
        """
        if not (base.kind == ARR or base.kind.startswith("arr_of:")):
            return
        self.use("__t_bounds_fail")
        bad = self.label()
        good = self.label()
        neg_one = self.temp()
        self.emit("imm", neg_one, -1)
        length = self.temp()
        self.emit("ld8", length, base.slot, neg_one)
        self.emit("jcck", "lt", idx.slot, 0, bad)
        self.emit("jcc", "lt", idx.slot, length, good)
        self.emit("lab", bad)
        unused = self.temp()
        self.emit("bcall", unused, "__t_bounds_fail", ())
        self.emit("lab", good)

    def check_string_index(self, idx):
        """Abort on a negative string index.

        Strings carry no length, so the upper bound would need a strlen on
        every access, which is too slow for byte-at-a-time scanning. The lower
        bound costs one branch and catches reads and writes before the buffer.
        Writing at `strlen(s)` is how a NUL-terminated buffer grows, so the
        upper bound must stay open anyway.
        """
        self.use("__t_bounds_fail")
        good = self.label()
        self.emit("jcck", "ge", idx.slot, 0, good)
        unused = self.temp()
        self.emit("bcall", unused, "__t_bounds_fail", ())
        self.emit("lab", good)

    # -- expressions ------------------------------------------------------
    def expr(self, node):
        if isinstance(node, A.Num):
            t = self.temp()
            self.emit("imm", t, node.value)
            return Val(t, INT)
        if isinstance(node, A.Float):
            mant = self.temp()
            exp = self.temp()
            self.emit("imm", mant, node.mantissa)
            self.emit("imm", exp, node.exp)
            t = self.temp()
            self.use("__t_fconst")
            self.emit("bcall", t, "__t_fconst", (mant, exp))
            return Val(t, FLOAT)
        if isinstance(node, A.Str):
            t = self.temp()
            self.emit("lea", t, self.intern(node.value))
            return Val(t, STR)
        if isinstance(node, A.Name):
            return self.lookup(node.name, node)
        if isinstance(node, A.Bin):
            return self.binary(node)
        if isinstance(node, A.Un):
            operand = self.expr(node.expr)
            if operand.kind == FLOAT:
                if node.op != "-":
                    self.error(
                        f"cannot use unary '{node.op}' on a float", node)
                t = self.temp()
                self.use("__t_fneg")
                self.emit("bcall", t, "__t_fneg", (operand.slot,))
                return Val(t, FLOAT)
            # `!s` asks whether the pointer is null, which is what `if s` does.
            # Negating or complementing a pointer is a mistake, so say so.
            if node.op in ("-", "~") and operand.kind == STR:
                self.error(f"cannot use unary '{node.op}' on a string", node)
            t = self.temp()
            self.emit(UNARY[node.op], t, operand.slot)
            return Val(t, INT)
        if isinstance(node, A.Call):
            return self.call(node)
        if isinstance(node, A.Index):
            return self.index(node)
        if isinstance(node, A.Field):
            base = self.expr(node.base)
            off = self.field_offset(base, node)
            t = self.temp()
            self.emit("fld", t, base.slot, off)
            return Val(t, self.field_kind(base.kind, node.name))
        if isinstance(node, A.ArrayLit):
            return self.array_lit(node)
        self.error("unsupported expression", node)

    def binary(self, node):
        op = node.op
        if op in ("&&", "||"):
            return self.logical(node)
        left = self.expr(node.left)
        right = self.expr(node.right)

        if op == "+" and (left.kind == STR or right.kind == STR):
            if FLOAT in (left.kind, right.kind):
                self.error("cannot concatenate a float to a string", node)
            a = self.to_str(left)
            b = self.to_str(right)
            t = self.temp()
            self.use(CONCAT_SYMBOL)
            self.emit("bcall", t, CONCAT_SYMBOL, (a, b))
            return Val(t, STR)

        if (op in ("+", "-") and right.kind in (INT, UNKNOWN)
                and self.is_pointer(left.kind)):
            return self.pointer_offset(left, right, 1 if op == "+" else -1)
        if (op == "+" and left.kind in (INT, UNKNOWN)
                and self.is_pointer(right.kind)):
            return self.pointer_offset(right, left, 1)
        if (op == "-" and self.is_pointer(left.kind)
                and self.is_pointer(right.kind)):
            diff = self.temp()
            self.emit("bin", "sub", diff, left.slot, right.slot)
            eight = self.temp()
            self.emit("imm", eight, 8)
            t = self.temp()
            self.emit("bin", "div", t, diff, eight)
            return Val(t, INT)

        if left.kind == FLOAT or right.kind == FLOAT:
            return self.float_binary(node, left, right)

        if op in CMP and (left.kind == STR and right.kind == STR):
            if op in ("==", "!="):
                t = self.temp()
                self.use("__t_str_eq")
                self.emit("bcall", t, "__t_str_eq", (left.slot, right.slot))
                if op == "==":
                    return Val(t, INT)
                d = self.temp()
                self.emit("not", d, t)
                return Val(d, INT)
            # Ordering compares contents byte by byte, like strcmp; a prefix
            # sorts before the longer string.
            c = self.temp()
            self.use("__t_str_cmp")
            self.emit("bcall", c, "__t_str_cmp", (left.slot, right.slot))
            zero = self.temp()
            self.emit("imm", zero, 0)
            t = self.temp()
            self.emit("cmp", CMP[op], t, c, zero)
            return Val(t, INT)

        if op in CMP:
            t = self.temp()
            self.emit("cmp", CMP[op], t, left.slot, right.slot)
            return Val(t, INT)

        if op not in BIN_OPS:
            self.error(f"unknown operator '{op}'", node)
        if left.kind == STR or right.kind == STR:
            self.error(f"cannot use '{op}' on strings", node)
        t = self.temp()
        self.emit("bin", BIN_OPS[op], t, left.slot, right.slot)
        return Val(t, INT)

    def pointer_offset(self, ptr, index, sign):
        """Step a pointer by whole 8-byte slots; `p - i` uses sign -1."""
        eight = self.temp()
        self.emit("imm", eight, 8)
        scaled = self.temp()
        self.emit("bin", "mul", scaled, index.slot, eight)
        t = self.temp()
        self.emit("bin", "add" if sign > 0 else "sub", t, ptr.slot, scaled)
        # The result may point inside an allocation, so it has no header and
        # cannot be bounds-checked as a whole array.
        return Val(t, PTR)

    def as_float(self, val, node):
        if val.kind == FLOAT:
            return val.slot
        if val.kind == INT:
            t = self.temp()
            self.use("__t_itof")
            self.emit("bcall", t, "__t_itof", (val.slot,))
            return t
        self.error(f"cannot convert {kind_name(val.kind)} to a float", node)

    def float_binary(self, node, left, right):
        op = node.op
        if op in ("&", "|", "^", "<<", ">>", "%"):
            self.error(f"cannot use '{op}' on floats", node)
        a = self.as_float(left, node)
        b = self.as_float(right, node)
        if op in ("+", "-", "*", "/"):
            kind = {"+": "add", "-": "sub", "*": "mul", "/": "div"}[op]
            t = self.temp()
            self.emit("fbin", kind, t, a, b)
            return Val(t, FLOAT)
        if op in CMP:
            cmpv = self.temp()
            self.use("__t_fcmp")
            self.emit("bcall", cmpv, "__t_fcmp", (a, b))
            t = self.temp()
            if op == "==":
                self.emit("cmpk", "eq", t, cmpv, 0)
            elif op == "!=":
                self.emit("cmpk", "ne", t, cmpv, 0)
            elif op == "<":
                self.emit("cmpk", "eq", t, cmpv, -1)
            elif op == "<=":
                self.emit("cmpk", "le", t, cmpv, 0)
            elif op == ">":
                self.emit("cmpk", "eq", t, cmpv, 1)
            else:
                ge = self.temp()
                not_nan = self.temp()
                self.emit("cmpk", "ge", ge, cmpv, 0)
                self.emit("cmpk", "ne", not_nan, cmpv, 2)
                self.emit("bin", "and", t, ge, not_nan)
            return Val(t, INT)
        self.error(f"unknown operator '{op}' on floats", node)

    def to_str(self, val):
        if val.kind == STR:
            return val.slot
        if val.kind == INT:
            t = self.temp()
            self.use("__t_itoa")
            self.emit("bcall", t, "__t_itoa", (val.slot,))
            return t
        return val.slot

    def logical(self, node):
        short = self.label()
        end = self.label()
        left = self.expr(node.left)
        t = self.temp()
        if node.op == "&&":
            self.emit("jz", left.slot, short)
        else:
            self.emit("jnz", left.slot, short)
        right = self.expr(node.right)
        self.emit("jz", right.slot, short) if node.op == "&&" else \
            self.emit("jnz", right.slot, short)
        # Fallthrough means both operands decided the result: true for &&,
        # false for ||. The short-circuit label is the opposite.
        self.emit("imm", t, 1 if node.op == "&&" else 0)
        self.emit("jmp", end)
        self.emit("lab", short)
        self.emit("imm", t, 0 if node.op == "&&" else 1)
        self.emit("lab", end)
        return Val(t, INT)

    def call(self, node):
        name = node.name

        # alloc(n, Struct) allocates a typed array: indexing it yields Struct.
        if (name == "alloc" and len(node.args) == 2
                and isinstance(node.args[1], A.Name)
                and (node.args[1].name in self.ctx.structs
                     or node.args[1].name in (INT, STR, FLOAT))):
            count = self.expr(node.args[0])
            t = self.temp()
            self.use("__t_alloc")
            self.emit("bcall", t, "__t_alloc", (count.slot,))
            return Val(t, "arr_of:" + node.args[1].name)

        args = [self.expr(a) for a in node.args]

        if name == "float":
            if len(args) != 1:
                self.error("float() takes exactly one argument", node)
            if args[0].kind == FLOAT:
                return args[0]
            if args[0].kind == INT:
                t = self.temp()
                self.use("__t_itof")
                self.emit("bcall", t, "__t_itof", (args[0].slot,))
                return Val(t, FLOAT)
            self.error("float() needs an integer or a float", node)

        if name == "int" and len(args) == 1 and args[0].kind == FLOAT:
            t = self.temp()
            self.use("__t_ftoi")
            self.emit("bcall", t, "__t_ftoi", (args[0].slot,))
            return Val(t, INT)

        expected = BUILTIN_ARGS.get(name)
        if expected is not None:
            for i, arg in enumerate(args):
                allowed = expected[i] if i < len(expected) else ()
                if arg.kind in ("", UNKNOWN) or not allowed:
                    continue
                if not any(compatible(want, arg.kind) for want in allowed):
                    wanted = " or ".join(kind_name(w) for w in allowed)
                    self.error(
                        f"{name}() argument {i + 1} should be {wanted}, "
                        f"got {kind_name(arg.kind)}", node)

        if name == "append":
            if len(args) != 2:
                self.error("append() takes exactly two arguments", node)
            arr, value = args
            if not is_array(arr.kind):
                self.error("append() needs an array", node)
            if arr.kind.startswith("arr_of:"):
                elem = arr.kind[len("arr_of:"):]
                if not compatible(elem, value.kind):
                    self.error(
                        f"cannot append {kind_name(value.kind)} to "
                        f"{kind_name(arr.kind)}", node)
            t = self.temp()
            self.use("__t_append")
            self.emit("bcall", t, "__t_append", (arr.slot, value.slot))
            return Val(t, arr.kind)

        if name == "len":
            if len(args) != 1:
                self.error("len() takes exactly one argument", node)
            arg = args[0]
            if arg.kind == STR:
                t = self.temp()
                self.use(STRLEN_SYMBOL)
                self.emit("bcall", t, STRLEN_SYMBOL, (arg.slot,))
                return Val(t, INT)
            # Arrays carry their length in the header, so this is O(1) -- no
            # compile-time constant to go stale when an alias appends.
            if arg.kind in (ARR, PTR) or arg.kind.startswith("arr_of:"):
                t = self.temp()
                self.use("__t_alen")
                self.emit("bcall", t, "__t_alen", (arg.slot,))
                return Val(t, INT)
            self.error("len() needs a string or an array", node)

        if name in self.ctx.structs:
            fields = self.ctx.structs[name]
            if len(args) != len(fields):
                self.error(
                    f"struct '{name}' has {len(fields)} field(s), "
                    f"got {len(args)}", node)
            t = self.temp()
            count = self.temp()
            self.use("__t_alloc")
            self.emit("imm", count, len(fields))
            self.emit("aloc", t, count)
            for i, arg in enumerate(args):
                self.emit("fst", t, i * 8, arg.slot)
            return Val(t, name)

        if name in self.ctx.funcs:
            fn = self.ctx.funcs[name]
            params = fn.params
            if len(args) != len(params):
                self.error(
                    f"function '{name}' takes {len(params)} argument(s), "
                    f"got {len(args)}", node)
            for i, arg in enumerate(args):
                ptype = (fn.param_types[i]
                         if i < len(fn.param_types) else "")
                want = type_kind(ptype, self.ctx.structs)
                if not compatible(want, arg.kind):
                    self.error(
                        f"function '{name}' argument {i + 1} should be "
                        f"{kind_name(want)}, got {kind_name(arg.kind)}", node)
            t = self.temp()
            self.emit("call", t, name, tuple(a.slot for a in args))
            return Val(t, self.ctx.ret_kinds.get(name, UNKNOWN))

        if name in BUILTINS:
            arity, kind, symbol = BUILTINS[name]
            if len(args) != arity:
                self.error(
                    f"{name}() takes {arity} argument(s), got {len(args)}",
                    node)
            if name in ("print", "print_err") and args[0].kind == INT:
                args[0] = Val(self.to_str(args[0]), STR)
            if name == "str" and args[0].kind == FLOAT:
                symbol = "__t_ftoa"
            t = self.temp()
            self.use(symbol)
            self.emit("bcall", t, symbol, tuple(a.slot for a in args))
            if name == "alloc":
                return Val(t, ARR)
            return Val(t, kind)

        self.error(f"unknown function '{name}'", node)

    def index(self, node):
        base = self.expr(node.base)
        idx = self.expr(node.idx)
        t = self.temp()
        if base.kind == STR:
            self.check_string_index(idx)
            self.emit("ldb", t, base.slot, idx.slot)
            return Val(t, INT)
        if base.kind in self.ctx.structs:
            self.error(f"cannot index struct '{base.kind}'", node)
        self.check_array_index(base, idx)
        self.emit("ld8", t, base.slot, idx.slot)
        if base.kind.startswith("arr_of:"):
            return Val(t, base.kind[len("arr_of:"):])
        return Val(t, INT)

    def array_lit(self, node):
        items = [self.expr(i) for i in node.items]
        arr = self.temp()
        count = self.temp()
        self.use("__t_alloc")
        self.emit("imm", count, len(items))
        self.emit("aloc", arr, count)
        for i, item in enumerate(items):
            slot = self.temp()
            self.emit("imm", slot, i)
            self.emit("st8", arr, slot, item.slot)
        # A literal with one element kind is typed, so `for x in [..]` and
        # `append` know what its slots hold; a mixed literal stays untyped.
        elem = items[0].kind if items else UNKNOWN
        if any(item.kind != elem for item in items):
            elem = UNKNOWN
        if elem in (INT, STR, FLOAT) or elem in self.ctx.structs:
            return Val(arr, "arr_of:" + elem)
        return Val(arr, ARR)

    # -- functions --------------------------------------------------------
    def lower_func(self, fn, ret_kind):
        self.fname = fn.name
        self.ins = []
        self.nperm = 0
        self.ntemp = 0
        self.max_temp = 0
        self.scopes = [dict(self.base_scope)]
        self.loops = []
        self.cur_ret = ret_kind
        for index, pname in enumerate(fn.params):
            ptype = fn.param_types[index] if index < len(fn.param_types) else ""
            self.declare(pname, self.new_perm(), type_kind(ptype, self.ctx.structs))
        for s in fn.body.stmts:
            self.stmt(s)
        return FuncIR(fn.name, fn.params, self.nperm, self.max_temp,
                      self.ins, ret_kind)


def lower_program(program, filename="<input>", opt=True):
    structs = {}
    for decl in program.structs:
        if decl.name in structs:
            raise TlangError(f"struct '{decl.name}' defined twice", filename,
                             decl.line, decl.col)
        if decl.name in BUILTINS:
            raise TlangError(
                f"struct name '{decl.name}' is a builtin", filename,
                decl.line, decl.col)
        if len(set(decl.fields)) != len(decl.fields):
            raise TlangError(f"struct '{decl.name}' has duplicate fields",
                             filename, decl.line, decl.col)
        structs[decl.name] = decl.fields

    # Field type annotations: "" (unknown), int, str, or a struct name.
    field_kinds = {}
    for decl in program.structs:
        kinds = {}
        for fname, ftype in zip(decl.fields, decl.field_types):
            kind = type_kind(ftype, structs)
            if kind is None:
                raise TlangError(
                    f"unknown type '{ftype}' for field '{fname}'", filename,
                    decl.line, decl.col)
            kinds[fname] = kind
        field_kinds[decl.name] = kinds

    funcs = {}
    for fn in program.funcs:
        if fn.name in funcs:
            raise TlangError(f"function '{fn.name}' defined twice", filename,
                             fn.line, fn.col)
        if fn.name in BUILTINS:
            raise TlangError(
                f"function name '{fn.name}' is a builtin", filename,
                fn.line, fn.col)
        funcs[fn.name] = fn

    if "main" not in funcs:
        raise TlangError("program needs a 'fn main()'", filename, 1, 1)
    if funcs["main"].params:
        raise TlangError("'main' takes no parameters", filename,
                         funcs["main"].line, funcs["main"].col)

    ctx = Context(structs, funcs, {}, filename, field_kinds)
    # Globals are visible from every function, so return inference can see
    # them. Later globals are not in scope yet, matching lowering.
    global_scope = {}
    for node in program.globals:
        global_scope[node.name] = infer_expr_kind(
            node.expr, dict(global_scope), ctx)
    for fn in program.funcs:
        for tname in list(fn.param_types) + [fn.ret_type]:
            if tname and type_kind(tname, structs) is None:
                raise TlangError(f"unknown type '{tname}'", filename,
                                 fn.line, fn.col)
        ctx.ret_kinds[fn.name] = (type_kind(fn.ret_type, structs)
                                  if fn.ret_type
                                  else infer_ret_kind(fn, ctx, global_scope))

    # Only emit functions reachable from main or from a global initializer.
    # Globals are lowered into __init, so a helper they call is a root even
    # when nothing in main calls it.
    reachable = set()
    worklist = ["main"]
    for node in program.globals:
        for sub in walk(node.expr):
            if isinstance(sub, A.Call) and sub.name in funcs:
                worklist.append(sub.name)
    while worklist:
        name = worklist.pop()
        if name in reachable or name not in funcs:
            continue
        reachable.add(name)
        for node in walk(funcs[name].body):
            if isinstance(node, A.Call) and node.name in funcs:
                worklist.append(node.name)

    strings = {}
    runtime_used = set()
    irs = []

    # Globals live in static storage and are visible from every function.
    # They are encoded as negative slots: global i is slot -(i + 1).
    globals_scope = {}
    if program.globals:
        init = Lowerer(ctx, strings, runtime_used)
        init.fname = "__init"
        for index, node in enumerate(program.globals):
            if node.name in globals_scope:
                raise TlangError(f"global '{node.name}' defined twice",
                                 filename, node.line, node.col)
            value = init.expr(node.expr)
            init.emit("mov", -1 - index, value.slot)
            entry = [-1 - index, value.kind]
            globals_scope[node.name] = entry
            init.scopes[0][node.name] = entry
        irs.append(FuncIR("__init", [], init.nperm, init.max_temp, init.ins,
                          INT))

    for fn in program.funcs:
        if fn.name not in reachable:
            # The self-hosted compiler type-checks every function it parses,
            # including dead ones. Lower the function into a throwaway context
            # so both compilers accept and reject the same programs, without
            # pulling its strings or runtime helpers into the binary.
            checker = Lowerer(ctx, {}, set(), globals_scope)
            checker.lower_func(fn, ctx.ret_kinds.get(fn.name, UNKNOWN))
            continue
        lowerer = Lowerer(ctx, strings, runtime_used, globals_scope)
        irs.append(lowerer.lower_func(fn, ctx.ret_kinds.get(fn.name, UNKNOWN)))

    module = Module(irs, strings, runtime_used, len(program.globals))
    return optimize_module(module) if opt else module
