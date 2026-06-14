"""Task registry — persisted JSON under asyncio lock.

State lives in state/server/tasks.json per task_id.
Status transitions: queued → running → accepted|rejected|blocked|cancelled|infra_error.
cancelled is registry-only (no ledger event for cancel).
"""

from __future__ import annotations

import asyncio
import json
from datetime import datetime, timezone

from ..config import TASKS_FILE

_lock = asyncio.Lock()
_registry: dict | None = None


def _load() -> dict:
    global _registry
    if _registry is not None:
        return _registry
    if TASKS_FILE.exists():
        _registry = json.loads(TASKS_FILE.read_text())
    else:
        _registry = {}
    return _registry


def _save() -> None:
    TASKS_FILE.parent.mkdir(parents=True, exist_ok=True)
    TASKS_FILE.write_text(json.dumps(_registry or {}, indent=2))


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


async def load_all() -> list[dict]:
    async with _lock:
        reg = _load()
        return list(reg.values())


async def get_task(task_id: str) -> dict | None:
    async with _lock:
        return _load().get(task_id)


async def enqueue(task_id: str, spec_file: str | None = None, spec: dict | None = None) -> dict:
    async with _lock:
        reg = _load()
        if task_id in reg:
            current = reg[task_id].get("status")
            if current not in ("accepted", "rejected", "blocked", "cancelled", "infra_error"):
                # Already queued or running — idempotent
                return reg[task_id]
        ts = _now()
        entry = {
            "task_id": task_id,
            "status": "queued",
            "submitted_at": ts,
            "spec_file": spec_file,
            "spec": spec,
        }
        reg[task_id] = entry
        _save()
        return entry


async def set_status(task_id: str, status: str, **kwargs) -> dict | None:
    async with _lock:
        reg = _load()
        entry = reg.get(task_id)
        if entry is None:
            return None
        entry["status"] = status
        if status == "running":
            entry["started_at"] = kwargs.get("started_at", _now())
        elif status in ("accepted", "rejected", "blocked", "cancelled", "infra_error"):
            entry["finished_at"] = kwargs.get("finished_at", _now())
        for k in ("result_branch", "landed_sha", "pid"):
            if k in kwargs and kwargs[k]:
                entry[k] = kwargs[k]
        reg[task_id] = entry
        _save()
        return entry
