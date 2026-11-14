#!/usr/bin/env bash
# Build taarch64. Uses the stage-0 driver by default; `--selfhost` builds it
# with Build/tcomp (see Tools/selfhost.sh in the repository root).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
src="$here/src/taarch64.tl"
out="$here/taarch64"

cd "$root"

if [ "${1:-}" = "--selfhost" ]; then
  if [ ! -x Build/tcomp ]; then
    echo "taarch64: Build/tcomp not found; run Tools/selfhost.sh first" >&2
    exit 1
  fi
  Build/tcomp "$src" > "$here/taarch64.s"
  as --64 -mx86-used-note=no -o "$here/taarch64.o" "$here/taarch64.s"
  ld -s -z noseparate-code --build-id=none -o "$out" "$here/taarch64.o"
  python3 -m Bootstrap.elf "$out" >/dev/null
  rm -f "$here/taarch64.s" "$here/taarch64.o"
  echo "taarch64: $out ($(stat -c%s "$out") bytes, self-hosted)"
else
  ./tcomp build "$src" -o "$out"
fi
