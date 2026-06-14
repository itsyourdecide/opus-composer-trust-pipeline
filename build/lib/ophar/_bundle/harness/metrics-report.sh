#!/usr/bin/env bash
#
# metrics-report.sh [metrics.jsonl]
#
# The §3 / §6.5 reader on top of the raw telemetry feed (runs/metrics.jsonl). Pure
# deterministic glue — ZERO Opus tokens. Computes the rolling self-baseline:
#
#   - overall: run count, work_ok rate, dispatch reliability, total Composer tokens
#   - §6.5 trust signals:
#       overclaim_rate      = share of runs Composer claimed success but work_ok is false
#       held_out vs visible = pass rates; a persistent held-out lag = fitting to visible
#       reward_hack_count   = visible+scope green but held-out red (caught overfits)
#   - §3 quantile rigor:
#       reliability         = timeout / invalid_json / failed-before-completion broken out
#                             SEPARATELY (plan principle 2: failures never inflate cost p50)
#       quantiles           = p50/p90/p95 of cost+latency over COMPLETED runs only, each with
#                             n + low_confidence_p90/p95 flags (plan principle 4: p95 on a
#                             handful of runs is statistically empty — flag it, don't trust it)
#   - per-class rollup: n, work_ok rate, attempts/wall-clock quantiles (completed-only)
#
# Emits a JSON summary to stdout (and a short human table to stderr).
#
# Env: P90_MIN_N (30) / P95_MIN_N (200) — sample sizes below which a quantile is flagged
#      low_confidence (the §3 "treat high quantiles as indicator, not verdict" caveat).
#
set -uo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METRICS="${1:-$HARNESS_DIR/../runs/metrics.jsonl}"
[[ -f "$METRICS" ]] || { echo "metrics-report: no metrics at $METRICS" >&2; exit 2; }
P90_MIN_N="${P90_MIN_N:-30}"
P95_MIN_N="${P95_MIN_N:-200}"

