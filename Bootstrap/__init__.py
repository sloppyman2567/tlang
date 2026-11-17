"""Stage-0 tcomp: the tlang compiler written in Python.

This exists only to build the self-hosted compiler (tcomp.tl).  Once the
fixed point holds it can be deleted.
"""

import os

# VERSION is the single source of truth; the self-hosted compiler gets the
# same value through the generated Runtime/version_gen.tl module.
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       os.pardir, "VERSION"), encoding="utf-8") as _fh:
    __version__ = _fh.read().strip()
