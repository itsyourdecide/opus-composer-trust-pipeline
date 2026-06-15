#!/usr/bin/env bash
# Commit and push Ophar changes. Review output before it runs.
# Usage: bash scripts/commit-and-push.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Repository: $ROOT"
echo "==> Branch: $(git branch --show-current)"
echo ""

# --- stage intended changes only (no dist/, no .venv/) ---
git add .gitignore
git add README.md pyproject.toml
git add ophar/__main__.py ophar/launcher.py ophar/setup_cmd.py
git add docs/mcp.cursor.json.example
git add harness/mcp_server.py
git add scripts/install.sh scripts/commit-and-push.sh

# drop accidentally tracked build/ artifacts from the repo
if git ls-files build/ | grep -q .; then
  echo "==> Removing tracked build/ from git index"
  git rm -rf --cached build/ 2>/dev/null || true
fi

echo ""
echo "==> Staged changes:"
git status -sb
echo ""
git diff --cached --stat
echo ""

if ! git diff --cached --quiet; then
  git commit -m "$(cat <<'EOF'
Add python -m ophar entrypoint for Windows-friendly install (v0.1.1).

Use `python -m ophar setup` and `python -m ophar mcp` so pip Scripts PATH
is not required. MCP config now uses sys.executable -m ophar mcp.
Ignore build/ and dist/ artifacts.
EOF
)"
  echo ""
  echo "==> Committed:"
  git log -1 --oneline
else
  echo "==> Nothing to commit (already clean or nothing staged)."
  exit 0
fi

echo ""
echo "==> Pushing to origin/main..."
git push origin main
echo ""
echo "Done. Next: create GitHub Release v0.1.1 to publish to PyPI."
