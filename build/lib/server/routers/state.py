"""State router — read STATE.md and run reconcile.sh."""

from __future__ import annotations

from fastapi import APIRouter

from ..services import state as state_svc

router = APIRouter(prefix="/state", tags=["state"])


@router.get("")
async def get_state():
    """Get STATE.md content with machine-checked claims."""
    return state_svc.read_state_md()


@router.post("/reconcile")
async def run_reconcile():
    """Run harness/reconcile.sh and return the result."""
    return state_svc.reconcile()
