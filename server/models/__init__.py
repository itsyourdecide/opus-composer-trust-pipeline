"""Pydantic models shared across routers/services."""

from __future__ import annotations

from typing import Any, Optional
from pydantic import BaseModel, Field


# ---- Tasks ----

class TaskSpec(BaseModel):
    task_id: str
    prompt: str
    target_repo: str
    base_ref: str = "HEAD"
    allowed_scope: list[str] = Field(default_factory=list)
    class_: str = Field(default="unclassified", alias="class")
    complexity: Optional[int] = None
    spec_clarity: Optional[int] = None
    heldout_set: str = ""
    # Per-task verification commands. When set, these override the global settings.json
    # defaults so each task is verified with its own toolchain (orchestrate.sh reads them).
    test_cmd: Optional[str] = None
    typecheck_cmd: Optional[str] = None
    lint_cmd: Optional[str] = None


class SubmitRequest(BaseModel):
    spec_file: Optional[str] = None
    spec: Optional[TaskSpec] = None


class TaskSummary(BaseModel):
    task_id: str
    status: str
    class_: Optional[str] = None
    submitted_at: Optional[str] = None
    started_at: Optional[str] = None
    finished_at: Optional[str] = None
    result_branch: Optional[str] = None
    landed_sha: Optional[str] = None


class TaskDetail(BaseModel):
    task_id: str
    status: str
    spec: Optional[dict] = None
    iterations: list[dict] = Field(default_factory=list)
    verdict: Optional[str] = None
    diff: Optional[str] = None
    landed_sha: Optional[str] = None


# ---- Metrics ----

class MetricsSummary(BaseModel):
    raw: dict[str, Any]


# ---- Settings ----

class SettingsUpdate(BaseModel):
    MAX_ITERATIONS: Optional[int] = None
    RETRIES: Optional[int] = None
    TIMEOUT: Optional[int] = None
    MODEL: Optional[str] = None
    SANDBOX: Optional[str] = None
    ENFORCE_SCOPE: Optional[int] = None
    RUN_AS_USER: Optional[str] = None
    INJECT_AGENTS: Optional[int] = None
    CURSOR_AGENT_CMD: Optional[str] = None
    TEST_CMD: Optional[str] = None
    TYPECHECK_CMD: Optional[str] = None
    LINT_CMD: Optional[str] = None
    P90_MIN_N: Optional[int] = None
    P95_MIN_N: Optional[int] = None


# ---- Ledger ----

class LedgerEvent(BaseModel):
    ts: str
    event: str
    task_id: str
    extra: dict[str, Any] = Field(default_factory=dict)
