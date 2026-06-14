"""Metrics router."""

from __future__ import annotations

from fastapi import APIRouter

from ..services import metrics as metrics_svc
from ..models import MetricsSummary

router = APIRouter(prefix="/metrics", tags=["metrics"])


@router.get("", response_model=MetricsSummary)
async def get_metrics():
    """Current metrics snapshot from metrics-report.sh."""
    summary = metrics_svc.current_summary()
    return MetricsSummary(raw=summary)


@router.get("/history")
async def get_history(granularity: str = "daily"):
    """Historical metrics aggregated per day."""
    return metrics_svc.history_by_day()


@router.get("/classes")
async def get_classes():
    """Breakdown by task class."""
    return metrics_svc.class_breakdown()
