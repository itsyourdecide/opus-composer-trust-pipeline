#!/usr/bin/env python3
"""
MCP stdio server — exposes run_in_composer as a tool for Claude Code (subscription auth).

Claude Code calls this tool; the server runs orchestrate.sh and returns ground truth.
No API key needed — auth is handled by the Claude Code CLI session.

Register once (after pip install + python -m ophar setup, or from a git checkout):

    claude mcp add --scope user ophar -- python -m ophar mcp

Manual path (development):

    claude mcp add --scope user ophar -- \
        "$PWD/.venv/bin/python3" "$PWD/harness/mcp_server.py"
"""

import asyncio
import json
import os
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

import mcp.server.stdio
import mcp.types as types
from mcp.server import NotificationOptions, Server
from mcp.server.models import InitializationOptions

from ophar.paths import get_root

# Optional Level-2 retrieval layer. This file is loaded via spec_from_file_location (not as
# part of an importable `harness` package), so the sibling bridge is loaded by path next to
# this file. Done defensively: a broken/missing bridge leaves graphify_bridge=None and the
# graphify tools simply report "unavailable" — the pipeline runs exactly as before.
def _load_graphify_bridge():
    import importlib.util as _ilu
    try:
        path = Path(__file__).resolve().parent / "graphify_bridge.py"
        spec = _ilu.spec_from_file_location("ophar_graphify_bridge", path)
        if spec and spec.loader:
            mod = _ilu.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    except Exception:  # noqa: BLE001
        return None
    return None


graphify_bridge = _load_graphify_bridge()

server = Server("ophar")


def _root() -> Path:
    return get_root()


def _harness() -> Path:
    return _root() / "harness"


def _tasks_dir() -> Path:
    return _root() / "tasks"


def _heldout_dir() -> Path:
    return _root() / "heldout"


def _ledger() -> Path:
    return _root() / "state" / "ledger.jsonl"


def _resources() -> dict[str, tuple[str, Path, str]]:
    root = _root()
    return {
        "pipeline://state": (
            "Live state",
            root / "state" / "STATE.md",
            "Current pipeline state (§4 soft state). Read at session start.",
        ),
        "pipeline://discipline": (
            "Discipline",
            root / "CLAUDE.md",
            "Orchestrator delegation rules - the behavioral layer.",
        ),
        "pipeline://plan": (
            "Design",
            root / "orchestrator-pipeline-plan.md",
            "Full pipeline design and rationale.",
        ),
        "pipeline://ledger": (
            "Ledger tail",
            _ledger(),
            "Recent task lifecycle events (open/dispatch/accept/...).",
        ),
    }

# ── operating manual ──────────────────────────────────────────────────────────
# Delivered to the client at initialize time (claude CLI injects it into the
# orchestrator's system prompt). This is the SINGLE source of the orchestrator's
# discipline — it no longer depends on a CLAUDE.md that happens to be in cwd. Keep it
# tight; the depth lives in the resources below (read them on demand, context stays thin).

INSTRUCTIONS = """\
You are Opus, the orchestrator of the Opus→Composer pipeline. This server IS your
interface to the pipeline — you plan and verify; Composer (a headless executor) does
the dirty work. Everything you need to drive the pipeline is here: these instructions,
the two tools, and the pipeline:// resources.

## Trust boundary (the whole point of this pipeline)
Decisions come ONLY from the ground truth this server returns (diff, tests, held-out,
scope) — NEVER from the executor's summary/claim. If you ever accept based on the
executor's narrative, that is the exact trust leak this pipeline exists to prevent.

## Session start
Read resource `pipeline://state` first to rehydrate live state. If anything looks
stale, say so before acting on it.

## Understand the target repo cheaply (do this BEFORE reading files)
Reading files wholesale burns your context — the one thing this pipeline keeps thin. If a
graph index exists, ASK it instead:
- query_repo(target_repo, question): comprehension over a prebuilt knowledge graph, far
  cheaper than opening files. Use mode="affected" with a symbol to get its blast radius —
  that directly tells you the narrowest correct allowed_scope for run_in_composer.
- The graph is a NAVIGATION hint (edges are INFERRED/AMBIGUOUS). Use it to decide WHERE to
  look and HOW to scope — NEVER as a verdict. Acceptance still comes only from ground truth.
- If query_repo reports no_index, call init_repo(path, index=true) once to build it (or tell
  the user to run `/graphify <path>`). If it reports unavailable, just read files normally —
  graphify is optional.

## Tools
- init_repo(path, lang, index): create/reuse a git repo so it's a valid target_repo. Call
  this FIRST when target_repo doesn't exist or has no commits. Idempotent. Pass index=true to
  build/refresh a graphify index for the repo (optional, best-effort).
- query_repo(target_repo, question, mode): query the repo's graphify index (mode "query" or
  "affected"); cheap comprehension/scoping. Optional — degrades gracefully if no graph.
- run_in_composer(...): dispatch a coding task; returns ground truth only. Author:
  - prompt: imperative, states WHAT must be true after the fix.
  - allowed_scope: narrowest globs (e.g. ["src/**"]) — enforced structurally.
  - test_cmd: shell cmd that exits 0 iff correct (absolute interpreter paths).
  - acceptance_criteria: one machine-checkable sentence.
  - heldout_code (strongly recommended): pytest with UNSEEN inputs testing the same
    criterion from another angle, to catch overfitting. NEVER mention these inputs in
    the prompt or visible tests.

## Reading ground truth
verdict ∈ {accepted, rejected, blocked}. If tests_passed=true but held_out_passed=false,
the executor overfit the visible tests — do NOT accept; revise and redispatch.

## Resources (read on demand; keep context thin)
- pipeline://state      — live STATE.md
- pipeline://discipline — delegation rules (the behavioral layer)
- pipeline://plan       — full pipeline design
- pipeline://ledger     — recent task events

Respond in the user's language. Be concise. After a dispatch, explain the ground truth
plainly — not the executor's story.
"""

