"""WebSocket endpoints — global events feed and per-task log streaming."""

from __future__ import annotations

import asyncio
import json

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from ..config import LEDGER_FILE, LOGS_DIR
from ..services import dispatch as dispatch_svc, registry

router = APIRouter()


@router.websocket("/ws/events")
async def ws_events(ws: WebSocket):
    """Global event stream: queue status + ledger tail every 2 seconds."""
    await ws.accept()
    last_ledger_offset = 0
    try:
        while True:
            # Read new ledger lines
            new_events = []
            if LEDGER_FILE.exists():
                lines = LEDGER_FILE.read_text().splitlines()
                for i in range(last_ledger_offset, len(lines)):
                    try:
                        rec = json.loads(lines[i])
                        new_events.append(rec)
                    except json.JSONDecodeError:
                        pass
                last_ledger_offset = len(lines)

            # Current queue state
            queue = await dispatch_svc.get_queue()
            current = await dispatch_svc.current_task()

            await ws.send_json({
                "queue": queue,
                "current": current,
                "new_events": new_events,
            })
            await asyncio.sleep(2)
    except WebSocketDisconnect:
        pass


@router.websocket("/ws/tasks/{task_id}")
async def ws_task_logs(ws: WebSocket, task_id: str):
    """Stream per-task log tail."""
    await ws.accept()
    log_path = LOGS_DIR / f"{task_id}.log"
    last_size = log_path.stat().st_size if log_path.exists() else 0
    try:
        while True:
            if log_path.exists():
                sz = log_path.stat().st_size
                if sz > last_size:
                    with open(log_path, "r") as fh:
                        fh.seek(last_size)
                        tail = fh.read()
                    last_size = sz
                    await ws.send_text(tail)

            # Task status
            entry = await registry.get_task(task_id)
            status = entry.get("status") if entry else "unknown"
            if status in ("accepted", "rejected", "blocked", "cancelled", "infra_error"):
                await ws.send_json({"status": status, "done": True})
                break

            await asyncio.sleep(1)
    except WebSocketDisconnect:
        pass
