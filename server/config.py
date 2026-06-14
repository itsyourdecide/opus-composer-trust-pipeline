"""Server config: paths, env, settings. MUST reject non-localhost binds (RCE risk)."""

import os
import json
from pathlib import Path

from ophar.paths import get_root

ROOT = get_root()
HARNESS_DIR = ROOT / "harness"
STATE_DIR = ROOT / "state"
RUNS_DIR = ROOT / "runs"
HISTORY_DIR = STATE_DIR / "history"
SERVER_STATE_DIR = STATE_DIR / "server"
TASKS_FILE = SERVER_STATE_DIR / "tasks.json"
LOGS_DIR = SERVER_STATE_DIR / "logs"
LEDGER_FILE = STATE_DIR / "ledger.jsonl"
METRICS_FILE = RUNS_DIR / "metrics.jsonl"
OPUS_METRICS_FILE = RUNS_DIR / "opus-metrics.jsonl"
STATE_MD = STATE_DIR / "STATE.md"
SETTINGS_FILE = SERVER_STATE_DIR / "settings.json"

# -- bind --
HOST = os.environ.get("OPUS_HOST", "127.0.0.1")
PORT = int(os.environ.get("OPUS_PORT", "8001"))

ALLOWED_HOSTS = {"127.0.0.1", "::1", "localhost"}

# Tailscale CGNAT range (100.64.0.0/10) is a private overlay network — safe to bind.
ALLOWED_PREFIXES = ("100.",)


def enforce_localhost_bind(host: str) -> None:
    """Fail-fast if the bind host is not localhost or Tailscale — settings PUT can inject
    arbitrary commands into subprocess env, so a public bind is RCE."""
    if host in ALLOWED_HOSTS:
        return
    if any(host.startswith(p) for p in ALLOWED_PREFIXES):
        return
    raise SystemExit(
        f"Refusing to bind to '{host}': only localhost or Tailscale (100.x.x.x) are allowed. "
        "Settings contain exec-able commands (CURSOR_AGENT_CMD, TEST_CMD, etc) — "
        "a public bind is an RCE vector."
    )


# -- settings (global env knobs) --
DEFAULT_SETTINGS: dict = {
    "MAX_ITERATIONS": 3,
    "RETRIES": 2,
    "TIMEOUT": 120,
    "MODEL": "composer-2.5",
    "SANDBOX": "enabled",
    "ENFORCE_SCOPE": 1,
    "RUN_AS_USER": "",
    "INJECT_AGENTS": 1,
    "CURSOR_AGENT_CMD": "cursor-agent",
    "TEST_CMD": "npm test --silent",
    "TYPECHECK_CMD": "",
    "LINT_CMD": "",
    "P90_MIN_N": 30,
    "P95_MIN_N": 200,
}


def load_settings() -> dict:
    """Load persisted settings, merged on top of defaults."""
    s = dict(DEFAULT_SETTINGS)
    if SETTINGS_FILE.exists():
        try:
            with open(SETTINGS_FILE) as fh:
                overrides = json.load(fh)
            s.update(overrides)
        except (json.JSONDecodeError, IOError):
            pass
    return s


def save_settings(s: dict, path: Path | None = None) -> None:
    p = path or SETTINGS_FILE
    p.parent.mkdir(parents=True, exist_ok=True)
    with open(p, "w") as fh:
        json.dump(s, fh, indent=2, sort_keys=True)
