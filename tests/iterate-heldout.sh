#!/usr/bin/env bash
#
# §9 + §6.4 gate: the HELD-OUT-driven iterate→accept path through the FULL orchestrate loop.
#
# This is the path the plan flagged as untested (T-1001 is too clean to ever iterate): the
# executor's first attempt OVERFITS to the visible inputs (visible PASS, scope clean, held-out
# FAIL). Visible tests + scope alone would have accepted it; only §9 held-out catch it, so the
# verdict is `iterate` with a GENERALIZED hint. The refined second attempt generalises and is
# accepted. Same wiring as the real binary — only the executor (mock) and Opus refinement
# (mock-claude) are stubbed, so it costs ZERO quota (Cursor AND Claude).
#
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CURSOR_AGENT_CMD="$ROOT/harness/lib/mock-cursor-agent.sh"
export CLAUDE_CMD="${CLAUDE_CMD:-$ROOT/harness/lib/mock-claude.sh}"
export TEST_CMD="${TEST_CMD:-python3 -m pytest tests/ -x -q}"
export HELDOUT_PYTEST="${HELDOUT_PYTEST:-python3 -m pytest}"
SPEC="$ROOT/tasks/T-1002.json"
LEDGER="$ROOT/state/ledger.jsonl"
fail=0

[[ -f "$ROOT/sandbox-py/src/signals.py" ]] || { echo "iterate-heldout gate: sandbox-py missing"; exit 2; }

git -C "$ROOT/sandbox-py" branch -D orch/accepted/T-1002 >/dev/null 2>&1 || true
rm -f /tmp/mock-overfit-count

echo "### overfit-then-generalise: held-out forces iterate(1) → accept(2)"
MOCK_MODE=overfit_then_fix MOCK_STATE_FILE=/tmp/mock-overfit-count \
  TIMEOUT=30 RETRIES=2 MAX_ITERATIONS=3 \
  bash "$ROOT/harness/orchestrate.sh" "$SPEC" >/tmp/iter-heldout.log 2>&1
rc=$?
echo "  orchestrate exit=$rc (want 0)"
[[ "$rc" -eq 0 ]] || { echo "  -> FAIL: loop did not reach accept"; fail=1; }

# iteration 1 must be an iterate driven by HELD-OUT (generalized reason, no leak)
it_reason="$(jq -rs 'map(select(.task_id=="T-1002" and .event=="iterate"))|first.reason' "$LEDGER" 2>/dev/null)"
echo "  iterate(1) reason: $it_reason"
if grep -qi "held-out\|overfit" <<<"$it_reason"; then
  echo "  -> iterate was held-out-driven: OK"
else
  echo "  -> FAIL: first iterate was not the held-out path"; fail=1
fi
# §9.5: the generalized hint must not leak the held-out assertion specifics
if grep -qiE "complement|0\.61|0\.85|table|test_heldout" <<<"$it_reason"; then
  echo "  -> LEAK: iterate reason exposes held-out specifics"; fail=1
else
  echo "  -> hint stays generalized: OK"
fi

# accept must land on iteration 2 with the GENERAL fix, base untouched
acc_iter="$(jq -rs 'map(select(.task_id=="T-1002" and .event=="accept"))|last.iteration' "$LEDGER" 2>/dev/null)"
echo "  accepted on iteration: $acc_iter (want 2)"
[[ "$acc_iter" == "2" ]] || { echo "  -> FAIL: not accepted on the refined attempt"; fail=1; }
if git -C "$ROOT/sandbox-py" rev-parse --verify orch/accepted/T-1002 >/dev/null 2>&1 \
   && git -C "$ROOT/sandbox-py" show orch/accepted/T-1002:src/signals.py | grep -q "return up_price / denom"; then
  echo "  -> landed the general fix on orch/accepted/T-1002: OK"
else
  echo "  -> FAIL: accept did not land the general fix"; fail=1
fi
if git -C "$ROOT/sandbox-py" show master:src/signals.py | grep -q "down_price / denom"; then
  echo "  -> base (master) left untouched: OK"
else
  echo "  -> FAIL: base was mutated"; fail=1
fi

echo; [[ $fail -eq 0 ]] && echo "ITERATE-HELDOUT (§9/§6.4) GATE: GREEN" || echo "ITERATE-HELDOUT (§9/§6.4) GATE: RED"
exit $fail
