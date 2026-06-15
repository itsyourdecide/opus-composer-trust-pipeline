"""Metrics commands — the §3 / §6.5 dashboard on top of the API.

The backend (metrics-report.sh, surfaced via /api/metrics{,/history,/classes}) already
computes the full trust + economics picture; this module is purely presentation. The
centerpiece is the trust panel: overclaim, the visible↔held-out gap, and caught
reward-hacks — the signals this whole pipeline exists to make visible.
"""

from __future__ import annotations

import subprocess
import time
from datetime import datetime, timezone

import typer
from rich import box
from rich.columns import Columns
from rich.console import Console, Group
from rich.live import Live
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

from ophar.paths import get_root

from ..client import api_get

# Click rewraps within a paragraph and only keeps blank-line-separated blocks apart, so
# each cheat-sheet line is its own paragraph to survive as a separate line in --help.
_HELP_EPILOG = (
    "Read top-down — trust first, then reliability, then cost.\n\n"
    "1) Overclaim / visible→held-out gap red — the executor's report can't be trusted.\n\n"
    "2) Reward-hacks > 0 — overfits were caught; inspect those tasks.\n\n"
    "3) Reliability slipping — infra/timeouts, not code quality.\n\n"
    "4) Opus tokens/task or context-proxy climbing — split tasks and checkpoint.\n\n"
    "Colors: green = ok, yellow = watch, red = act. '†' = low-confidence quantile "
    "(sample too small — lean on p50)."
)

app = typer.Typer(epilog=_HELP_EPILOG)
console = Console()


# ── formatting helpers ────────────────────────────────────────────────────────

def _pct(v: float | None) -> str:
    return "n/a" if v is None else f"{v * 100:.1f}%"


def _good(v: float | None, hi: float = 0.9, mid: float = 0.7) -> str:
    """Higher is better (work_ok, dispatch ok, held-out pass)."""
    if v is None:
        return "[dim]n/a[/]"
    color = "green" if v >= hi else "yellow" if v >= mid else "red"
    return f"[{color}]{_pct(v)}[/]"


def _bad(v: float | None, lo: float = 0.05, mid: float = 0.2) -> str:
    """Lower is better (overclaim, timeout, bad-json, failed-before-completion)."""
    if v is None:
        return "[dim]n/a[/]"
    color = "green" if v <= lo else "yellow" if v <= mid else "red"
    return f"[{color}]{_pct(v)}[/]"


def _bar(frac: float | None, width: int = 12) -> str:
    if frac is None:
        return "[dim]" + "░" * width + "[/]"
    frac = max(0.0, min(1.0, frac))
    filled = round(frac * width)
    color = "green" if frac >= 0.9 else "yellow" if frac >= 0.7 else "red"
    return f"[{color}]" + "█" * filled + "[/][dim]" + "░" * (width - filled) + "[/]"


def _num(v) -> str:
    if v is None:
        return "[dim]?[/]"
    if isinstance(v, int):
        return f"{v:,}"
    return str(v)


# ── panels ────────────────────────────────────────────────────────────────────

def _trust_panel(r: dict) -> Panel:
    """§6.5 — the reason the pipeline exists. Overclaim + visible↔held-out gap."""
    grid = Table.grid(padding=(0, 2))
    grid.add_column(justify="left", style="bold")
    grid.add_column(justify="right")
    grid.add_column(justify="left")

    overclaim = r.get("overclaim_rate")
    visible = r.get("visible_pass_rate")
    held = r.get("held_out_pass_rate")
    hacks = r.get("reward_hack_count", 0) or 0

    grid.add_row("Overclaim", _bad(overclaim),
                 "[dim]claimed ok, wasn't[/]" if (overclaim or 0) > 0.05 else "")
    grid.add_row("Visible pass", _good(visible), "")

    if held is None:
        grid.add_row("Held-out pass", "[dim]n/a[/]", "[dim]no held-out runs[/]")
    else:
        gap = (visible or 0) - held
        if gap >= 0.15:
            gap_str = f"[red]▼ {gap * 100:.1f}pp gap → overfitting[/]"
        elif gap >= 0.05:
            gap_str = f"[yellow]▼ {gap * 100:.1f}pp gap[/]"
        else:
            gap_str = "[green]aligned[/]"
        grid.add_row("Held-out pass", _good(held),
                     f"{gap_str}  [dim](n={r.get('held_out_runs', 0)})[/]")

    hack_str = "[green]0[/]" if hacks == 0 else f"[red]{hacks}[/]"
    grid.add_row("Reward-hacks", hack_str, "[dim]caught overfits[/]")

    return Panel(grid, title="[bold]Trust signals[/] [dim]§6.5[/]",
                 border_style="magenta", box=box.ROUNDED, padding=(1, 2))


