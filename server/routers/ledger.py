"""Ledger router — read-only access to state/ledger.jsonl."""

from __future__ import annotations

import json

from fastapi import APIRouter, Query

from ..config import LEDGER_FILE

router = APIRouter(prefix="/ledger", tags=["ledger"])


@router.get("")
async def get_ledger(
    task_id: str | None = None,
    event: str | None = None,
    limit: int = Query(100, ge=1, le=1000),
):
    """Query ledger events, optionally filtered by task_id and/or event."""
    results = []
    if not LEDGER_FILE.exists():
        return results
    for line in LEDGER_FILE.read_text().splitlines():
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if task_id and rec.get("task_id") != task_id:
            continue
        if event and rec.get("event") != event:
            continue
        results.append(rec)
        if len(results) >= limit:
            break
    return results
