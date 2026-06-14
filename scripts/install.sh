#!/usr/bin/env bash
# Install Ophar and register MCP (Cursor + Claude Code) in one step.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate

pip install -U pip
pip install -e ".[test]"
ophar-setup

echo ""
echo "Done. Try: opctl --help  |  ophar-mcp (stdio MCP)  |  reload Cursor MCP settings"
