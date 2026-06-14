"""State service — reads STATE.md, fenced claims, and reconcile.json."""

from __future__ import annotations

import json
import re
import subprocess

from ..config import STATE_MD, HARNESS_DIR, STATE_DIR


def read_state_md() -> dict:
    """Return raw STATE.md content and parsed claims."""
    raw = STATE_MD.read_text() if STATE_MD.exists() else ""
    claims = _parse_claims_block(raw)
    return {"raw": raw, "claims": claims}


def _parse_claims_block(md: str) -> list:
    """Extract the fenced ```json claims block from STATE.md."""
    match = re.search(r"```json\s*\n(.*?)```", md, re.DOTALL)
    if not match:
        return []
    try:
        return json.loads(match.group(1))
    except json.JSONDecodeError:
        return []


def reconcile() -> dict:
    """Run harness/reconcile.sh and return the result."""
    reconcile_path = STATE_DIR / "reconcile.json"
    cmd = [str(HARNESS_DIR / "reconcile.sh")]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if reconcile_path.exists():
            return json.loads(reconcile_path.read_text())
        return {"error": "reconcile.json not produced", "stderr": proc.stderr}
    except (subprocess.SubprocessError, json.JSONDecodeError) as e:
        return {"error": str(e)}
