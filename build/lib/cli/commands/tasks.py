"""Task commands: submit, list, show, cancel, logs."""

import json

import typer
from rich.console import Console
from rich.table import Table

from ..client import api_get, api_post
from ..display.formatting import status_icon, status_color

app = typer.Typer()
console = Console()


@app.command()
def submit(spec_file: str = typer.Argument(..., help="Path to task spec JSON")):
    """Submit a task specification."""
    result = api_post("/api/tasks", {"spec_file": spec_file})
    console.print(f"[green]Submitted[/] {result['task_id']} → {result['status']}")


@app.command()
def list(
    status: str = typer.Option(None, help="Filter by status"),
    class_: str = typer.Option(None, "--class", help="Filter by class"),
):
    """List tasks."""
    params = {}
    if status:
        params["status"] = status
    if class_:
        params["class_"] = class_
    data = api_get("/api/tasks", **params)
    table = Table(title="Tasks")
    table.add_column("Task ID")
    table.add_column("Status")
    table.add_column("Submitted")
    for t in data:
        s = t["status"]
        table.add_row(
            t["task_id"],
            f"[{status_color(s)}]{status_icon(s)} {s}[/]",
            t.get("submitted_at", "?"),
        )
    console.print(table)


@app.command()
def show(task_id: str = typer.Argument(...), diff: bool = typer.Option(False, "--diff")):
    """Show task details."""
    data = api_get(f"/api/tasks/{task_id}")
    console.print(f"[bold]Task:[/] {data['task_id']}")
    console.print(f"[bold]Status:[/] [{status_color(data['status'])}]{data['status']}[/]")
    if data.get("verdict"):
        console.print(f"[bold]Verdict:[/] {data['verdict']}")
    if data.get("landed_sha"):
        console.print(f"[bold]Landed:[/] {data['landed_sha']}")
    console.print(f"[bold]Iterations:[/] {len(data['iterations'])}")
    if diff and data.get("diff"):
        console.print(f"\n[bold cyan]Diff:[/]")
        console.print(data["diff"])


@app.command()
def cancel(task_id: str = typer.Argument(...)):
    """Cancel a running or queued task."""
    result = api_post(f"/api/tasks/{task_id}/cancel")
    console.print(f"[yellow]Cancelled[/] {result['task_id']}")


@app.command()
def logs(task_id: str = typer.Argument(...), follow: bool = typer.Option(False, "-f", help="Follow live (WebSocket)")):
    """View per-task log."""
    import asyncio
    from ..client import get_ws_url

    if follow:
        import websockets

        async def _follow():
            url = get_ws_url(f"/ws/tasks/{task_id}")
            async with websockets.connect(url) as ws:
                async for msg in ws:
                    if isinstance(msg, bytes):
                        console.print(str(msg, "utf-8"), end="")
                    elif isinstance(msg, str):
                        try:
                            data = json.loads(msg)
                            if data.get("done"):
                                console.print(f"\n[bold]Task finished: {data['status']}[/]")
                                break
                        except json.JSONDecodeError:
                            console.print(msg, end="")
        asyncio.run(_follow())
    else:
        # Read the log file directly
        from pathlib import Path
        from server.config import LOGS_DIR
        log_path = LOGS_DIR / f"{task_id}.log"
        if log_path.exists():
            console.print(log_path.read_text())
        else:
            console.print(f"[dim]No log for {task_id}[/]")
