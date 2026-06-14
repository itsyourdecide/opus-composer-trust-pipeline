"""System commands: serve, stop, status, reconcile.

The orchestrator is NOT a CLI command - it is reached through the `ophar`
MCP server (instructions + pipeline:// resources + tools). Run `claude` and the
registered MCP server makes the session an orchestrator. There is no `opctl chat`.
"""

import os
import signal

import typer
from rich.console import Console
from rich.table import Table

from ..client import get_base_url, api_get, api_post

app = typer.Typer()
console = Console()


@app.command()
def serve():
    """Start the API server explicitly (normally auto-spawned)."""
    base = get_base_url()
    console.print(f"[green]Server running at {base}[/]")


@app.command()
def stop():
    """Stop the API server."""
    from ..client import _read_lockfile, LOCKFILE
    lock = _read_lockfile()
    if lock:
        try:
            os.kill(lock["pid"], signal.SIGTERM)
            console.print(f"[yellow]Stopped server (pid {lock['pid']})[/]")
        except OSError:
            console.print("[dim]Server already stopped[/]")
        LOCKFILE.unlink(missing_ok=True)
    else:
        console.print("[dim]No server running[/]")


@app.command()
def status():
    """Show pipeline status."""
    base = get_base_url()
    metrics = api_get("/api/metrics")
    tasks_data = api_get("/api/tasks")
    raw = metrics["raw"]
    active_count = sum(1 for t in tasks_data if t["status"] in ("queued", "running"))

    table = Table(title="Ophar status")
    table.add_column("Key")
    table.add_column("Value")
    table.add_row("[bold]API server[/]", f"[green]running ({base})[/]")
    table.add_row("[bold]Active tasks[/]", f"{active_count}")
    table.add_row("[bold]Total runs[/]", str(raw.get("runs", "?")))
    table.add_row("[bold]Work OK[/]", f"{(raw.get('work_ok_rate', 0) or 0) * 100:.1f}%")
    table.add_row("[bold]Overclaim[/]", f"{(raw.get('overclaim_rate', 0) or 0) * 100:.1f}%")
    table.add_row("[bold]Composer tokens[/]", f"{raw.get('composer_tokens_total', 0):,}")
    opus = raw.get("opus", {}) or {}
    if opus:
        table.add_row("[bold]Opus tokens[/]", f"{opus.get('opus_tokens_total', 0):,}")
    console.print(table)


@app.command()
def reconcile():
    """Run reconcile.sh against STATE.md claims."""
    result = api_post("/api/state/reconcile")
    d = result.get("discrepancies", "?")
    c = result.get("checked", "?")
    color = "green" if d == 0 else "red"
    console.print(f"[{color}]Checked {c} claims, {d} discrepancies[/]")

