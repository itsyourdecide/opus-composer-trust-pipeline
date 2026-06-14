"""Settings commands."""

import typer
from rich.console import Console

from ..client import api_get, api_put

console = Console()


def settings_get():
    """Show current settings."""
    data = api_get("/api/settings")
    for k, v in sorted(data.items()):
        console.print(f"[bold]{k}[/] = {v}")


def settings_set(key: str = typer.Argument(...), value: str = typer.Argument(...)):
    """Set a setting (e.g. opctl settings-set MAX_ITERATIONS 5)."""
    try:
        parsed = int(value)
    except ValueError:
        parsed = value
    result = api_put("/api/settings", {key: parsed})
    console.print(f"[green]{key}[/] → {result.get(key)}")
