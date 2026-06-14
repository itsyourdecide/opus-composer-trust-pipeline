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
from ophar.paths import reset_root_cache


def _ophar_mcp_command() -> str:
    candidates = [
        shutil.which("ophar-mcp"),
        Path(sys.executable).resolve().parent / "ophar-mcp",
        Path(sys.prefix) / "bin" / "ophar-mcp",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return str(Path(candidate).resolve())
    return "ophar-mcp"


def _configure_cursor(command: str) -> tuple[str, str]:
    path = Path.home() / ".cursor" / "mcp.json"
    data: dict = {"mcpServers": {}}
    if path.exists():
        try:
            data = json.loads(path.read_text())
        except json.JSONDecodeError:
            data = {"mcpServers": {}}
    servers = data.setdefault("mcpServers", {})
    servers["ophar"] = {"command": command, "args": []}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")
    return "cursor", str(path)


def _configure_claude(command: str) -> tuple[str, str]:
    claude = shutil.which("claude")
    if not claude:
        return "claude", "skipped (claude CLI not found)"

    subprocess.run(
        [claude, "mcp", "remove", "ophar"],
        capture_output=True,
        text=True,
    )
    proc = subprocess.run(
        [claude, "mcp", "add", "--scope", "user", "ophar", "--", command],
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

    mcp_cmd = _ophar_mcp_command()
    print(f"MCP command:    {mcp_cmd}")

    results: dict[str, str] = {}
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = {
            pool.submit(_configure_cursor, mcp_cmd): "cursor",
            pool.submit(_configure_claude, mcp_cmd): "claude",
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
    print("Requirements for real executor runs: git, bash, jq, cursor-agent CLI")


if __name__ == "__main__":
    main()
