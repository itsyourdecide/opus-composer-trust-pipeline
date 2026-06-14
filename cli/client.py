"""HTTP/WS client with auto-spawn of the local API server (OpenCode-style).

Discovery: state/server/server.json lockfile {pid, port, started_at}.
If the server is alive (/health) -> connect.
Otherwise -> spawn uvicorn in the background, wait for /health, write lockfile.
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

import httpx
import websockets

from ophar.paths import get_root

ROOT = get_root()
STATE_DIR = ROOT / "state" / "server"
LOCKFILE = STATE_DIR / "server.json"
PYTHON = sys.executable
DEFAULT_PORT = 8001


def _ensure_state_dir() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)


def _read_lockfile() -> dict | None:
    if not LOCKFILE.exists():
        return None
    try:
        return json.loads(LOCKFILE.read_text())
    except (json.JSONDecodeError, IOError):
        return None


def _write_lockfile(data: dict) -> None:
    _ensure_state_dir()
    LOCKFILE.write_text(json.dumps(data, indent=2))


def _is_alive(port: int) -> bool:
    """Check if the server at 127.0.0.1:<port> responds to /health."""
    try:
        resp = httpx.get(f"http://127.0.0.1:{port}/health", timeout=2)
        return resp.status_code == 200 and resp.json().get("status") == "ok"
    except Exception:
        return False


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def get_base_url() -> str:
    """Get the base URL of the API server, spawning it if necessary.

    Returns the base URL (e.g. 'http://127.0.0.1:8000').
    """
    lock = _read_lockfile()
    if lock:
        port = lock["port"]
        pid = lock["pid"]
        if _pid_alive(pid) and _is_alive(port):
            return f"http://127.0.0.1:{port}"

    # Spawn new server
    port = int(os.environ.get("OPUS_PORT", str(DEFAULT_PORT)))
    log_path = STATE_DIR / "server.log"

    env = {**os.environ}
    cmd = [
        PYTHON, "-m", "uvicorn", "server.main:app",
        "--host", "127.0.0.1",
        "--port", str(port),
        "--log-level", "warning",
    ]
    with open(log_path, "a") as fh:
        proc = subprocess.Popen(
            cmd,
            stdout=fh,
            stderr=subprocess.STDOUT,
            env=env,
            preexec_fn=os.setsid,
        )

    _write_lockfile({
        "pid": proc.pid,
        "port": port,
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    })

    # Wait for /health (up to 15s)
    base = f"http://127.0.0.1:{port}"
    for _ in range(30):
        if _is_alive(port):
            return base
        time.sleep(0.5)

    raise RuntimeError(f"Server did not start on port {port}. Check {log_path} for errors.")


def get_ws_url(path: str) -> str:
    base = get_base_url()
    ws_base = base.replace("http://", "ws://")
    return f"{ws_base}{path}"


def api_get(path: str, **params) -> dict | list:
    base = get_base_url()
    resp = httpx.get(f"{base}{path}", params=params, timeout=30)
    resp.raise_for_status()
    return resp.json()


def api_post(path: str, body: dict | None = None) -> dict:
    base = get_base_url()
    resp = httpx.post(f"{base}{path}", json=body or {}, timeout=120)
    resp.raise_for_status()
    return resp.json()


def api_put(path: str, body: dict) -> dict:
    base = get_base_url()
    resp = httpx.put(f"{base}{path}", json=body, timeout=30)
    resp.raise_for_status()
    return resp.json()
