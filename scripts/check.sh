#!/usr/bin/env bash
# Quality gate: sourcemap + luau-lsp type check + selene lint.
set -euo pipefail
cd "$(dirname "$0")/.."

DEFS="globalTypes.d.luau"
if [ ! -f "$DEFS" ]; then
  echo "Fetching Roblox type definitions..."
  curl -fsSL -o "$DEFS" \
    "https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau"
fi

echo "==> sourcemap"
rojo sourcemap default.project.json -o sourcemap.json

echo "==> luau-lsp analyze"
luau-lsp analyze --sourcemap=sourcemap.json --defs="$DEFS" src

echo "==> selene"
selene src

echo "All checks passed."
