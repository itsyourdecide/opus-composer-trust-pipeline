#!/usr/bin/env bash
#
# log-opus.sh <task_id> <iteration> <model> <usage_json> <brief_chars>
#
# Appends ONE record per Opus (claude) refinement call to runs/opus-metrics.jsonl. This is
# the §3 ECONOMICS feed for the ORCHESTRATOR side — the half the Composer metrics log can't
# see. It is a byproduct of a step Opus already takes (the iterate refinement), so it costs
# zero EXTRA Opus tokens (§3 cost invariant): we just record the usage the call already returned.
#
#   - opus window spend per refine (in/out/cache/total) -> p50/p90 + `r` drift by class
#   - turns per task = count of these records per task_id
#   - brief_chars = size of the brief we fed Opus -> /context-growth proxy
#
# Normalizes Claude's usage keys (input_tokens, output_tokens, cache_*_input_tokens) to the
# same {in,out,cache_read,cache_creation,total} schema the Composer log uses.
#
set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$LIB/../.." && pwd)"

TASK_ID="${1:?usage: log-opus.sh <task_id> <iteration> <model> <usage_json> <brief_chars>}"
ITERATION="${2:-0}"
MODEL="${3:-unknown}"
USAGE_JSON="${4:-{\}}"
BRIEF_CHARS="${5:-0}"

OPUS_METRICS="${OPUS_METRICS_LOG:-$ROOT/runs/opus-metrics.jsonl}"
mkdir -p "$(dirname "$OPUS_METRICS")"

jq -cn \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg task_id "$TASK_ID" \
  --argjson iteration "${ITERATION:-0}" \
  --arg model "$MODEL" \
  --argjson usage "$USAGE_JSON" \
  --argjson brief_chars "${BRIEF_CHARS:-0}" \
  '
  ($usage.input_tokens  // $usage.in  // 0) as $in |
  ($usage.output_tokens // $usage.out // 0) as $out |
  (($usage.cache_read_input_tokens // $usage.cache_read // 0)) as $cr |
  (($usage.cache_creation_input_tokens // $usage.cache_creation // 0)) as $cc |
  {
    ts: $ts, task_id: $task_id, iteration: $iteration, model: $model, kind: "iterate",
    tokens: { in: $in, out: $out, cache_read: $cr, cache_creation: $cc, total: ($in + $out) },
    brief_chars: $brief_chars
  }' >> "$OPUS_METRICS"

echo "$OPUS_METRICS"
