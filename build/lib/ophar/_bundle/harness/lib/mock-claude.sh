#!/usr/bin/env bash
#
# mock-claude.sh — stand-in for `claude -p --output-format json`, so the iterate path
# (Opus spec-refinement) and Opus-window telemetry are exercised at ZERO Claude quota.
#
# Emits the real Claude Code envelope shape: {type, result, usage:{input_tokens,...}}.
# `result` is a valid refined task spec, derived from the SPEC_SKELETON block that
# iterate.sh appends to the brief (read from stdin). The mock ignores all CLI flags.
#
# Env:
#   MOCK_CLAUDE_IN, MOCK_CLAUDE_OUT, MOCK_CLAUDE_CACHE — override the reported token counts.
#
set -uo pipefail
BRIEF="$(cat)"

# Everything after the sentinel line is the spec skeleton iterate.sh embedded.
SKEL="$(printf '%s\n' "$BRIEF" | awk 'f{print} /### SPEC_SKELETON/{f=1}')"

REFINED="$(jq -c '
  .prompt = ("Refined: " + (.prompt // "") +
             " Implement a generally correct solution; do not special-case the visible inputs.")
' <<<"$SKEL" 2>/dev/null)"
[[ -n "$REFINED" ]] || REFINED='{"task_id":"T-MOCK","prompt":"refined (mock)"}'

jq -n \
  --arg result "$REFINED" \
  --argjson in  "${MOCK_CLAUDE_IN:-1820}" \
  --argjson out "${MOCK_CLAUDE_OUT:-240}" \
  --argjson cache "${MOCK_CLAUDE_CACHE:-6100}" \
  '{
     type: "result", subtype: "success", is_error: false,
     result: $result, session_id: "mock-claude", num_turns: 1, duration_ms: 1200,
     total_cost_usd: 0.012,
     usage: { input_tokens: $in, output_tokens: $out,
              cache_read_input_tokens: $cache, cache_creation_input_tokens: 0 }
   }'
