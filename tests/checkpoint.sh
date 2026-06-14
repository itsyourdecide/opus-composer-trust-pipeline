#!/usr/bin/env bash
#
# §4 / §8.2 gate: the deterministic checkpoint step emits a valid checkpoint and fires the
# critical-point triggers on data (not by feel).
#
#   (a) calm ledger     -> no trigger, exit 0, checkpoint_recommended=false
#   (b) milestone closed -> trigger (last event accept), exit 10
#   (c) quality degraded -> trigger (>=3 iterate on one task), exit 10
#   (d) consecutive iterate/reject -> trigger (trailing run >= limit), exit 10
#   (e) context proxy over limit -> trigger from opus-metrics brief_chars, exit 10
#
# Pure jq over synthetic ledgers; zero quota, never touches the real STATE.md/ledger.
#
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CKPT="$ROOT/harness/checkpoint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

mkledger() { printf '%s\n' "$@" > "$TMP/ledger.jsonl"; echo "$TMP/ledger.jsonl"; }
run() { # extra-env... -> sets RC and OUT_JSON globals
  CHECKPOINT_OUT="$TMP/ckpt.json" LEDGER="$1" OPUS_METRICS_LOG="${2:-/dev/null}" \
    DEGRADE_ITERS=3 CONSECUTIVE_LIMIT=2 CONTEXT_PROXY_LIMIT=24000 \
    bash "$CKPT" >/dev/null 2>&1
  RC=$?
  OUT_JSON="$(cat "$TMP/ckpt.json")"
}
sig() { jq -r ".signals.$1" <<<"$OUT_JSON"; }
rec() { jq -r '.checkpoint_recommended' <<<"$OUT_JSON"; }

echo "### (a) calm ledger: open+dispatch only -> no trigger"
L="$(mkledger \
  '{"ts":"2026-06-14T10:00:00Z","event":"open","task_id":"T-1"}' \
  '{"ts":"2026-06-14T10:01:00Z","event":"dispatch","task_id":"T-1","iteration":1}')"
run "$L"
echo "  recommended=$(rec) exit=$RC"
[[ "$(rec)" == "false" && "$RC" -eq 0 ]] || { echo "  -> FAIL"; fail=1; }

echo "### (b) milestone closed: last event accept -> trigger"
L="$(mkledger \
  '{"ts":"2026-06-14T10:00:00Z","event":"open","task_id":"T-1"}' \
  '{"ts":"2026-06-14T10:02:00Z","event":"accept","task_id":"T-1","iteration":1}')"
run "$L"
echo "  milestone_closed=$(sig milestone_closed) recommended=$(rec) exit=$RC"
[[ "$(sig milestone_closed)" == "true" && "$(rec)" == "true" && "$RC" -eq 10 ]] || { echo "  -> FAIL"; fail=1; }

echo "### (c) quality degradation: 3 iterate rounds on one task -> trigger"
L="$(mkledger \
  '{"ts":"2026-06-14T10:00:00Z","event":"open","task_id":"T-2"}' \
  '{"ts":"2026-06-14T10:01:00Z","event":"iterate","task_id":"T-2","iteration":1}' \
  '{"ts":"2026-06-14T10:02:00Z","event":"dispatch","task_id":"T-2","iteration":2}' \
  '{"ts":"2026-06-14T10:03:00Z","event":"iterate","task_id":"T-2","iteration":2}' \
  '{"ts":"2026-06-14T10:04:00Z","event":"dispatch","task_id":"T-2","iteration":3}' \
  '{"ts":"2026-06-14T10:05:00Z","event":"iterate","task_id":"T-2","iteration":3}')"
run "$L"
echo "  max_iterations_on_a_task=$(sig max_iterations_on_a_task) quality_degradation=$(sig quality_degradation) exit=$RC"
[[ "$(sig quality_degradation)" == "true" && "$RC" -eq 10 ]] || { echo "  -> FAIL"; fail=1; }

echo "### (d) consecutive iterate/reject trailing run -> trigger"
L="$(mkledger \
  '{"ts":"2026-06-14T10:00:00Z","event":"dispatch","task_id":"T-3","iteration":1}' \
  '{"ts":"2026-06-14T10:01:00Z","event":"iterate","task_id":"T-3","iteration":1}' \
  '{"ts":"2026-06-14T10:02:00Z","event":"reject","task_id":"T-3","iteration":2}')"
run "$L"
echo "  consecutive_iterate_reject=$(sig consecutive_iterate_reject) consecutive_trip=$(sig consecutive_trip) exit=$RC"
[[ "$(sig consecutive_iterate_reject)" == "2" && "$(sig consecutive_trip)" == "true" && "$RC" -eq 10 ]] || { echo "  -> FAIL"; fail=1; }

echo "### (e) context proxy over limit (opus-metrics brief_chars) -> trigger"
L="$(mkledger '{"ts":"2026-06-14T10:00:00Z","event":"dispatch","task_id":"T-4","iteration":1}')"
OM="$TMP/opus.jsonl"; printf '%s\n' '{"task_id":"T-4","brief_chars":30000}' > "$OM"
run "$L" "$OM"
echo "  context_proxy_chars=$(sig context_proxy_chars) context_near_threshold=$(sig context_near_threshold) exit=$RC"
[[ "$(sig context_near_threshold)" == "true" && "$RC" -eq 10 ]] || { echo "  -> FAIL"; fail=1; }

echo; [[ $fail -eq 0 ]] && echo "CHECKPOINT (§4/§8.2) GATE: GREEN" || echo "CHECKPOINT (§4/§8.2) GATE: RED"
exit $fail