def _throughput_panel(r: dict) -> Panel:
    grid = Table.grid(padding=(0, 2))
    grid.add_column(justify="left", style="bold")
    grid.add_column(justify="right")
    grid.add_column(justify="left")

    work_ok = r.get("work_ok_rate")
    grid.add_row("Runs", _num(r.get("runs")), "")
    grid.add_row("Work OK", _good(work_ok), _bar(work_ok))
    grid.add_row("Dispatch OK", _good(r.get("dispatch_ok_rate")), "")
    grid.add_row("Composer tok", _num(r.get("composer_tokens_total")), "[dim]total[/]")

    return Panel(grid, title="[bold]Throughput[/]",
                 border_style="cyan", box=box.ROUNDED, padding=(1, 2))


def _reliability_panel(rel: dict) -> Panel:
    grid = Table.grid(padding=(0, 2))
    grid.add_column(justify="left", style="bold")
    grid.add_column(justify="right")

    completed, n = rel.get("completed", 0), rel.get("n", 0)
    grid.add_row("Completed", f"{_num(completed)}[dim]/{n}[/]")
    grid.add_row("Timeout", _bad(rel.get("timeout_rate")))
    grid.add_row("Bad JSON", _bad(rel.get("invalid_json_rate")))
    grid.add_row("Failed", _bad(rel.get("failed_before_completion_rate")))

    return Panel(grid, title="[bold]Reliability[/] [dim]§3.2[/]",
                 border_style="blue", box=box.ROUNDED, padding=(1, 2))


def _quantiles_table(q: dict) -> Table:
    table = Table(title="[bold]Cost & latency[/] [dim]§3 — completed runs only[/]",
                  box=box.SIMPLE_HEAD, title_justify="left", expand=True)
    table.add_column("Metric")
    table.add_column("p50", justify="right")
    table.add_column("p90", justify="right")
    table.add_column("p95", justify="right")
    table.add_column("mean", justify="right")
    table.add_column("n", justify="right", style="dim")

    def _q(v) -> str:
        return "[dim]—[/]" if v is None else str(v)

    rows = [
        ("Wall clock (s)", q.get("wall_clock_s", {})),
        ("Attempts", q.get("attempts", {})),
        ("Composer tokens", q.get("composer_tokens", {})),
    ]
    flagged = False
    for label, m in rows:
        if not m:
            continue
        n = m.get("n", 0) or 0
        p90, p95 = _q(m.get("p90")), _q(m.get("p95"))
        # Only flag low-confidence when there is actually data behind the quantile.
        if n and m.get("low_confidence_p90"):
            p90 += " [dim]†[/]"
            flagged = True
        if n and m.get("low_confidence_p95"):
            p95 += " [dim]†[/]"
            flagged = True
        mean = m.get("mean")
        mean_str = f"{mean:.1f}" if isinstance(mean, (int, float)) else "[dim]—[/]"
        table.add_row(label, _q(m.get("p50")), p90, p95, mean_str, str(n))

    if flagged:
        table.caption = "[dim]† low-confidence: sample below P90/P95 min-n — indicator, not verdict[/]"
        table.caption_justify = "left"
    return table


def _opus_panel(opus: dict) -> Panel:
    grid = Table.grid(padding=(0, 2))
    grid.add_column(justify="left", style="bold")
    grid.add_column(justify="right")
    grid.add_column(justify="left", style="dim")

    grid.add_row("Refine calls", _num(opus.get("opus_refine_calls")), "")
    grid.add_row("Tokens total", _num(opus.get("opus_tokens_total")), "")
    grid.add_row("Tokens/task",
                 f"{_num(opus.get('opus_tokens_per_task_p50'))}"
                 f" [dim]/[/] {_num(opus.get('opus_tokens_per_task_p90'))}",
                 "p50 / p90")
    grid.add_row("Turns/task",
                 f"{_num(opus.get('opus_turns_p50'))}"
                 f" [dim]/[/] {_num(opus.get('opus_turns_p90'))}",
                 "p50 / p90")
    grid.add_row("Context proxy", _num(opus.get("context_proxy_chars_p90")), "chars p90")

    return Panel(grid, title="[bold]Opus window[/] [dim]§3 economics[/]",
                 border_style="green", box=box.ROUNDED, padding=(1, 2))


def _render_dashboard(data: dict) -> Group:
    r = data.get("raw", data)
    if r.get("error"):
        return Group(Panel(f"[red]metrics error:[/] {r['error']}", border_style="red"))

    parts: list = [
        Columns([_trust_panel(r), _throughput_panel(r)], equal=True, expand=True),
        Columns(
            [_reliability_panel(r.get("reliability", {})), _quantiles_table(r.get("quantiles", {}))],
            expand=True,
        ),
    ]
    if r.get("opus"):
        parts.append(_opus_panel(r["opus"]))

    stamp = datetime.now(timezone.utc).strftime("%H:%M:%SZ")
    parts.append(Text(f"self-baseline over {r.get('runs', '?')} runs · {stamp}",
                      style="dim", justify="right"))
    return Group(*parts)


