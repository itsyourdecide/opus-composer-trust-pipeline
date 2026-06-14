#!/usr/bin/env bash
#
# verdict.sh <run-dir> [max_iterations]
#
# Deterministic verdict from ground truth + dispatch state (§6.4).
# Never reads the executor's report — only ground-truth.json and dispatch.json.
#
#   accept  — work_ok=true; the task is done.
#   iterate — work_ok=false, dispatch_reliable=true, attempt < MAX_ITERATIONS;
#             Opus should refine the spec and try again.
#   reject  — work_ok=false, dispatch_reliable=true, attempt >= MAX_ITERATIONS;
#             giving up after N attempts with clear failures.
#   block   — dispatch was never reliable (exhausted retries in run.sh); no
#             usable ground truth; human or Opus should investigate infra.
#
# Emits verdict.json into the run-dir and also prints it to stdout.
#
set -uo pipefail
RUN_DIR="${1:?usage: verdict.sh <run-dir> [max_iterations] [iteration]}"
MAX_ITERATIONS="${2:-${MAX_ITERATIONS:-3}}"
# The reject threshold is keyed to the LOGICAL orchestrate iteration (how many
# times Opus has refined the spec), NOT run.sh's mechanical retry counter. The
# caller passes it as $3; standalone callers fall back to the attempts file.
ITERATION_ARG="${3:-}"

GT="$RUN_DIR/ground-truth.json"
DISPATCH="$RUN_DIR/dispatch.json"
ATTEMPTS_FILE="$RUN_DIR/attempts"

[[ -f "$GT" ]]       || { echo "verdict: ground-truth.json not found in $RUN_DIR" >&2; exit 2; }
[[ -f "$DISPATCH" ]] || { echo "verdict: dispatch.json not found in $RUN_DIR" >&2; exit 2; }

if [[ -n "$ITERATION_ARG" ]]; then
  ATTEMPT="$ITERATION_ARG"
else
  ATTEMPT=1
  [[ -f "$ATTEMPTS_FILE" ]] && ATTEMPT="$(cat "$ATTEMPTS_FILE")"
fi

TASK_ID="$(jq -r '.task_id' "$RUN_DIR/run.json" 2>/dev/null || echo "unknown")"

work_ok() {
  # Acceptance requires held-out to pass too (or to not have run). A solution that
  # is green on visible tests + scope but red on held-out is a reward-hack (§9) and
  # must NOT be accepted.
  jq -e '.visible_tests.passed and
         ((.scope.out_of_scope_touched|length)==0) and
         ((.diff_name_only|length)>0) and
         ((.held_out_checks.ran|not) or .held_out_checks.passed) and
         ((.typecheck.ran|not) or .typecheck.passed) and
         ((.lint.ran|not) or .lint.passed)' "$GT" >/dev/null 2>&1
}

dispatch_reliable() {
  [[ "$(jq -r .dispatch_status "$DISPATCH")" == "ok" ]]
}

if work_ok; then
  VERDICT="accept"
  REASON="all visible tests pass, scope clean, changes present"
elif dispatch_reliable; then
  if [[ $ATTEMPT -lt $MAX_ITERATIONS ]]; then
    VERDICT="iterate"
    # §9.5: when held-out fails but visible passes, the reason stays GENERALIZED —
    # it must not leak the held-out assertion (that would convert it to a visible test).
    REASON="$(jq -r '
      if (.visible_tests.passed | not) then "tests failed"
      elif ((.scope.out_of_scope_touched|length)>0) then "scope violation: \(.scope.out_of_scope_touched|join(", "))"
      elif ((.diff_name_only|length)==0) then "no changes made"
      elif (.typecheck.ran and (.typecheck.passed|not)) then "typecheck failed"
      elif (.lint.ran and (.lint.passed|not)) then "lint failed"
      elif (.held_out_checks.ran and (.held_out_checks.passed|not)) then "passes visible tests but fails held-out checks — solution likely overfits; require general correctness"
      else "work_ok=false (unknown reason)"
      end' "$GT")"
  else
    VERDICT="reject"
    REASON="reliable failure after $ATTEMPT/$MAX_ITERATIONS attempts"
  fi
else
  VERDICT="block"
  REASON="dispatch unreliable ($(jq -r .dispatch_status "$DISPATCH")) after retry exhaustion"
fi

jq -cn \
  --arg verdict "$VERDICT" \
  --arg reason "$REASON" \
  --arg task_id "$TASK_ID" \
  --argjson attempt "$ATTEMPT" \
  --argjson max "$MAX_ITERATIONS" \
  '{verdict:$verdict, reason:$reason, task_id:$task_id, attempt:$attempt, max_iterations:$max}' \
  | tee "$RUN_DIR/verdict.json"
