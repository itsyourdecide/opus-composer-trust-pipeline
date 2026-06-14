"""Settings router — global env knobs only (per-task fields stay in task spec)."""

from __future__ import annotations

from fastapi import APIRouter, HTTPException

from ..config import load_settings, save_settings, DEFAULT_SETTINGS
from ..models import SettingsUpdate

router = APIRouter(prefix="/settings", tags=["settings"])


@router.get("")
async def get_settings() -> dict:
    """Get current settings."""
    return load_settings()


@router.put("")
async def update_settings(upd: SettingsUpdate):
    """Update global settings. Only known env knobs are accepted."""
    current = load_settings()
    for k, v in upd.model_dump(exclude_unset=True).items():
        if k not in DEFAULT_SETTINGS:
            raise HTTPException(400, f"Unknown setting: {k}")
        current[k] = v
    save_settings(current)
    return current
