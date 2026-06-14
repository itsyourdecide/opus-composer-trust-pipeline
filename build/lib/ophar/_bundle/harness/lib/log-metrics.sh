#!/usr/bin/env bash
#
# log-metrics.sh <run-dir>
#
# Appends ONE record per run to runs/metrics.jsonl. Pure deterministic glue — ZERO Opus
# tokens (§3 cost invariant). Combines:
#   - a-priori [балл Opus], locked at dispatch (run.json): class, complexity, spec_clarity
#   - a-posteriori [клей] from ground truth + dispatch: outcome, scope, tokens, wall-clock
# This is the Phase-0 prod telemetry / rolling self-baseline; quantiles are computed later
# off this log, per class.
#
set -uo pipefail
RUN_DIR="${1:?usage: log-metrics.sh <run-dir>}"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METRICS="${METRICS_LOG:-$RUN_DIR/../metrics.jsonl}"

RUN="$RUN_DIR/run.json"
DISPATCH="$RUN_DIR/dispatch.json"
GT="$RUN_DIR/ground-truth.json"
NORM="$("$LIB/adapt-report.sh" "$RUN_DIR/report.json")"
ATTEMPTS="$(cat "$RUN_DIR/attempts" 2>/dev/null || echo 1)"

jq -cn \
  --argjson run "$(cat "$RUN")" \
  --argjson dispatch "$(cat "$DISPATCH")" \
  --argjson gt "$(cat "$GT")" \
  --argjson norm "$NORM" \
  --argjson attempts "$ATTEMPTS" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
     ts: $ts,
     task_id: $run.task_id,
     model: $run.model,
     # a priori (locked at dispatch)
     class: $run.a_priori.class,
     complexity: $run.a_priori.complexity,
     spec_clarity: $run.a_priori.spec_clarity,
     # a posteriori (glue, from ground truth)
     attempts: $attempts,
     dispatch_status: $dispatch.dispatch_status,
     wall_clock_s: $dispatch.wall_clock_s,
     work_ok: ($gt.visible_tests.passed
               and (($gt.scope.out_of_scope_touched|length)==0)
               and (($gt.diff_name_only|length)>0)
               and (($gt.held_out_checks.ran|not) or $gt.held_out_checks.passed)
               and (($gt.typecheck.ran|not) or $gt.typecheck.passed)
               and (($gt.lint.ran|not) or $gt.lint.passed)),
     tests_passed: $gt.visible_tests.passed,
     typecheck_ran: ($gt.typecheck.ran // false),
     typecheck_passed: $gt.typecheck.passed,
     lint_ran: ($gt.lint.ran // false),
     lint_passed: $gt.lint.passed,
     # §6.5 anti-overfit signal: held-out vs visible pass rate (held_out_ran=false when no set)
     held_out_ran: ($gt.held_out_checks.ran // false),
     # NB: read the key directly; the jq // operator also replaces false, which would
     # turn a real held-out failure (passed false) into null.
     held_out_passed: $gt.held_out_checks.passed,
     reward_hack_suspected: ($gt.visible_tests.passed
               and (($gt.scope.out_of_scope_touched|length)==0)
               and ($gt.held_out_checks.ran // false)
               and (($gt.held_out_checks.passed // false)|not)),
     out_of_scope_count: ($gt.scope.out_of_scope_touched | length),
     files_changed: ($gt.diff_name_only | length),
     diff_stat: $gt.diff_stat,
     # trust material (untrusted claim vs reality is compared off-log)
     claimed_success: $norm.claimed_success,
     report_present: $norm.report_present,
     composer_tokens: $norm.tokens
   }' >> "$METRICS"

echo "$METRICS"
