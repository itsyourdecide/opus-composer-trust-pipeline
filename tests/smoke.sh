#!/usr/bin/env bash
#
# Phase 1 gate (§2): the executor runs headless and predictably.
# Exit criterion: 10/10 runs return valid JSON and terminate within the timeout.
# Also exercises the two known failure modes the dispatcher must classify, not hang on:
# a hanging executor (timeout) and non-JSON output (invalid_json).
#
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCK="$ROOT/harness/lib/mock-cursor-agent.sh"
# The 10x gate runs whatever executor is configured: set CURSOR_AGENT_CMD=cursor-agent
# for the REAL Phase 1 gate, or leave unset to dry-run the harness against the mock.
EXECUTOR="${CURSOR_AGENT_CMD:-$MOCK}"
SPEC="$ROOT/tasks/T-0001.json"
RUN_TIMEOUT="${TIMEOUT:-30}"
# N is configurable: the plan's gate is 10, but against the REAL binary on a near-empty
# subscription, run SMOKE_N=1 to confirm wiring without burning quota.
N="${SMOKE_N:-10}"
fail=0

echo "### Phase 1 smoke: ${N}x runs return valid JSON + terminate  [executor: $EXECUTOR]"
pass=0
for i in $(seq 1 "$N"); do
  RUN_DIR="$(CURSOR_AGENT_CMD="$EXECUTOR" MOCK_MODE=honest TIMEOUT="$RUN_TIMEOUT" "$ROOT/harness/dispatch.sh" "$SPEC")"
  status="$(jq -r .dispatch_status "$RUN_DIR/dispatch.json")"
  if [[ "$status" == "ok" ]] && jq -e . "$RUN_DIR/report.json" >/dev/null 2>&1; then
    pass=$((pass+1))
  else
    echo "  run $i FAILED: dispatch_status=$status"
  fi
done
echo "  -> $pass/$N valid JSON + terminated"
[[ $pass -eq $N ]] || fail=1

# The classifier sub-tests below probe dispatch.sh's behavior and ALWAYS use the mock
# (the real binary can't be told to hang or emit garbage on demand).
echo "### Reliability: a hanging executor is killed and classified as timeout"
RUN_DIR="$(CURSOR_AGENT_CMD="$MOCK" MOCK_MODE=hang TIMEOUT=3 "$ROOT/harness/dispatch.sh" "$SPEC")"
status="$(jq -r .dispatch_status "$RUN_DIR/dispatch.json")"
echo "  -> dispatch_status=$status (want: timeout)"
[[ "$status" == "timeout" ]] || fail=1

echo "### Reliability: non-JSON output is classified as invalid_json"
RUN_DIR="$(CURSOR_AGENT_CMD="$MOCK" MOCK_MODE=badjson TIMEOUT=10 "$ROOT/harness/dispatch.sh" "$SPEC")"
status="$(jq -r .dispatch_status "$RUN_DIR/dispatch.json")"
echo "  -> dispatch_status=$status (want: invalid_json)"
[[ "$status" == "invalid_json" ]] || fail=1

echo; [[ $fail -eq 0 ]] && echo "PHASE 1 GATE: GREEN" || echo "PHASE 1 GATE: RED"
exit $fail
