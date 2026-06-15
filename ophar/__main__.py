"""Cross-platform CLI: works without Scripts/bin on PATH (Windows-friendly)."""

from __future__ import annotations

import sys

_USAGE = """\
usage: python -m ophar <command>

commands:
  setup   Bootstrap data dir and register MCP (Cursor + Claude Code)
  mcp     Run the stdio MCP server
  help    Show this message

Quick start:
  pip install ophar
  python -m ophar setup
"""


def main(argv: list[str] | None = None) -> None:
    args = list(argv if argv is not None else sys.argv[1:])
    if not args or args[0] in {"-h", "--help", "help"}:
        print(_USAGE, end="")
        return

    cmd = args[0]
    if cmd == "setup":
        from ophar.setup_cmd import main as setup_main

        setup_main()
        return
    if cmd == "mcp":
        from ophar.mcp_entry import main as mcp_main

        mcp_main()
        return

    print(f"Unknown command: {cmd}\n", file=sys.stderr)
    print(_USAGE, end="", file=sys.stderr)
    raise SystemExit(1)


if __name__ == "__main__":
    main()
