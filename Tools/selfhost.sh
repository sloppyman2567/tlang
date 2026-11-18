#!/usr/bin/env bash
# Bootstrap tcomp: build the self-hosted compiler from tcomp.tl.
#
#   Tools/selfhost.sh            # Build/ -> Build/tcomp
#   Tools/selfhost.sh --verify   # also prove the fixed point
#
# Stage 1 is the checked-in Tools/tcomp-seed. The staging, linking and
# fixed-point logic lives in Tools/selfhost.py so CI and Tests/fixedpoint.py
# use the same implementation.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
exec python3 "$root/Tools/selfhost.py" "$@"
