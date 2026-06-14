"""CLI for Ophar — opctl."""

import typer

from .commands import tasks, metrics, system, settings

app = typer.Typer(help="Ophar CLI (opctl)")
app.add_typer(tasks.app, name="tasks", help="Submit and manage tasks")
app.add_typer(metrics.app, name="metrics", help="Metrics dashboard")
app.add_typer(system.app, name="system", help="Server lifecycle and reconcile")

# Flat commands
app.command()(settings.settings_get)
app.command(name="settings-set")(settings.settings_set)
app.command(name="serve")(system.serve)
app.command(name="stop")(system.stop)

if __name__ == "__main__":
    app()
