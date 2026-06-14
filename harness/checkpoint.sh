#!/usr/bin/env bash
#
# checkpoint.sh
#
# The DETERMINISTIC checkpoint step (§4 / §8.2) — the half the plan audit found missing.
# STATE.md is the soft state Opus AUTHORS (prose: plan, decisions, why). This is the glue
# half: a zero-Opus-token, machine-written checkpoint of what git/ledger/metrics already
# know, plus the §8.2 critical-point TRIGGERS held as data instead of "by feel". It is meant
# to run BEFORE a compaction / session switch, so a fresh session rehydrates from
# state/checkpoint.json + state/reconcile.json + STATE.md.
#
# It NEVER rewrites STATE.md (that is Opus's authored prose). It only emits a structured
# checkpoint and a recommendation.
#
# §8.2 triggers (any -> checkpoint + fresh session):
#   - context near threshold        (proxy: max Opus brief_chars from opus-metrics.jsonl)
#   - logical milestone closed       (last ledger event is accept/reject/block)
#   - quality degradation            (a task hit >= DEGRADE_ITERS iterate rounds)
#   - several iterate/reject in a row (trailing run >= CONSECUTIVE_LIMIT — context may be dirty)
#
# Emits state/checkpoint.json. Exit 10 if a checkpoint+fresh-session is recommended, else 0.
#
# Env:
#   LEDGER, OPUS_METRICS_LOG, CHECKPOINT_OUT — override the input/output paths (tests use this).
#   CONTEXT_PROXY_LIMIT (24000), DEGRADE_ITERS (3), CONSECUTIVE_LIMIT (2) — trigger thresholds.
#
set -uo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HARNESS_DIR/.." && pwd)"

LEDGER="${LEDGER:-$ROOT/state/ledger.jsonl}"
OPUS_METRICS="${OPUS_METRICS_LOG:-$ROOT/runs/opus-metrics.jsonl}"
OUT="${CHECKPOINT_OUT:-$ROOT/state/checkpoint.json}"
CONTEXT_PROXY_LIMIT="${CONTEXT_PROXY_LIMIT:-24000}"
DEGRADE_ITERS="${DEGRADE_ITERS:-3}"
CONSECUTIVE_LIMIT="${CONSECUTIVE_LIMIT:-2}"

[[ -f "$LEDGER" ]] || { echo "checkpoint: ledger not found: $LEDGER" >&2; jq -n '{error:"no ledger"}' | tee "$OUT" >/dev/null; exit 2; }

# /context-growth proxy: the largest brief we ever fed Opus (§3). A real /context number
# would be better; this is the deterministic stand-in until that is wired.
CTX=0
if [[ -f "$OPUS_METRICS" ]]; then
  CTX="$(jq -s 'map(.brief_chars // 0) | (max // 0)' "$OPUS_METRICS" 2>/dev/null || echo 0)"
fi
[[ "$CTX" =~ ^[0-9]+$ ]] || CTX=0

mkdir -p "$(dirname "$OUT")"
jq -s \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson ctx "$CTX" \
  --argjson ctxlim "$CONTEXT_PROXY_LIMIT" \
  --argjson degit "$DEGRADE_ITERS" \
  --argjson conlim "$CONSECUTIVE_LIMIT" '
  . as $ev
  | ($ev | length) as $n
  | (($ev[-1].event) // "") as $last
  | ($ev | map(select(.event=="iterate")) | group_by(.task_id)
         | map({task:.[0].task_id, iters:length})) as $iters
  | ($ev | group_by(.task_id)
         | map({task:.[0].task_id, latest:(sort_by(.ts)|last.event), events:length})) as $tasks
  # trailing run of iterate/reject (count from the end until a non-{iterate,reject} event)
  | ([ ($ev|reverse)[].event ]) as $rev
  | (reduce range(0; ($rev|length)) as $i ({stop:false,c:0};
        if .stop then .
        elif ($rev[$i]=="iterate" or $rev[$i]=="reject") then {stop:false,c:(.c+1)}
        else {stop:true,c:.c} end) | .c) as $consec
  | (($iters | map(.iters) | max) // 0) as $maxit
  | {
      ts: $ts,
      ledger_events: $n,
      last_event: $last,
      tasks: $tasks,
      iterations_by_task: $iters,
      ledger_tail: ($ev[-8:] | map({ts, event, task_id})),
      signals: {
        context_proxy_chars: $ctx,
        context_proxy_limit: $ctxlim,
        context_near_threshold: ($ctx >= $ctxlim),
        milestone_closed: ($last=="accept" or $last=="reject" or $last=="block"),
        consecutive_iterate_reject: $consec,
        consecutive_limit: $conlim,
        consecutive_trip: ($consec >= $conlim),
        max_iterations_on_a_task: $maxit,
        degrade_iters_limit: $degit,
        quality_degradation: ($maxit >= $degit)
      }
    }
  | .checkpoint_recommended = (
      .signals.context_near_threshold or .signals.milestone_closed
      or .signals.consecutive_trip or .signals.quality_degradation)
  | .reasons = [
      (if .signals.context_near_threshold then "context proxy \(.signals.context_proxy_chars) >= \(.signals.context_proxy_limit) chars (near window threshold)" else empty end),
      (if .signals.milestone_closed then "logical milestone closed (last event: \(.last_event))" else empty end),
      (if .signals.consecutive_trip then "\(.signals.consecutive_iterate_reject) consecutive iterate/reject (context may be polluted)" else empty end),
      (if .signals.quality_degradation then "a task reached \(.signals.max_iterations_on_a_task) iterate rounds (quality degradation)" else empty end)
    ]
' "$LEDGER" | tee "$OUT"

REC="$(jq -r '.checkpoint_recommended' "$OUT" 2>/dev/null)"
if [[ "$REC" == "true" ]]; then
  echo "checkpoint: RECOMMENDED — $(jq -rc '.reasons' "$OUT")" >&2
  exit 10
fi
echo "checkpoint: no critical-point trigger; continue current session" >&2
exit 0
