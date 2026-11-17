"""The intermediate representation.

Three-address code with virtual registers.  Temps are numbered from TEMP_BASE so
they never collide with permanent (named) slots, which are allocated upward as
the function is lowered.
"""

TEMP_BASE = 1 << 20


class FuncIR:
    def __init__(self, name, params, nperm, max_temp, ins, ret_kind):
        self.name = name
        self.params = params
        self.nperm = nperm
        self.max_temp = max_temp
        self.ins = ins
        self.ret_kind = ret_kind

    @property
    def nslots(self):
        return self.nperm + self.max_temp

    def format(self):
        lines = [
            f"fn {self.name}({', '.join(self.params)})  "
            f"[{self.nperm} perm + {self.max_temp} temp slots]"
        ]
        for ins in self.ins:
            parts = ["_" if x is None else str(x) for x in ins]
            lines.append("  " + " ".join(parts))
        return "\n".join(lines)


class Module:
    def __init__(self, funcs, strings, runtime_used, nglobals=0,
                 freestanding=False, entry="main", tables=None):
        self.funcs = funcs
        self.strings = strings          # label -> raw bytes
        self.tables = tables or {}      # label -> list of case-body labels
        self.runtime_used = runtime_used
        self.nglobals = nglobals
        self.freestanding = freestanding
        self.entry = entry

    def format_ir(self):
        return "\n\n".join(f.format() for f in self.funcs)
