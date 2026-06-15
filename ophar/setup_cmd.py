"""One-shot setup: bootstrap data dir + register MCP in Cursor and Claude Code."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from ophar.bootstrap import bootstrap
from ophar.launcher import format_mcp_command, mcp_launch
from ophar.paths import reset_root_cache


def _configure_cursor() -> tuple[str, str]:
    path = Path.home() / ".cursor" / "mcp.json"
    data: dict = {"mcpServers": {}}
    if path.exists():
        try:
            data = json.loads(path.read_text())
        except json.JSONDecodeError:
            data = {"mcpServers": {}}
    command, args = mcp_launch()
    servers = data.setdefault("mcpServers", {})
    servers["ophar"] = {"command": command, "args": args}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")
    return "cursor", str(path)


def _configure_claude() -> tuple[str, str]:
    claude = shutil.which("claude")
    if not claude:
        return "claude", "skipped (claude CLI not found)"

    command, args = mcp_launch()
    subprocess.run(
        [claude, "mcp", "remove", "ophar"],
        capture_output=True,
        text=True,
    )
    proc = subprocess.run(
        [claude, "mcp", "add", "--scope", "user", "ophar", "--", command, *args],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        return "claude", f"failed: {err or proc.returncode}"
    return "claude", "registered (user scope)"


def main() -> None:
    print("Ophar setup")
    print("-----------")

    home = bootstrap()
    reset_root_cache()
    os.environ["OPHAR_HOME"] = str(home)
    print(f"Data directory: {home}")
    print(f"MCP command:    {format_mcp_command()}")

    results: dict[str, str] = {}
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = {
            pool.submit(_configure_cursor): "cursor",
            pool.submit(_configure_claude): "claude",
        }
        for fut in as_completed(futures):
            key, msg = fut.result()
            results[key] = msg

    print()
    print(f"Cursor: {results.get('cursor', 'unknown')}")
    print(f"Claude: {results.get('claude', 'unknown')}")
    print()
    print("Next steps:")
    print("  - Reload Cursor (Settings → MCP) or restart the IDE")
    print("  - Or run: claude")
    print()
    print("Tip: python -m ophar setup  and  python -m ophar mcp  work without PATH.")
    print("Requirements for real executor runs: git, bash, jq, cursor-agent CLI")


if __name__ == "__main__":
    main()
