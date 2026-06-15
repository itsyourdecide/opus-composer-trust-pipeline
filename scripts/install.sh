#!/usr/bin/env bash
# Install Ophar and register MCP (Cursor + Claude Code) in one step.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# A copied/relocated .venv keeps a working bin/python symlink but its console-script
# shebangs (pip, opctl, ophar-*) and pyvenv.cfg still point at the ORIGINAL absolute path.
# So: recreate the venv if its interpreter is dead, and otherwise drive everything through
# the venv's own python (-m pip / -m ophar) — never the stale wrapper scripts or `activate`.
# `pip install -e` then regenerates the console scripts with shebangs for THIS location.
if [[ ! -x .venv/bin/python ]] || ! .venv/bin/python -c 'import sys' 2>/dev/null; then
  rm -rf .venv
  python3 -m venv .venv
fi
PY="$ROOT/.venv/bin/python"

"$PY" -m pip install -U pip
"$PY" -m pip install -e ".[test]"
"$PY" -m ophar setup

echo ""
echo "Done. Try: opctl --help  |  python -m ophar mcp  |  reload Cursor MCP settings"
