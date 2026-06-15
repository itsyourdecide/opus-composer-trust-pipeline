"""Optional graphify bridge — Level-2 orchestration, NOT a dependency.

graphify (https://pypi.org/project/graphifyy/) indexes a repo into a queryable knowledge
graph. The orchestrator can ask the graph ("where is X / what depends on Y / what's the
blast radius of Z") instead of reading files wholesale — which is exactly ophar's economic
goal: keep the expensive Opus window thin. The executor stays blind by design (the graph is
an orchestrator-side convenience, never fed to Composer, never a ground-truth signal).

This module shells out to the `graphify` CLI as a sibling process. It is import-free of
graphify itself and degrades gracefully when graphify is not installed: every entry point
returns a structured dict with a `status` and a human `hint`, never raises. So ophar never
hard-depends on graphify, and a missing graph just means "read files the old way".
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

_QUERY_TIMEOUT_S = 120
_UPDATE_TIMEOUT_S = 300


def _bin() -> str | None:
    """Locate the graphify console script (PATH first, then the usual pip --user dir)."""
    found = shutil.which("graphify")
    if found:
        return found
    candidate = Path.home() / ".local" / "bin" / "graphify"
    return str(candidate) if candidate.exists() else None


def available() -> bool:
    return _bin() is not None


def index_path(repo: str | Path) -> Path:
    return Path(repo) / "graphify-out" / "graph.json"


def has_index(repo: str | Path) -> bool:
    return index_path(repo).is_file()


def status(repo: str | Path) -> dict:
    return {
        "available": available(),
        "has_index": has_index(repo),
        "index_path": str(index_path(repo)),
    }


def query(repo: str | Path, question: str, budget: int = 1500,
          mode: str = "query", depth: int = 2) -> dict:
    """Ask the prebuilt graph. mode='query' (BFS comprehension) or 'affected'
    (reverse traversal: what a change to <question> impacts → scope/blast-radius).

    Never raises — returns a dict with `status` in
    {ok, unavailable, no_index, error} plus a `hint` when something is missing.
    """
    repo = Path(repo)
    gbin = _bin()
    if gbin is None:
        return {
            "status": "unavailable",
            "hint": "graphify not installed — `pip install graphifyy` (or `uv tool install "
                    "graphifyy`) to index this repo, otherwise read files directly.",
        }
    if not has_index(repo):
        return {
            "status": "no_index",
            "hint": f"no graph at {index_path(repo)} — build it once with "
                    f"init_repo(path, index=true) or `graphify extract {repo}`, then retry.",
        }

    if mode == "affected":
        cmd = [gbin, "affected", question, "--depth", str(depth)]
    else:
        cmd = [gbin, "query", question, "--budget", str(budget)]

    try:
        proc = subprocess.run(
            cmd, cwd=str(repo), capture_output=True, text=True, timeout=_QUERY_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        return {"status": "error", "hint": f"graphify {mode} timed out after {_QUERY_TIMEOUT_S}s"}
    if proc.returncode != 0:
        return {"status": "error", "hint": (proc.stderr or proc.stdout or "graphify failed").strip()[:500]}
    return {"status": "ok", "mode": mode, "answer": proc.stdout.strip()}


def ensure_index(repo: str | Path, background: bool = True) -> dict:
    """Build the index if missing (LLM-backed `extract`), or refresh it if present
    (`update`, no LLM). The initial build can be slow and needs a graphify LLM backend, so
    by default it is launched detached and logged; the caller is not blocked.
    """
    repo = Path(repo)
    gbin = _bin()
    if gbin is None:
        return {
            "status": "unavailable",
            "hint": "graphify not installed — skipping indexing (the pipeline works without it).",
        }

    if has_index(repo):
        try:
            proc = subprocess.run(
                [gbin, "update", str(repo)], cwd=str(repo),
                capture_output=True, text=True, timeout=_UPDATE_TIMEOUT_S,
            )
        except subprocess.TimeoutExpired:
            return {"status": "error", "hint": f"graphify update timed out after {_UPDATE_TIMEOUT_S}s"}
        ok = proc.returncode == 0
        return {"status": "refreshed" if ok else "error",
                "hint": "graph refreshed (no LLM)" if ok else (proc.stderr or "update failed").strip()[:500]}

    # Initial build: AST + semantic LLM extraction. Detached so the MCP call returns fast.
    log = repo / "graphify-out" / ".ophar-extract.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    if background:
        with open(log, "a") as fh:
            subprocess.Popen(
                [gbin, "extract", str(repo)], cwd=str(repo),
                stdout=fh, stderr=subprocess.STDOUT, start_new_session=True,
            )
        return {
            "status": "building",
            "hint": f"indexing started in the background (needs a graphify LLM backend); "
                    f"progress in {log}. query_repo will work once it finishes.",
        }
    try:
        proc = subprocess.run([gbin, "extract", str(repo)], cwd=str(repo),
                              capture_output=True, text=True)
    except Exception as e:  # noqa: BLE001 — best-effort, never break the caller
        return {"status": "error", "hint": str(e)[:500]}
    ok = proc.returncode == 0 and has_index(repo)
    return {"status": "built" if ok else "error",
            "hint": "graph built" if ok else (proc.stderr or "extract failed").strip()[:500]}
