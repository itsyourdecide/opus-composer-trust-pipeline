#!/usr/bin/env bash
#
# Phase 4–5 gate (§6.4): the full orchestrate loop reaches the correct terminal
# verdict on each of the four paths, and the ledger records the trail.
#
# Paths:
#   accept          honest mock fixes on attempt 1               -> exit 0
#   iterate->accept flaky mock fails once, then fixes            -> exit 0, 2 iterations
#   reject          blocked mock never fixes (reliable failure)  -> exit 1, MAX iterations
#   block           hanging mock, retries exhausted (no GT)      -> exit 2
#
# iterate/reject paths invoke the real `claude -p` for spec refinement (own usage,
# not Cursor quota). The executor is always the mock — zero Cursor quota.
#
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CURSOR_AGENT_CMD="$ROOT/harness/lib/mock-cursor-agent.sh"
# Default the Opus refinement step to the mock too, so the gate runs at ZERO quota
# (Cursor AND Claude). Override CLAUDE_CMD=claude to exercise the real refinement.
export CLAUDE_CMD="${CLAUDE_CMD:-$ROOT/harness/lib/mock-claude.sh}"
export TEST_CMD="${TEST_CMD:-python3 -m pytest tests/ -x -q}"
# held-out (§9) is part of work_ok; it needs a real pytest interpreter (the worktree has no venv).
export HELDOUT_PYTEST="${HELDOUT_PYTEST:-python3 -m pytest}"
SPEC="$ROOT/tasks/T-0002.json"
LEDGER="$ROOT/state/ledger.jsonl"
fail=0

# Sandbox-py must exist with the bug present for the executor to act on.
[[ -f "$ROOT/sandbox-py/src/signals.py" ]] || { echo "orchestrate gate: sandbox-py missing"; exit 2; }

run_orch() { # mode timeout retries max_iter -> echoes exit code
  local mode="$1" to="$2" retries="$3" maxit="$4"
  rm -f /tmp/mock-flaky-count
  MOCK_MODE="$mode" MOCK_STATE_FILE=/tmp/mock-flaky-count TIMEOUT="$to" RETRIES="$retries" \
    MAX_ITERATIONS="$maxit" bash "$ROOT/harness/orchestrate.sh" "$SPEC" >/tmp/orch-gate.log 2>&1
  echo $?
}

check() { # label want_exit got_exit
  if [[ "$2" == "$3" ]]; then echo "  -> $1: OK (exit $3)"; else echo "  -> $1: FAIL (want exit $2, got $3)"; fail=1; fi
}

echo "### accept: honest mock fixes on attempt 1"
git -C "$ROOT/sandbox-py" branch -D orch/accepted/T-0002 >/dev/null 2>&1 || true
check "accept" 0 "$(run_orch honest 30 2 3)"
# the accept must LAND on a durable result branch carrying the fix, without touching base
if git -C "$ROOT/sandbox-py" rev-parse --verify orch/accepted/T-0002 >/dev/null 2>&1 \
   && git -C "$ROOT/sandbox-py" show orch/accepted/T-0002:src/signals.py | grep -q "return up_price / denom"; then
  echo "  -> landed on orch/accepted/T-0002 with the fix: OK"
else
  echo "  -> FAIL: accept did not land the fix on a result branch"; fail=1
fi
if git -C "$ROOT/sandbox-py" show master:src/signals.py | grep -q "down_price / denom"; then
  echo "  -> base (master) left untouched: OK"
else
  echo "  -> FAIL: base was mutated by land"; fail=1
fi

echo "### iterate->accept: flaky mock fails once then fixes"
rc="$(run_orch flaky 30 2 3)"
check "iterate->accept exit" 0 "$rc"
last_accept_iter="$(jq -rs 'map(select(.event=="accept"))|last.iteration' "$LEDGER" 2>/dev/null)"
[[ "$last_accept_iter" == "2" ]] && echo "  -> accepted on iteration 2: OK" || { echo "  -> accepted on iteration $last_accept_iter (want 2): FAIL"; fail=1; }

echo "### reject: blocked mock never fixes (reliable failure)"
check "reject" 1 "$(run_orch blocked 30 2 3)"

echo "### block: hanging mock, retries exhausted (no ground truth)"
check "block" 2 "$(run_orch hang 5 0 3)"

echo; [[ $fail -eq 0 ]] && echo "PHASE 4-5 GATE: GREEN" || echo "PHASE 4-5 GATE: RED"
exit $fail
