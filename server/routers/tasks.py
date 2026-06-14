"""Task CRUD router."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

from fastapi import APIRouter, HTTPException

from ..config import ROOT, HISTORY_DIR
from ..models import SubmitRequest, TaskSummary, TaskDetail
from ..services import registry, dispatch as dispatch_svc

router = APIRouter(prefix="/tasks", tags=["tasks"])


@router.get("", response_model=list[TaskSummary])
async def list_tasks(status: str | None = None, class_: str | None = None):
    """List all tasks in the registry, optionally filtered."""
    all_tasks = await registry.load_all()
    results = []
    for t in all_tasks:
        if status and t.get("status") != status:
            continue
        results.append(TaskSummary(
            task_id=t["task_id"],
            status=t["status"],
            class_=t.get("class"),
            submitted_at=t.get("submitted_at"),
            started_at=t.get("started_at"),
            finished_at=t.get("finished_at"),
            result_branch=t.get("result_branch"),
            landed_sha=t.get("landed_sha"),
        ))
    return results


@router.post("", response_model=dict)
async def submit_task(req: SubmitRequest):
    """Submit a task spec (by file path or inline). Enqueue for the serial worker."""
    spec_file = req.spec_file
    spec_dict = None
    if req.spec:
        spec_dict = req.spec.model_dump(by_alias=True)
        task_id = req.spec.task_id
    elif spec_file:
        spec_path = Path(spec_file)
        if not spec_path.is_absolute():
            spec_path = ROOT / spec_file
        if not spec_path.exists():
            raise HTTPException(404, f"Spec file not found: {spec_file}")
        spec_dict = json.loads(spec_path.read_text())
        task_id = spec_dict.get("task_id")
    else:
        raise HTTPException(400, "Either spec_file or spec is required")

    if not task_id:
        raise HTTPException(400, "task_id is required")

    entry = await registry.enqueue(task_id, spec_file=spec_file, spec=spec_dict)
    await dispatch_svc.enqueue(task_id)
    return entry


@router.get("/{task_id}", response_model=TaskDetail)
async def get_task(task_id: str):
    """Get task detail including spec, iterations from history, and diff from landed branch."""
    entry = await registry.get_task(task_id)
    if entry is None:
        raise HTTPException(404, f"Task not found: {task_id}")

    spec_dict = entry.get("spec") or {}
    if not spec_dict and entry.get("spec_file"):
        spec_path = Path(entry["spec_file"])
        if not spec_path.is_absolute():
            spec_path = ROOT / spec_path
        if spec_path.exists():
            spec_dict = json.loads(spec_path.read_text())

    # Iterations from durable history
    iterations = []
    hist_dir = HISTORY_DIR / task_id
    if hist_dir.exists():
        for it_dir in sorted(hist_dir.iterdir()):
            if it_dir.is_dir():
                it_data = {}
                for f in ("ground-truth.json", "dispatch.json", "heldout.json"):
                    fp = it_dir / f
                    if fp.exists():
                        it_data[f] = json.loads(fp.read_text())
                if it_data:
                    iterations.append(it_data)

    # Verdict from last iteration
    verdict = None
    for it in reversed(iterations):
        gt = it.get("ground-truth.json", {})
        if gt.get("visible_tests", {}).get("passed") and not gt.get("scope", {}).get("out_of_scope_touched"):
            held = it.get("heldout.json", {})
            if not held.get("ran") or held.get("passed"):
                verdict = "accepted"
            else:
                verdict = "rejected"
            break
    if verdict is None and entry.get("status") == "accepted":
        verdict = "accepted"

    # Diff from landed branch
    diff = None
    result_branch = entry.get("result_branch")
    if result_branch and spec_dict.get("target_repo"):
        base_ref = spec_dict.get("base_ref", "HEAD")
        try:
            proc = subprocess.run(
                ["git", "-C", spec_dict["target_repo"], "diff", f"{base_ref}..{result_branch}"],
                capture_output=True, text=True, timeout=10,
            )
            if proc.returncode == 0:
                diff = proc.stdout
        except subprocess.SubprocessError:
            pass

    return TaskDetail(
        task_id=task_id,
        status=entry["status"],
        spec=spec_dict,
        iterations=iterations,
        verdict=verdict,
        diff=diff,
        landed_sha=entry.get("landed_sha"),
    )


@router.post("/{task_id}/cancel")
async def cancel_task(task_id: str):
    """Cancel a running or queued task. Registry-only status (no ledger cancel event)."""
    ok = await dispatch_svc.cancel(task_id)
    if not ok:
        raise HTTPException(404, f"Task not active: {task_id}")
    return {"task_id": task_id, "cancelled": True}
