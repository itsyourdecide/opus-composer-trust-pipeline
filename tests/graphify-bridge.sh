#!/usr/bin/env bash
#
# Gate: the optional graphify bridge (Level-2 retrieval) is wired correctly and degrades
# gracefully. Assertions hold whether or not graphify is installed — the contract is
# "never raise, always return a status + hint", so a missing graph/CLI is a soft miss, not
# a failure. This keeps graphify strictly optional: ophar must run identically without it.
#
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${PYTHON:-$ROOT/.venv/bin/python}"
[[ -x "$PYTHON" ]] || PYTHON="python3"

echo "### graphify bridge: load, tool registration, graceful degradation  [py: $PYTHON]"

"$PYTHON" - "$ROOT" <<'PY'
import asyncio, importlib.util, sys, tempfile
from pathlib import Path

root = Path(sys.argv[1])
fail = 0

def check(label, cond):
    global fail
    print(f"  -> {label}: {'OK' if cond else 'FAIL'}")
    if not cond:
        fail = 1

def load(name, rel):
    spec = importlib.util.spec_from_file_location(name, root / rel)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod

br = load("ophar_graphify_bridge_test", "harness/graphify_bridge.py")
m = load("ophar_mcp_server_test", "harness/mcp_server.py")

tmp = tempfile.mkdtemp()

# 1. an empty dir has no index
check("has_index(empty) is False", br.has_index(tmp) is False)

# 2. query never raises and reports a non-ok status with a hint when there's no graph
q = br.query(tmp, "anything")
check("query(no graph) degrades", q.get("status") in ("no_index", "unavailable") and bool(q.get("hint")))

# 3. status() always returns the three contract keys
st = br.status(tmp)
check("status() shape", set(st) == {"available", "has_index", "index_path"})

# 4. the MCP server loaded the bridge and registered query_repo
check("bridge loaded into server", m.graphify_bridge is not None)
tools = [t.name for t in asyncio.run(m.list_tools())]
check("query_repo registered", "query_repo" in tools)
check("init_repo + run_in_composer intact", {"init_repo", "run_in_composer"} <= set(tools))

# 5. _query_repo returns a structured dict (never raises)
r = m._query_repo(tmp, "anything")
check("_query_repo returns status", isinstance(r, dict) and "status" in r)

# 6. init_repo without index is unchanged (no graph key)
ir = m._init_repo(tempfile.mkdtemp(), "python")
check("init_repo(no index) has no graph key", "graph" not in ir and ir.get("ready") is True)

# 7. init_repo(index=true) always reports a graph status dict (best-effort, never fatal).
#    Stub a graph so the available-path is the synchronous no-LLM refresh, not a detached
#    background build — keeps the gate side-effect-free.
import json
repo7 = Path(tempfile.mkdtemp())
(repo7 / "graphify-out").mkdir()
(repo7 / "graphify-out" / "graph.json").write_text(json.dumps({"nodes": [], "edges": []}))
ir2 = m._init_repo(str(repo7), "python", index=True)
check("init_repo(index=true) reports graph status", isinstance(ir2.get("graph"), dict) and "status" in ir2["graph"])

sys.exit(fail)
PY
fail=$?

echo; [[ $fail -eq 0 ]] && echo "GRAPHIFY BRIDGE GATE: GREEN" || echo "GRAPHIFY BRIDGE GATE: RED"
exit $fail