# Serial invariant: orchestrate.sh uses a global runs/.last-run-dir pointer that two
# concurrent dispatches would clobber. The FastAPI worker enforces this with its own
# lock; this MCP entry point must too. Created lazily inside the event loop.
_dispatch_lock: asyncio.Lock | None = None


def _get_dispatch_lock() -> asyncio.Lock:
    global _dispatch_lock
    if _dispatch_lock is None:
        _dispatch_lock = asyncio.Lock()
    return _dispatch_lock


# ── helpers ──────────────────────────────────────────────────────────────────

def _task_id() -> str:
    ts = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    return f"T-{ts}-{uuid.uuid4().hex[:4].upper()}"


def _ledger_events(task_id: str) -> list[dict]:
    ledger = _ledger()
    if not ledger.exists():
        return []
    events = []
    for line in ledger.read_text().splitlines():
        try:
            e = json.loads(line)
            if e.get("task_id") == task_id:
                events.append({"event": e["event"], "ts": e.get("ts", "")})
        except Exception:
            pass
    return events


def _run_in_composer(
    prompt: str,
    target_repo: str,
    allowed_scope: list,
    test_cmd: str,
    acceptance_criteria: str,
    heldout_code: str | None = None,
    max_iterations: int = 3,
) -> dict:
    task_id = _task_id()
    spec = {
        "task_id": task_id,
        "prompt": f"{acceptance_criteria}\n\n{prompt}",
        "target_repo": target_repo,
        "base_ref": "HEAD",
        "allowed_scope": allowed_scope,
        # The spec is the source of truth for verification: orchestrate.sh reads test_cmd
        # and exports it, overriding the global settings.json default so this task is never
        # checked with the wrong test runner.
        "test_cmd": test_cmd,
        "class": "small",
        "complexity": 2,
        "spec_clarity": 4,
    }

    if heldout_code and heldout_code.strip():
        hd = _heldout_dir() / task_id
        hd.mkdir(parents=True, exist_ok=True)
        (hd / "test_heldout.py").write_text(heldout_code)
        (hd / "manifest.json").write_text(json.dumps({
            "set": task_id,
            "place": [{"from": "test_heldout.py", "to": "tests/test_heldout.py"}],
            "cmd": "${HELDOUT_PYTEST:-python3 -m pytest} -q tests/test_heldout.py",
        }, indent=2))
        spec["heldout_set"] = task_id

    tasks_dir = _tasks_dir()
    tasks_dir.mkdir(parents=True, exist_ok=True)
    (tasks_dir / f"{task_id}.json").write_text(json.dumps(spec, indent=2))

    # test_cmd now travels in the spec (above); orchestrate.sh translates it to the
    # TEST_CMD env that ground-truth.sh consumes. Only MAX_ITERATIONS still rides env.
    env = {**os.environ, "MAX_ITERATIONS": str(max_iterations)}
    proc = subprocess.run(
        ["bash", str(_harness() / "orchestrate.sh"), str(tasks_dir / f"{task_id}.json")],
        env=env,
    )

    run_dir = _root() / "runs" / task_id
    gt: dict = {}
    gt_path = run_dir / "ground-truth.json"
    if gt_path.exists():
        raw = json.loads(gt_path.read_text())
        gt = {
            "diff_files":      raw.get("diff_name_only", []),
            "diff_stat":       raw.get("diff_stat", "no changes"),
            "tests_passed":    raw.get("visible_tests", {}).get("passed"),
            "held_out_ran":    raw.get("held_out_checks", {}).get("ran", False),
            "held_out_passed": raw.get("held_out_checks", {}).get("passed"),
            "scope_clean":     len(raw.get("scope", {}).get("out_of_scope_touched", [])) == 0,
        }

    events = _ledger_events(task_id)
    last_event = events[-1]["event"] if events else None
    if proc.returncode == 2:
        verdict = "blocked" if last_event == "block" else "infra_error"
    else:
        verdict = {0: "accepted", 1: "rejected"}.get(proc.returncode, "unknown")

    result_branch = None
    land_path = run_dir / "land.json"
    if land_path.exists():
        result_branch = json.loads(land_path.read_text()).get("result_branch")

    return {
        "task_id":       task_id,
        "verdict":       verdict,
        "result_branch": result_branch,
        "ground_truth":  gt,
        "ledger":        events,
    }


