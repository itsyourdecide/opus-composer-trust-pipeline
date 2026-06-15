"""Resolve how to launch the MCP server (PATH-independent)."""

from __future__ import annotations

import sys
from pathlib import Path


def mcp_launch() -> tuple[str, list[str]]:
    """Return (command, args) for MCP clients — always via python -m ophar mcp."""
    return str(Path(sys.executable).resolve()), ["-m", "ophar", "mcp"]


def format_mcp_command() -> str:
    exe, args = mcp_launch()
    return " ".join([exe, *args])
