"""AST node definitions.  Every node carries a source position for errors."""

from dataclasses import dataclass, field


@dataclass
class Node:
    line: int = 0
    col: int = 0


@dataclass
class Program(Node):
    structs: list = field(default_factory=list)
    funcs: list = field(default_factory=list)
    globals: list = field(default_factory=list)
    consts: list = field(default_factory=list)


@dataclass
class Global(Node):
    name: str = ""
    expr: Node = None


@dataclass
class Const(Node):
    """A compile-time name for an int or string literal; it has no storage."""
    name: str = ""
    expr: Node = None


@dataclass
class StructDecl(Node):
    name: str = ""
    fields: list = field(default_factory=list)
    field_types: list = field(default_factory=list)


@dataclass
class Func(Node):
    name: str = ""
    params: list = field(default_factory=list)
    param_types: list = field(default_factory=list)
    ret_type: str = ""
    body: "Block" = None


@dataclass
class Block(Node):
    stmts: list = field(default_factory=list)


@dataclass
class Let(Node):
    name: str = ""
    expr: Node = None


@dataclass
class Assign(Node):
    target: Node = None
    expr: Node = None


@dataclass
class If(Node):
    cond: Node = None
    then: Node = None
    els: Node = None


@dataclass
class While(Node):
    cond: Node = None
    body: Node = None


@dataclass
class DoWhile(Node):
    """`do { } while cond` -- the body runs once before the first test."""
    cond: Node = None
    body: Node = None


@dataclass
class Loop(Node):
    """`loop { }` -- an unconditional loop; leave it with `break`."""
    body: Node = None


@dataclass
class For(Node):
    """`for i in start..end { }` -- end is evaluated once, before the loop."""
    name: str = ""
    start: Node = None
    end: Node = None
    body: Node = None


@dataclass
class Case(Node):
    """One `case v1, v2 { }` arm of a switch; values are literals."""
    values: list = field(default_factory=list)
    body: "Block" = None


@dataclass
class Switch(Node):
    """`switch value { case 1 { } else { } }` -- no fallthrough."""
    expr: Node = None
    cases: list = field(default_factory=list)
    default: "Block" = None


@dataclass
class ForEach(Node):
    """`for x in value { }` -- value is a string or an array, read once."""
    name: str = ""
    items: Node = None
    body: Node = None


@dataclass
class Return(Node):
    expr: Node = None


@dataclass
class Break(Node):
    pass


@dataclass
class Continue(Node):
    pass


@dataclass
class ExprStmt(Node):
    expr: Node = None


@dataclass
class Num(Node):
    value: int = 0


@dataclass
class Float(Node):
    """A decimal literal represented as mantissa * 10**exp."""
    mantissa: int = 0
    exp: int = 0


@dataclass
class Str(Node):
    value: bytes = b""


@dataclass
class Name(Node):
    name: str = ""


@dataclass
class Bin(Node):
    op: str = ""
    left: Node = None
    right: Node = None


@dataclass
class Un(Node):
    op: str = ""
    expr: Node = None


@dataclass
class Call(Node):
    name: str = ""
    args: list = field(default_factory=list)


@dataclass
class Index(Node):
    base: Node = None
    idx: Node = None


@dataclass
class Field(Node):
    base: Node = None
    name: str = ""


@dataclass
class ArrayLit(Node):
    items: list = field(default_factory=list)