# ── init_repo ────────────────────────────────────────────────────────────────

_GITIGNORE = "__pycache__/\n*.pyc\n.venv/\ndist/\n"

_SCAFFOLDS: dict[str, dict[str, str]] = {
    "python": {
        "src/__init__.py": "",
        "tests/__init__.py": "",
        "tests/test_placeholder.py": (
            "# Replace with real tests\n"
            "def test_ok():\n    assert True\n"
        ),
        ".gitignore": _GITIGNORE,
    },
    "node": {
        "src/index.js": "// entry point\n",
        "tests/index.test.js": "// add tests here\n",
        ".gitignore": "node_modules/\ndist/\n",
    },
}


def _init_repo(path: str, lang: str = "python", index: bool = False) -> dict:
    """Create a git repo at path with minimal scaffold. Idempotent if already a repo.

    When index=true and graphify is available, build/refresh a graphify index for the repo
    (best-effort, never fatal) so the orchestrator can query it instead of reading files.
    """
    repo = Path(path)
    repo.mkdir(parents=True, exist_ok=True)

    is_git = (repo / ".git").exists()
    scaffold = _SCAFFOLDS.get(lang, _SCAFFOLDS["python"])

    # Write scaffold files only when not already present
    created: list[str] = []
    for rel, content in scaffold.items():
        target = repo / rel
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
            created.append(rel)

    def git(*args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["git", *args], cwd=str(repo),
            capture_output=True, text=True,
        )

    if not is_git:
        git("init")
        git("config", "user.email", "opus@local")
        git("config", "user.name", "Opus")

    # Stage everything and commit only if there are changes
    git("add", "-A")
    status = git("status", "--porcelain")
    if status.stdout.strip():
        git("commit", "-m", "chore: scaffold")

    # Confirm HEAD exists
    head = git("rev-parse", "HEAD")
    result = {
        "path": str(repo),
        "lang": lang,
        "already_existed": is_git,
        "files_created": created,
        "head": head.stdout.strip(),
        "ready": head.returncode == 0,
    }

    # Optional Level-2 retrieval index. Best-effort: a graphify failure never fails init_repo.
    if index and graphify_bridge is not None:
        result["graph"] = graphify_bridge.ensure_index(repo)
    elif index:
        result["graph"] = {"status": "unavailable", "hint": "graphify bridge not loaded"}

    return result


def _query_repo(target_repo: str, question: str, mode: str = "query",
                budget: int = 1500, depth: int = 2) -> dict:
    """Query the target repo's graphify index (best-effort, never raises)."""
    if graphify_bridge is None:
        return {"status": "unavailable", "hint": "graphify bridge not loaded"}
    return graphify_bridge.query(target_repo, question, budget=budget, mode=mode, depth=depth)


# ── resources (live pipeline context, read on demand) ────────────────────────
# The orchestrator pulls these instead of depending on a CLAUDE.md in cwd. All read
# live from disk so they reflect current state, not a snapshot.

_LEDGER_TAIL = 40  # ledger.jsonl is large; only the recent window is useful context


@server.list_resources()
async def list_resources() -> list[types.Resource]:
    out = []
    for uri, (title, path, desc) in _resources().items():
        if path.exists():
            out.append(types.Resource(
                uri=uri, name=title, description=desc, mimeType="text/plain",
            ))
    return out


@server.read_resource()
async def read_resource(uri: str) -> str:
    entry = _resources().get(str(uri))
    if entry is None:
        raise ValueError(f"Unknown resource: {uri}")
    _, path, _ = entry
    if not path.exists():
        return f"(resource {uri} not present at {path})"
    if str(uri) == "pipeline://ledger":
        lines = path.read_text().splitlines()
        return "\n".join(lines[-_LEDGER_TAIL:])
    return path.read_text()


# ── MCP handlers ─────────────────────────────────────────────────────────────

