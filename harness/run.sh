#!/usr/bin/env bash
#
# run.sh <task-spec.json>
#
# One closed loop (Phase 3 skeleton) with Phase-6 hardening: SMART retry-on-unreliable.
#
#   UNTRUSTED  - what the executor claims (adapted from the real schema). Hint + metrics.
#   TRUSTED    - what actually happened (§6.2 ground truth). The ONLY basis for a verdict.
#
# Retry policy (driven by a real observation: a hung process often ALREADY did the work):
#   - work_ok                         -> done, stop. (Even if the process timed out: the
#                                        trusted layer confirms the work, so no retry.)
#   - unreliable (timeout/bad json)
#     AND not work_ok                 -> transient executor failure, nothing usable -> RETRY.
#   - reliable but not work_ok        -> a genuine result (red tests / scope break). Retrying
#                                        the same prompt won't help -> stop; Opus iterates (§6.4).
#
# The accept/iterate/reject verdict itself is Opus's job and is NOT decided here.
#
# Env: RETRIES (default 2 -> up to 3 attempts).
#
set -uo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HARNESS_DIR/lib"
SPEC="${1:?usage: run.sh <task-spec.json>}"
RETRIES="${RETRIES:-2}"

work_ok_of()   { jq -e '.visible_tests.passed and ((.scope.out_of_scope_touched|length)==0) and ((.diff_name_only|length)>0) and ((.held_out_checks.ran|not) or .held_out_checks.passed) and ((.typecheck.ran|not) or .typecheck.passed) and ((.lint.ran|not) or .lint.passed)' "$1" >/dev/null 2>&1; }
reliable_of()  { [[ "$(jq -r .dispatch_status "$1")" == "ok" ]]; }

attempt=0
while :; do
  attempt=$((attempt+1))
  RUN_DIR="$("$HARNESS_DIR/dispatch.sh" "$SPEC")"
  "$HARNESS_DIR/ground-truth.sh" "$RUN_DIR" >/dev/null

  if work_ok_of "$RUN_DIR/ground-truth.json"; then
    outcome="work_ok"; break
  elif ! reliable_of "$RUN_DIR/dispatch.json" && [[ $attempt -le $RETRIES ]]; then
    echo "  [retry] attempt $attempt unreliable ($(jq -r .dispatch_status "$RUN_DIR/dispatch.json")) and no usable work — retrying" >&2
    continue
  else
    outcome="stopped"; break
  fi
done
echo "$attempt" > "$RUN_DIR/attempts"

DISPATCH="$RUN_DIR/dispatch.json"; GT="$RUN_DIR/ground-truth.json"
NORM="$("$LIB/adapt-report.sh" "$RUN_DIR/report.json")"
METRICS="$("$LIB/log-metrics.sh" "$RUN_DIR")"

echo "================ RUN $(jq -r .task_id "$RUN_DIR/run.json")  (attempts: $attempt) ================"
echo "--- dispatch (reliability) ---"; jq . "$DISPATCH"
echo "--- UNTRUSTED executor claim (adapted from real schema) ---"; echo "$NORM" | jq .
echo "--- TRUSTED ground truth (§6.2) ---"; jq . "$GT"

echo "--- STRUCTURAL CHECK (deterministic, not the verdict) ---"
jq -n --argjson dispatch "$(cat "$DISPATCH")" --argjson gt "$(cat "$GT")" \
  '{ tests_green: $gt.visible_tests.passed,
     scope_clean: (($gt.scope.out_of_scope_touched|length)==0),
     made_changes: (($gt.diff_name_only|length)>0),
     held_out_ran: ($gt.held_out_checks.ran // false),
     held_out_ok: (($gt.held_out_checks.ran|not) or $gt.held_out_checks.passed),
     typecheck_ok: (($gt.typecheck.ran|not) or $gt.typecheck.passed),
     lint_ok: (($gt.lint.ran|not) or $gt.lint.passed),
     dispatch_status: $dispatch.dispatch_status }
   | . + { work_ok: (.tests_green and .scope_clean and .made_changes and .held_out_ok and .typecheck_ok and .lint_ok),
           dispatch_reliable: (.dispatch_status=="ok") }
   | . + { reliability_incident: (.dispatch_reliable|not),
           reward_hack_suspected: (.tests_green and .scope_clean and .held_out_ran and (.held_out_ok|not)) }'

echo "metrics -> $METRICS"
echo "RUN_DIR=$RUN_DIR"
# write a pointer for orchestrate.sh to pick up without parsing mixed stdout
echo "$RUN_DIR" > "$(dirname "$RUN_DIR")/.last-run-dir"
