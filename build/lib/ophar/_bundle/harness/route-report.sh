#!/usr/bin/env bash
#
# route-report.sh [metrics.jsonl]
#
# The §2-Phase-0 / §5 ROUTING DECISION layer — the half the metrics baseline feeds into.
# Pure deterministic glue, ZERO Opus tokens. Reads runs/metrics.jsonl, aggregates per
# TASK (a task may span several iteration records), computes the composite operational
# "dud" flag, and turns the (class × complexity) dud-rate table into a route decision:
# keep the cell in the pipeline, or route it AROUND (back to Claude Code / manual).
#
# Composite dud (§3 "затупил", operational, not a feeling) — a task is a dud if ANY of:
#   - it never reached work_ok (failed outright);
#   - it needed >= DUD_ITERS iteration rounds to get there;
#   - it overclaimed (claimed success while ground truth said not work_ok);
#   - it reward-hacked (visible+scope green, held-out red).
#
# Decision per cell:
#   n < ROUTE_MIN_N            -> "pipeline" (insufficient data — DON'T route away on thin
#                                 data; this is also the §3 anti-freezing rule);
#   dud_rate > DUD_THRESHOLD   -> "route_around";
#   else                       -> "pipeline".
# Even a routed-around cell keeps EXPLORATION_SHARE of tasks in the pipeline (anti-freezing:
# stop sending a class and its table entry ossifies). Model versions per cell are surfaced
# so a post-update jump isn't misread as task difficulty.
#
# Env: DUD_THRESHOLD (0.20) DUD_ITERS (3) ROUTE_MIN_N (20) EXPLORATION_SHARE (0.10).
#
set -uo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METRICS="${1:-$HARNESS_DIR/../runs/metrics.jsonl}"
[[ -f "$METRICS" ]] || { echo "route-report: no metrics at $METRICS" >&2; exit 2; }

DUD_THRESHOLD="${DUD_THRESHOLD:-0.20}"
DUD_ITERS="${DUD_ITERS:-3}"
ROUTE_MIN_N="${ROUTE_MIN_N:-20}"
EXPLORATION_SHARE="${EXPLORATION_SHARE:-0.10}"

SUMMARY="$(jq -s \
  --argjson thr "$DUD_THRESHOLD" --argjson di "$DUD_ITERS" \
  --argjson minn "$ROUTE_MIN_N" --argjson expl "$EXPLORATION_SHARE" '
  # --- aggregate per task (a task = all its iteration records) ---
  ( group_by(.task_id) | map(
      (sort_by(.ts)) as $r
      | {
          task_id: $r[0].task_id,
          class: ($r[0].class // "unclassified"),
          complexity: ($r[0].complexity),
          iterations: ($r | length),
          final_work_ok: ($r | any(.work_ok == true)),
          first_attempt_fail: (($r[0].work_ok // false) | not),
          overclaim: ($r | any(.claimed_success == true and (.work_ok != true))),
          reward_hack: ($r | any(.reward_hack_suspected == true)),
          unreliable: ($r | any(.dispatch_status != "ok")),
          models: ($r | map(.model) | map(select(. != null)) | unique)
        }
      | .dud = ((.final_work_ok | not) or (.iterations >= $di) or .overclaim or .reward_hack)
  )) as $pt

  | def decide($n; $dr):
      if $n < $minn then "pipeline"
      elif $dr > $thr then "route_around"
      else "pipeline" end;
  {
      params: { dud_threshold:$thr, dud_iters:$di, route_min_n:$minn, exploration_share:$expl },
      tasks_seen: ($pt | length),
      components: {
        never_passed:       ($pt | map(select(.final_work_ok | not)) | length),
        many_iterations:    ($pt | map(select(.iterations >= $di))   | length),
        overclaim:          ($pt | map(select(.overclaim))           | length),
        reward_hack:        ($pt | map(select(.reward_hack))         | length),
        first_attempt_fail: ($pt | map(select(.first_attempt_fail))  | length),
        duds:               ($pt | map(select(.dud))                 | length)
      },
      by_cell: ( $pt | group_by("\(.class)/\(.complexity)")
        | map( (.[0].class) as $c | (.[0].complexity) as $cx
          | length as $n | (map(select(.dud)) | length) as $d
          | (map(.models) | add | unique) as $models
          | ($d / $n) as $dr
          | { key: "\($c)/\($cx)",
              value: {
                class:$c, complexity:$cx, n:$n, duds:$d, dud_rate:$dr,
                low_confidence: ($n < $minn),
                models:$models, mixed_model_versions: (($models | length) > 1),
                decision: decide($n; $dr),
                reason: ( if $n < $minn then "insufficient sample (n<\($minn)) — keep in pipeline to gather data"
                          elif $dr > $thr then "dud_rate \(($dr*100)|floor)% > \(($thr*100)|floor)% threshold — route around (keep \(($expl*100)|floor)% exploration)"
                          else "dud_rate \(($dr*100)|floor)% within threshold" end )
              } } )
        | from_entries ),
      by_class: ( $pt | group_by(.class)
        | map( (.[0].class) as $c | length as $n | (map(select(.dud)) | length) as $d
          | ($d / $n) as $dr
          | { key:$c, value:{ n:$n, duds:$d, dud_rate:$dr, decision: decide($n; $dr) } } )
        | from_entries )
    }
  | .route_around = ( [ .by_cell | to_entries[] | select(.value.decision == "route_around") | .key ] )
' "$METRICS")"

echo "$SUMMARY"

# --- human digest on stderr ---
{
  echo "── routing table ($(jq -r .tasks_seen <<<"$SUMMARY") tasks) ──────────────────"
  jq -r '.params | "thresholds: dud>\(.dud_threshold*100)% over n>=\(.route_min_n) tasks; dud=fail|>=\(.dud_iters) iters|overclaim|reward-hack; explore \(.exploration_share*100)%"' <<<"$SUMMARY"
  echo "class × complexity → decision:"
  jq -r '.by_cell | to_entries[] |
    "  \(.key): n=\(.value.n) duds=\(.value.duds) (\((.value.dud_rate*100)|floor)%) → \(.value.decision)\(if .value.low_confidence then " [thin data]" else "" end)\(if .value.mixed_model_versions then " [mixed models]" else "" end)"' <<<"$SUMMARY"
  ra="$(jq -r '.route_around | if length==0 then "(none)" else join(", ") end' <<<"$SUMMARY")"
  echo "route AROUND: $ra"
  echo "────────────────────────────────────────────────────────"
} >&2
