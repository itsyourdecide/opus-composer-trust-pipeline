"""Metrics commands."""

import time

import typer
from rich.console import Console
from rich.live import Live
from rich.table import Table
from rich.panel import Panel

from ..client import api_get

app = typer.Typer()
console = Console()


def _render_metrics_table(data: dict) -> Table:
    raw = data["raw"]
    table = Table(title="Metrics Snapshot")
    table.add_column("Metric")
    table.add_column("Value")
    table.add_row("[bold]Runs[/]", str(raw.get("runs", "?")))
    table.add_row("[bold]Work OK Rate[/]", f"{(raw.get('work_ok_rate', 0) or 0) * 100:.1f}%")
    table.add_row("[bold]Overclaim Rate[/]", f"{(raw.get('overclaim_rate', 0) or 0) * 100:.1f}%")
    table.add_row("[bold]Composer Tokens[/]", str(raw.get("composer_tokens_total", "?")))
    q = raw.get("quantiles", {})
    wc = q.get("wall_clock_s", {})
    if wc:
        table.add_row("[bold]Wall (p50/p95)[/]", f"{wc.get('p50', '?')} / {wc.get('p95', '?')}s")
    opus = raw.get("opus", {})
    if opus:
        table.add_row("[bold]Opus Tokens Total[/]", str(opus.get("opus_tokens_total", "?")))
    return table


@app.command()
def show(
    json_: bool = typer.Option(False, "--json", help="Raw JSON output"),
    watch: bool = typer.Option(False, "--watch", help="Live refreshing dashboard"),
    classes: bool = typer.Option(False, "--classes", help="Breakdown by class"),
):
    """View metrics."""
    if classes:
        data = api_get("/api/metrics/classes")
        console.print_json(data=data)
        return
    if watch:
        with Live(refresh_per_second=0.3) as live:
            while True:
                data = api_get("/api/metrics")
                live.update(_render_metrics_table(data))
                time.sleep(3)
        return
    if json_:
        data = api_get("/api/metrics")
        console.print_json(data=data)
        return
    data = api_get("/api/metrics")
    console.print(_render_metrics_table(data))