@server.list_tools()
async def list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="init_repo",
            description=(
                "Create (or re-use) a git repository at the given path with a minimal "
                "scaffold so it is ready as a target_repo for run_in_composer. "
                "Idempotent: safe to call on an existing repo — only missing files are added. "
                "Call this before run_in_composer whenever target_repo does not exist or "
                "has no commits (no HEAD)."
            ),
            inputSchema={
                "type": "object",
                "required": ["path"],
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Absolute path where the repo should be created.",
                    },
                    "lang": {
                        "type": "string",
                        "description": "Scaffold language: 'python' (default) or 'node'.",
                        "default": "python",
                    },
                    "index": {
                        "type": "boolean",
                        "description": (
                            "Build/refresh a graphify knowledge-graph index for the repo "
                            "(optional, best-effort). Lets the orchestrator query the repo "
                            "instead of reading files. Initial build needs a graphify LLM "
                            "backend and runs in the background."
                        ),
                        "default": False,
                    },
                },
            },
        ),
        types.Tool(
            name="query_repo",
            description=(
                "Query the target repo's graphify knowledge-graph index — cheap comprehension "
                "and scoping that avoids reading files wholesale (keeps the orchestrator's "
                "context thin). mode='query' answers a question by graph traversal; "
                "mode='affected' returns the blast radius of a symbol (use it to pick the "
                "narrowest allowed_scope). The graph is a navigation hint, never a ground-truth "
                "signal. Degrades gracefully: reports 'no_index' or 'unavailable' instead of "
                "failing when there is no graph."
            ),
            inputSchema={
                "type": "object",
                "required": ["target_repo", "question"],
                "properties": {
                    "target_repo": {
                        "type": "string",
                        "description": "Absolute path to the target git repository.",
                    },
                    "question": {
                        "type": "string",
                        "description": (
                            "Natural-language question (mode='query'), or a symbol/node label "
                            "(mode='affected')."
                        ),
                    },
                    "mode": {
                        "type": "string",
                        "enum": ["query", "affected"],
                        "description": "'query' = BFS comprehension; 'affected' = reverse blast-radius.",
                        "default": "query",
                    },
                    "budget": {
                        "type": "integer",
                        "description": "Max answer tokens for mode='query' (default 1500).",
                        "default": 1500,
                    },
                    "depth": {
                        "type": "integer",
                        "description": "Reverse-traversal depth for mode='affected' (default 2).",
                        "default": 2,
                    },
                },
            },
        ),
        types.Tool(
            name="run_in_composer",
            description=(
                "Dispatch a coding task to Composer (headless agent) and get back "
                "verified ground truth. Composer edits the repo; the harness independently "
                "verifies via tests + scope + optional held-out checks. Returns ground truth "
                "only — never Composer's self-report."
            ),
            inputSchema={
                "type": "object",
                "required": ["prompt", "target_repo", "allowed_scope", "test_cmd", "acceptance_criteria"],
                "properties": {
                    "prompt": {
                        "type": "string",
                        "description": "Precise imperative instruction for Composer.",
                    },
                    "target_repo": {
                        "type": "string",
                        "description": "Absolute path to the target git repository.",
                    },
                    "allowed_scope": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Glob patterns for files Composer may touch (e.g. ['src/**']).",
                    },
                    "test_cmd": {
                        "type": "string",
                        "description": "Shell command that exits 0 iff the fix is correct.",
                    },
                    "acceptance_criteria": {
                        "type": "string",
                        "description": "One-sentence machine-checkable description of done.",
                    },
                    "heldout_code": {
                        "type": "string",
                        "description": (
                            "Optional Python pytest code with UNSEEN inputs. "
                            "Tests the same criterion from a different angle to catch overfitting."
                        ),
                    },
                    "max_iterations": {
                        "type": "integer",
                        "description": "Max refinement rounds (default 3).",
                        "default": 3,
                    },
                },
            },
        )
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[types.TextContent]:
    loop = asyncio.get_event_loop()

    if name == "init_repo":
        result = await loop.run_in_executor(None, lambda: _init_repo(**arguments))
    elif name == "query_repo":
        result = await loop.run_in_executor(None, lambda: _query_repo(**arguments))
    elif name == "run_in_composer":
        # Serialize: never two orchestrate.sh subprocesses at once (shared .last-run-dir).
        async with _get_dispatch_lock():
            result = await loop.run_in_executor(None, lambda: _run_in_composer(**arguments))
    else:
        raise ValueError(f"Unknown tool: {name}")

    return [types.TextContent(type="text", text=json.dumps(result, ensure_ascii=False, indent=2))]


async def main() -> None:
    async with mcp.server.stdio.stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            InitializationOptions(
                server_name="ophar",
                server_version="0.1.0",
                instructions=INSTRUCTIONS,
                capabilities=server.get_capabilities(
                    notification_options=NotificationOptions(),
                    experimental_capabilities={},
                ),
            ),
        )


if __name__ == "__main__":
    asyncio.run(main())
