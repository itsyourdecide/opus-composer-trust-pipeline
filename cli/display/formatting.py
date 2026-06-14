"""Display formatting helpers."""

STATUS_ICONS = {
    "queued": "◌",
    "running": "●",
    "accepted": "✓",
    "rejected": "✗",
    "blocked": "⊘",
    "cancelled": "○",
    "infra_error": "⚠",
}

STATUS_COLORS = {
    "queued": "dim",
    "running": "blue",
    "accepted": "green",
    "rejected": "red",
    "blocked": "yellow",
    "cancelled": "dim",
    "infra_error": "red",
}


def status_icon(status: str) -> str:
    return STATUS_ICONS.get(status, "?")


def status_color(status: str) -> str:
    return STATUS_COLORS.get(status, "white")