# ── tables for subcommands ────────────────────────────────────────────────────

def _classes_table(data: dict) -> Table:
    table = Table(title="[bold]By task class[/]", box=box.SIMPLE_HEAD, title_justify="left")
    table.add_column("Class")
    table.add_column("N", justify="right")
    table.add_column("Accepted", justify="right")
    table.add_column("Rejected", justify="right")
    table.add_column("Accept rate", justify="right")
    table.add_column("", justify="left")

    for cls, c in sorted(data.items()):
        n = c.get("n", 0) or 0
        acc = c.get("accepted", 0) or 0
        rej = c.get("rejected", 0) or 0
        rate = acc / n if n else None
        table.add_row(cls, str(n), f"[green]{acc}[/]", f"[red]{rej}[/]" if rej else "0",
                      _good(rate), _bar(rate, width=10))
    if not data:
        table.add_row("[dim]no data[/]", "", "", "", "", "")
    return table


def _history_table(rows: list) -> Table:
    table = Table(title="[bold]Daily history[/]", box=box.SIMPLE_HEAD, title_justify="left")
    table.add_column("Date")
    table.add_column("Runs", justify="right")
    table.add_column("Accepted", justify="right")
    table.add_column("Rejected", justify="right")
    table.add_column("Accept rate", justify="right")
    table.add_column("Tokens", justify="right")
    table.add_column("", justify="left")

    for row in rows:
        runs = row.get("runs", 0) or 0
        acc = row.get("accepted", 0) or 0
        rej = row.get("rejected", 0) or 0
        rate = acc / runs if runs else None
        table.add_row(
            row.get("date", "?"), str(runs), f"[green]{acc}[/]",
            f"[red]{rej}[/]" if rej else "0", _good(rate),
            _num(row.get("tokens_total")), _bar(rate, width=10),
        )
    if not rows:
        table.add_row("[dim]no data[/]", "", "", "", "", "", "")
    return table


# ── commands ──────────────────────────────────────────────────────────────────

def _emit_dashboard(json_: bool, watch: bool) -> None:
    if json_:
        console.print_json(data=api_get("/api/metrics"))
        return
    if watch:
        try:
            with Live(refresh_per_second=4, console=console) as live:
                while True:
                    live.update(_render_dashboard(api_get("/api/metrics")))
                    time.sleep(3)
        except KeyboardInterrupt:
            console.print("[dim]stopped[/]")
        return
    console.print(_render_dashboard(api_get("/api/metrics")))


@app.callback(invoke_without_command=True)
def dashboard(
    ctx: typer.Context,
    json_: bool = typer.Option(False, "--json", help="Raw JSON output"),
    watch: bool = typer.Option(False, "--watch", help="Live refreshing dashboard"),
):
    """Trust + economics dashboard (run with no subcommand)."""
    if ctx.invoked_subcommand is not None:
        return
    _emit_dashboard(json_, watch)


@app.command()
def show(
    json_: bool = typer.Option(False, "--json", help="Raw JSON output"),
    watch: bool = typer.Option(False, "--watch", help="Live refreshing dashboard"),
):
    """Alias for the bare dashboard (back-compat with `opctl metrics show`)."""
    _emit_dashboard(json_, watch)


@app.command()
def classes(json_: bool = typer.Option(False, "--json", help="Raw JSON output")):
    """Accept/reject breakdown per task class."""
    data = api_get("/api/metrics/classes")
    if json_:
        console.print_json(data=data)
        return
    console.print(_classes_table(data))


@app.command()
def history(json_: bool = typer.Option(False, "--json", help="Raw JSON output")):
    """Daily run history (accept rate + token spend per day)."""
    rows = api_get("/api/metrics/history")
    if json_:
        console.print_json(data=rows)
        return
    console.print(_history_table(rows))


@app.command()
def clear(
    purge: bool = typer.Option(False, "--purge", help="Truncate without archiving (irreversible)"),
    yes: bool = typer.Option(False, "--yes", "-y", help="Skip the confirmation prompt"),
):
    """Reset metrics telemetry (runs/metrics.jsonl + opus-metrics.jsonl).

    Thin wrapper over harness/clear-metrics.sh: archives a timestamped copy under
    runs/archive/ (unless --purge) then truncates. Does not touch the ledger or STATE.md.
    """
    script = get_root() / "harness" / "clear-metrics.sh"
    args = ["bash", str(script)]
    if purge:
        args.append("--purge")
    if yes:
        args.append("--yes")
    # Inherit stdio so the script's confirmation prompt and digest reach the terminal.
    raise typer.Exit(subprocess.run(args).returncode)