# Slurp the JSONL into an array and compute everything in one jq pass.
SUMMARY="$(jq -s --argjson p90min "$P90_MIN_N" --argjson p95min "$P95_MIN_N" '
  def rate(f): if length==0 then null else ((map(select(f)) | length) / length) end;
  def median: if length==0 then null else (sort | .[ (length/2 | floor) ]) end;
  def quant($p): if length==0 then null else (sort | .[ (($p) * (length-1) | round) ]) end;
  # qstats: p50/p90/p95 + mean + sample-size confidence flags over the array it is fed.
  def qstats: . as $a | ($a|length) as $m
    | { n: $m,
        p50: ($a|quant(0.5)), p90: ($a|quant(0.9)), p95: ($a|quant(0.95)),
        mean: (if $m==0 then null else (($a|add)/$m) end),
        low_confidence_p90: ($m < $p90min),
        low_confidence_p95: ($m < $p95min) };

  . as $all
  | ($all | length) as $n
  # "completed" = a run that produced usable ground truth (dispatch reliable). Cost/latency
  # quantiles are computed ONLY over these; failures are reported separately (plan §3.2).
  | ($all | map(select(.dispatch_status=="ok"))) as $done
  | {
      runs: $n,
      work_ok_rate:        ($all | rate(.work_ok)),
      dispatch_ok_rate:    ($all | rate(.dispatch_status=="ok")),
      # §6.5: claimed success but ground truth says not acceptable
      overclaim_rate:      ($all | rate(.claimed_success and (.work_ok|not))),
      # §6.5: held-out vs visible (only over runs where held-out actually ran)
      visible_pass_rate:   ($all | rate(.tests_passed)),
      held_out_pass_rate:  (($all | map(select(.held_out_ran==true))) | rate(.held_out_passed==true)),
      held_out_runs:       (($all | map(select(.held_out_ran==true))) | length),
      reward_hack_count:   ($all | map(select(.reward_hack_suspected==true)) | length),
      composer_tokens_total: ($all | map(.composer_tokens.total // 0) | add),
      # legacy keys: wall-clock over ALL runs (kept for back-compat; prefer .quantiles below)
      wall_clock_s_p50:    ($all | map(.wall_clock_s // 0) | median),
      wall_clock_s_p90:    ($all | map(.wall_clock_s // 0) | quant(0.9)),
      # §3.2 reliability, counted SEPARATELY from the cost quantiles
      reliability: {
        n: $n,
        completed: ($done | length),
        ok_rate:               ($all | rate(.dispatch_status=="ok")),
        timeout_rate:          ($all | rate(.dispatch_status=="timeout")),
        invalid_json_rate:     ($all | rate(.dispatch_status=="invalid_json")),
        failed_before_completion_rate: ($all | rate(.dispatch_status!="ok"))
      },
      # §3 cost/latency quantiles — COMPLETED runs only, with sample-size confidence flags
      quantiles: {
        basis: "completed runs (dispatch_status==ok)",
        p90_min_n: $p90min, p95_min_n: $p95min,
        wall_clock_s:   ($done | map(.wall_clock_s // 0)        | qstats),
        attempts:       ($done | map(.attempts // 1)            | qstats),
        composer_tokens:($done | map(.composer_tokens.total // 0) | qstats)
      },
      by_class:
        ( $all
          | group_by(.class)
          | map({
              key: (.[0].class // "unclassified"),
              value: ( (map(select(.dispatch_status=="ok"))) as $c
                | {
                    n: length,
                    completed: ($c | length),
                    work_ok_rate: rate(.work_ok),
                    failed_before_completion_rate: rate(.dispatch_status!="ok"),
                    attempts_median: (map(.attempts // 1) | median),
                    wall_clock_s_median: (map(.wall_clock_s // 0) | median),
                    wall_clock_s: ($c | map(.wall_clock_s // 0) | qstats)
                  } )
            })
          | from_entries )
    }
' "$METRICS")"

# --- §3 ECONOMICS: orchestrator (Opus) side, from runs/opus-metrics.jsonl (one record per
# refine call). Joined to the Composer log by task_id to split by class. This is the rolling
# self-baseline for `r` (per-task Opus spend vs the class p50) and the /context-growth proxy. ---
OPUS_METRICS="${OPUS_METRICS:-$(dirname "$METRICS")/opus-metrics.jsonl}"
if [[ -s "$OPUS_METRICS" ]]; then
  OPUS="$(jq -s --slurpfile composer "$METRICS" '
    def median: if length==0 then null else (sort | .[ (length/2 | floor) ]) end;
    def quant($p): if length==0 then null else (sort | .[ (($p) * (length-1) | round) ]) end;
    ( reduce ($composer[]) as $r ({}; .[$r.task_id] = ($r.class // "unclassified")) ) as $cls
    | ( group_by(.task_id) | map({
        task_id: .[0].task_id,
        class: ($cls[.[0].task_id] // "unclassified"),
        opus_tokens: (map(.tokens.total // 0) | add),
        turns: length,
        brief_chars_max: (map(.brief_chars // 0) | max)
      }) ) as $per_task
    | {
        opus_refine_calls:        length,
        opus_tokens_total:        (map(.tokens.total // 0) | add),
        opus_tokens_per_task_p50: ($per_task | map(.opus_tokens) | median),
        opus_tokens_per_task_p90: ($per_task | map(.opus_tokens) | quant(0.9)),
        opus_tokens_per_task_p95: ($per_task | map(.opus_tokens) | quant(0.95)),
        opus_turns_p50:           ($per_task | map(.turns) | median),
        opus_turns_p90:           ($per_task | map(.turns) | quant(0.9)),
        context_proxy_chars_p90:  ($per_task | map(.brief_chars_max) | quant(0.9)),
        by_class:
          ( $per_task | group_by(.class)
            | map({ key: .[0].class,
                    value: { n: length, opus_tokens_p50: (map(.opus_tokens) | median) } })
            | from_entries )
      }
  ' "$OPUS_METRICS")"
else
  OPUS='null'
fi
SUMMARY="$(jq -n --argjson base "$SUMMARY" --argjson opus "$OPUS" '$base + {opus:$opus}')"

echo "$SUMMARY"

# --- human-readable digest on stderr ---
{
  echo "── metrics digest ($(jq -r .runs <<<"$SUMMARY") runs) ─────────────────────"
  jq -r '
    "work_ok           : \((.work_ok_rate // 0)*100|round)%",
    "dispatch ok       : \((.dispatch_ok_rate // 0)*100|round)%",
    "overclaim (§6.5)  : \((.overclaim_rate // 0)*100|round)%   (claimed success, not work_ok)",
    "visible pass      : \((.visible_pass_rate // 0)*100|round)%",
    "held-out pass     : \(if .held_out_pass_rate==null then "n/a" else "\((.held_out_pass_rate)*100|round)%" end)   (over \(.held_out_runs) held-out runs)",
    "reward-hacks caught: \(.reward_hack_count)",
    "composer tokens   : \(.composer_tokens_total)"
  ' <<<"$SUMMARY"
  jq -r '.reliability |
    "reliability (§3.2): completed \(.completed)/\(.n)   timeout \((.timeout_rate*100)|round)%  bad-json \((.invalid_json_rate*100)|round)%  failed \((.failed_before_completion_rate*100)|round)%"
  ' <<<"$SUMMARY"
  jq -r '.quantiles as $q |
    "quantiles (\($q.basis), n=\($q.wall_clock_s.n)):",
    "  wall s   p50/p90/p95: \($q.wall_clock_s.p50)/\($q.wall_clock_s.p90)/\($q.wall_clock_s.p95)\(if $q.wall_clock_s.low_confidence_p95 then "  [p95 low-confidence: n<\($q.p95_min_n)]" else "" end)",
    "  attempts p50/p90/p95: \($q.attempts.p50)/\($q.attempts.p90)/\($q.attempts.p95)",
    "  comp tok p50/p90/p95: \($q.composer_tokens.p50)/\($q.composer_tokens.p90)/\($q.composer_tokens.p95)"
  ' <<<"$SUMMARY"
  echo "per class:"
  jq -r '.by_class | to_entries[] | "  \(.key): n=\(.value.n) completed=\(.value.completed) work_ok=\((.value.work_ok_rate // 0)*100|round)% failed=\((.value.failed_before_completion_rate*100)|round)% wall p50/p95~\(.value.wall_clock_s.p50)/\(.value.wall_clock_s.p95)s"' <<<"$SUMMARY"
  if [[ "$(jq -r '.opus' <<<"$SUMMARY")" != "null" ]]; then
    echo "opus window (§3 economics):"
    jq -r '.opus |
      "  refine calls     : \(.opus_refine_calls)   tokens total: \(.opus_tokens_total)",
      "  tokens/task p50/p90: \(.opus_tokens_per_task_p50)/\(.opus_tokens_per_task_p90)",
      "  turns/task p50/p90 : \(.opus_turns_p50)/\(.opus_turns_p90)   context-proxy chars p90: \(.context_proxy_chars_p90)"
    ' <<<"$SUMMARY"
    jq -r '.opus.by_class | to_entries[] | "  r-baseline \(.key): n=\(.value.n) opus_tokens_p50=\(.value.opus_tokens_p50)"' <<<"$SUMMARY"
  fi
  echo "────────────────────────────────────────────────────────"
} >&2
