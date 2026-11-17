"""Package metadata for the tcomp driver and generators.

`__version__` is read from VERSION. The self-hosted compiler gets the same
value from the generated Runtime/version_gen.tl module.
"""

import os

# VERSION is the single source of truth; the self-hosted compiler gets the
# same value through the generated Runtime/version_gen.tl module.
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       os.pardir, "VERSION"), encoding="utf-8") as _fh:
    __version__ = _fh.read().strip()
