"""Console entry: stdio MCP server (Cursor, Claude Code, any MCP client)."""

from __future__ import annotations

import asyncio
import importlib.util
import sys


def _load_mcp_main():
    from ophar.paths import get_root

    root = get_root()
    script = root / "harness" / "mcp_server.py"
    if not script.is_file():
        raise RuntimeError(f"MCP server not found: {script}")

    spec = importlib.util.spec_from_file_location("ophar_mcp_server", script)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load MCP server from {script}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["ophar_mcp_server"] = module
    spec.loader.exec_module(module)
    return module.main


def main() -> None:
    mcp_main = _load_mcp_main()
    asyncio.run(mcp_main())


if __name__ == "__main__":
    main()
