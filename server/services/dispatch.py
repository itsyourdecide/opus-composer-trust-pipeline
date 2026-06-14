"""Serial worker — strictly ONE subprocess at a time.

Invariant: harness uses fixed runs/<task_id> + global runs/.last-run-dir
which break under parallelism. DO NOT parallelise this worker.
"""

from __future__ import annotations

import asyncio
import json
import os
import signal
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from ..config import HARNESS_DIR, LOGS_DIR, STATE_DIR
from . import registry

_queue: list[str] = []  # list of task_ids
_running: Optional[subprocess.Popen] = None
_current_task_id: Optional[str] = None
_lock: Optional[asyncio.Lock] = None  # created lazily inside the event loop


def _get_lock() -> asyncio.Lock:
    global _lock
    if _lock is None:
        _lock = asyncio.Lock()
    return _lock

# Exit-code mapping. EXIT 2 is OVERLOADED — disambiguate via ledger.
EXIT_MAP = {0: "accepted", 1: "rejected", 3: "infra_error"}

ORCHESTRATE = str(HARNESS_DIR / "orchestrate.sh")


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _settings_env(settings: dict) -> dict:
    env = {**os.environ}
    for k in (
        "MAX_ITERATIONS", "RETRIES", "TIMEOUT", "MODEL", "SANDBOX",
        "ENFORCE_SCOPE", "RUN_AS_USER", "INJECT_AGENTS", "CURSOR_AGENT_CMD",
        "TEST_CMD", "TYPECHECK_CMD", "LINT_CMD", "P90_MIN_N", "P95_MIN_N",
    ):
        v = settings.get(k)
        if v is not None and v != "":
            env[k] = str(v)
    return env


async def enqueue(task_id: str) -> None:
    async with _get_lock():
        if task_id not in _queue:
            _queue.append(task_id)


async def cancel(task_id: str) -> bool:
    """Kill the active process group; mark cancelled registry-side."""
    async with _get_lock():
        if _current_task_id == task_id and _running is not None:
            try:
                os.killpg(os.getpgid(_running.pid), signal.SIGTERM)
            except (ProcessLookupError, OSError):
                pass
            await registry.set_status(task_id, "cancelled")
            return True
        # If it's still queued, remove from queue and mark cancelled
        if task_id in _queue:
            _queue.remove(task_id)
            await registry.set_status(task_id, "cancelled")
            return True
        return False


async def active_count() -> int:
    async with _get_lock():
        return len(_queue) + (1 if _running is not None else 0)


async def current_task() -> Optional[str]:
    return _current_task_id


async def get_queue() -> list[str]:
    async with _get_lock():
        return list(_queue)


def _last_ledger_event(task_id: str) -> Optional[str]:
    """Read last ledger event for the given task to disambiguate exit 2."""
    ledger = STATE_DIR / "ledger.jsonl"
    if not ledger.exists():
        return None
    last_event = None
    for line in ledger.read_text().splitlines():
        try:
            rec = json.loads(line)
            if rec.get("task_id") == task_id:
                last_event = rec.get("event")
        except json.JSONDecodeError:
            pass
    return last_event


async def worker(loop_delay: float = 0.5):
    """Single-threaded loop: pick next queued task, run orchestrate.sh, record result.

    Runs as a background task. Never spawns two subprocesses concurrently.
    """
    global _running, _current_task_id
    from ..config import load_settings

    while True:
        task_id = None
        async with _get_lock():
            if _queue and _running is None:
                task_id = _queue.pop(0)

        if task_id is None:
            await asyncio.sleep(loop_delay)
            continue

        settings = load_settings()
        log_path = LOGS_DIR / f"{task_id}.log"
        spec_file = (await registry.get_task(task_id) or {}).get("spec_file")
        spec_path = None
        if spec_file:
            spec_path = Path(spec_file)
            if not spec_path.is_absolute():
                from ..config import ROOT
                spec_path = ROOT / spec_file
        if spec_path is None or not spec_path.exists():
            await registry.set_status(task_id, "infra_error")
            continue

        env = _settings_env(settings)
        start_time = _now()

        async with _get_lock():
            await registry.set_status(task_id, "running", started_at=start_time)
            _running = subprocess.Popen(
                ["bash", ORCHESTRATE, str(spec_path)],
                stdout=open(log_path, "w"),
                stderr=subprocess.STDOUT,
                env=env,
                preexec_fn=os.setsid,  # process group for cancel
            )
            _current_task_id = task_id

        # Wait without blocking the event loop (Popen.wait is sync).
        loop = asyncio.get_event_loop()
        rc = await loop.run_in_executor(None, _running.wait)

        async with _get_lock():
            _current_task_id = None
            _running = None

        # Disambiguate exit code
        if rc == 2:
            last_event = _last_ledger_event(task_id)
            if last_event == "block":
                final_status = "blocked"
            else:
                final_status = "infra_error"
        else:
            final_status = EXIT_MAP.get(rc, "infra_error")

        await registry.set_status(task_id, final_status)

        # Optionally: add a ledger note for cancelled/infra_error.
