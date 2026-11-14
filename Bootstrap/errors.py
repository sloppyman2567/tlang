"""Error type shared by the tlang front and back ends."""


class TlangError(Exception):
    """A user-facing compile error with source position."""

    def __init__(self, message, filename="<input>", line=0, col=0):
        self.message = message
        self.filename = filename
        self.line = line
        self.col = col
        super().__init__(self._format())

    def _format(self):
        if self.line:
            return f"{self.filename}:{self.line}:{self.col}: error: {self.message}"
        return f"{self.filename}: error: {self.message}"

    def remap(self, source):
        """Turn a virtual line from an expanded import tree into its real one."""
        if not self.line:
            return
        path, line = source.locate(self.line)
        if path:
            self.filename, self.line = path, line
            self.args = (self._format(),)
