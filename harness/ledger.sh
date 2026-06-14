#!/usr/bin/env bash
#
# ledger.sh <event> <task_id> [json_extra]
#
# Appends one timestamped JSONL event to state/ledger.jsonl.
# The ledger is the structural task journal — Opus reads it on session resume
# to know what happened without trusting prose summaries.
#
# Events: open | dispatch | accept | iterate | reject | block | note
#
# Usage:
#   ledger.sh open    T-0002 '{"spec_file":"tasks/T-0002.json"}'
#   ledger.sh accept  T-0002 '{"run_dir":"runs/T-0002","attempt":1}'
#   ledger.sh iterate T-0002 '{"run_dir":"runs/T-0002","reason":"tests failed","attempt":1}'
#   ledger.sh note    T-0002 '{"msg":"manually unblocked after infra fix"}'
#
set -uo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$HARNESS_DIR/../state"
mkdir -p "$STATE_DIR"
LEDGER="$STATE_DIR/ledger.jsonl"

EVENT="${1:?usage: ledger.sh <event> <task_id> [json_extra]}"
TASK_ID="${2:?usage: ledger.sh <event> <task_id> [json_extra]}"
EXTRA="${3:-}"
# braces in a ${:-} default get mis-parsed (${3:-{}} appends a stray '}'), so guard separately.
[[ -z "$EXTRA" ]] && EXTRA='{}'
# tolerate a malformed payload rather than dropping the whole ledger event.
jq -e . >/dev/null 2>&1 <<<"$EXTRA" || EXTRA='{}'

jq -cn \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg event "$EVENT" \
  --arg task_id "$TASK_ID" \
  --argjson extra "$EXTRA" \
  '{ts:$ts, event:$event, task_id:$task_id} + $extra' \
  >> "$LEDGER"

echo "ledger -> $LEDGER  [$EVENT $TASK_ID]" >&2
