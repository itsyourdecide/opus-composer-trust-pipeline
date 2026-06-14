"""Metrics service — wraps metrics-report.sh, aggregates historical data by day.

metrics.jsonl has a `ts` field (ISO timestamp), so daily bucketing is straightforward.
"""

from __future__ import annotations

import json
import subprocess
from datetime import date, datetime
from pathlib import Path

from ..config import HARNESS_DIR, METRICS_FILE, load_settings


def _read_metrics_jsonl(path: Path) -> list[dict]:
    records = []
    if not path.exists():
        return records
    for line in path.read_text().splitlines():
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return records


def current_summary() -> dict:
    """Run metrics-report.sh and parse its JSON output."""
    cmd = [str(HARNESS_DIR / "metrics-report.sh")]
    env = {}
    settings = load_settings()
    for k in ("P90_MIN_N", "P95_MIN_N"):
        v = settings.get(k)
        if v is not None and str(v) != "":
            env[k] = str(v)
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, env=env | {})
        return json.loads(proc.stdout) if proc.stdout else {"error": "no output"}
    except (subprocess.SubprocessError, json.JSONDecodeError) as e:
        return {"error": str(e)}


def history_by_day() -> list[dict]:
    """Aggregate metrics.jsonl into daily buckets."""
    records = _read_metrics_jsonl(METRICS_FILE)
    daily: dict[str, dict] = {}
    for r in records:
        ts = r.get("ts", "")
        if not ts:
            continue
        day = ts[:10]
        if day not in daily:
            daily[day] = {
                "date": day,
                "runs": 0,
                "accepted": 0,
                "rejected": 0,
                "tokens_total": 0,
            }
        bucket = daily[day]
        bucket["runs"] += 1
        if r.get("work_ok"):
            bucket["accepted"] += 1
        else:
            bucket["rejected"] += 1
        bucket["tokens_total"] += r.get("composer_tokens", {}).get("total", 0)
    return sorted(daily.values(), key=lambda x: x["date"])


def class_breakdown() -> dict:
    """Breakdown by task class."""
    records = _read_metrics_jsonl(METRICS_FILE)
    classes: dict[str, dict] = {}
    for r in records:
        cls = r.get("class", "unclassified")
        if cls not in classes:
            classes[cls] = {"n": 0, "accepted": 0, "rejected": 0}
        c = classes[cls]
        c["n"] += 1
        if r.get("work_ok"):
            c["accepted"] += 1
        else:
            c["rejected"] += 1
    return classes
