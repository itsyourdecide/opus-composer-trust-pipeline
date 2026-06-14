#!/usr/bin/env bash
#
# iterate.sh <run-dir> <task-spec.json>
#
# Opus-driven prompt refinement (§6.4 iterate path).
# Reads the ground-truth failure evidence from <run-dir>: test log, diff,
# scope violations. Calls Opus (claude -p) with a structured brief.
# Outputs a refined task spec JSON to stdout (same format as the input spec,
# only the "prompt" field is updated). The caller redirects stdout to a stable
# location — this script writes no run-dir artifact, since dispatch.sh wipes the
# run-dir at the start of the next attempt.
#
# Opus sees ONLY: original spec + test log tail + diff stat + diff body (capped).
# It does NOT see the executor's report — that's untrusted by design.
#
# Env:
#   CLAUDE_CMD     — Opus binary (default: claude). Point at the mock to test at zero quota.
#   ITERATE_MODEL  — claude model to use (default: claude-opus-4-8)
#   DIFF_MAX_LINES — max lines of diff to show Opus (default: 120)
#   LOG_MAX_LINES  — max tail lines of test log (default: 40)
#
set -uo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HARNESS_DIR/lib"
RUN_DIR="${1:?usage: iterate.sh <run-dir> <task-spec.json> [iteration]}"
SPEC="${2:?usage: iterate.sh <run-dir> <task-spec.json> [iteration]}"
ITERATION="${3:-0}"   # logical iteration that FAILED (for Opus-window telemetry)

CLAUDE_CMD="${CLAUDE_CMD:-claude}"
ITERATE_MODEL="${ITERATE_MODEL:-claude-opus-4-8}"
DIFF_MAX_LINES="${DIFF_MAX_LINES:-120}"
LOG_MAX_LINES="${LOG_MAX_LINES:-40}"
ITERATE_RETRIES="${ITERATE_RETRIES:-2}"

# Extract a single JSON object from a model reply that may wrap it in prose or
# ```json fences: take everything from the first '{' line to the last '}' line.
extract_json() {
  awk '
    /\{/ && start==0 { start=NR }
    { buf[NR]=$0 }
    /\}/            { end=NR }
    END { if (start>0 && end>=start) for (i=start;i<=end;i++) print buf[i] }
  '
}

GT="$RUN_DIR/ground-truth.json"
TEST_LOG="$RUN_DIR/visible-tests.log"
WORKTREE="$(jq -r .worktree "$RUN_DIR/run.json")"
BASE_SHA="$(jq -r .base_sha "$RUN_DIR/run.json")"

[[ -f "$GT" ]]   || { echo "iterate: ground-truth.json not found" >&2; exit 2; }
[[ -f "$SPEC" ]] || { echo "iterate: task spec not found: $SPEC" >&2; exit 2; }

DIFF_STAT="$(git -C "$WORKTREE" diff --shortstat "$BASE_SHA" 2>/dev/null || echo "(no diff)")"
DIFF_BODY="$(git -C "$WORKTREE" diff "$BASE_SHA" 2>/dev/null | head -n "$DIFF_MAX_LINES")"
TEST_TAIL="$(tail -n "$LOG_MAX_LINES" "$TEST_LOG" 2>/dev/null || echo "(no test log)")"

# §9.5 leak management: the held-out hint is GENERALIZED. We never include heldout.log
# or the held-out assertions in the brief — that would convert held-out into a visible
# test. Only the fact "fails hidden checks; generalize" crosses the boundary.
FAIL_SUMMARY="$(jq -r '
  [ if (.visible_tests.passed | not) then "- tests failed (exit \(.visible_tests.exit_code))" else empty end,
    if ((.scope.out_of_scope_touched|length)>0) then "- scope violation: \(.scope.out_of_scope_touched|join(", "))" else empty end,
    if ((.diff_name_only|length)==0) then "- no files changed" else empty end,
    if (.held_out_checks.ran and (.held_out_checks.passed|not)) then "- passes the visible tests but FAILS hidden held-out checks: the solution likely special-cases the visible inputs instead of being generally correct. Require a general implementation, not one tuned to the shown cases." else empty end
  ] | join("\n")' "$GT")"

ORIG_PROMPT="$(jq -r .prompt "$SPEC")"
TASK_ID="$(jq -r .task_id "$SPEC")"

BRIEF="$(cat <<BRIEF
You are the Opus orchestrator reviewing a failed Composer executor run on task $TASK_ID.

## Original task prompt (what Composer was told)
$ORIG_PROMPT

## Why the run failed
$FAIL_SUMMARY

## What the executor changed (diff stat)
$DIFF_STAT

## Diff body (first $DIFF_MAX_LINES lines)
\`\`\`diff
$DIFF_BODY
\`\`\`

## Test output tail ($LOG_MAX_LINES lines)
\`\`\`
$TEST_TAIL
\`\`\`

## Your job
Write a refined prompt for Composer that is more precise and avoids the failure above.
Rules:
- Focus on the specific failure, not general advice.
- Keep the prompt machine-checkable: what to change, where, and what the acceptance criterion is.
- Do NOT mention the test output or diff in the new prompt (Composer should not see those).
- Output ONLY a JSON object — no markdown, no explanation outside the JSON.

The JSON must have exactly these fields (same values as below, except "prompt" which you rewrite):

### SPEC_SKELETON
$(jq '{task_id,prompt:("(you rewrite this)"),target_repo,base_ref,allowed_scope,heldout_set,class,complexity,spec_clarity}' "$SPEC")
BRIEF
)"

# Call Opus, robustly extract the JSON, validate. Retry on a malformed reply —
# a live model occasionally adds a stray fence or preamble despite instructions.
# Uses --output-format json so we capture the Opus-window `usage` (§3 economics telemetry);
# falls back gracefully if a binary returns plain text.
BRIEF_CHARS=${#BRIEF}
attempt=0
while :; do
  attempt=$((attempt + 1))
  ENVELOPE="$(printf '%s' "$BRIEF" | "$CLAUDE_CMD" -p --output-format json --model "$ITERATE_MODEL" 2>/dev/null)"
  if REPLY_TEXT="$(printf '%s' "$ENVELOPE" | jq -er '.result' 2>/dev/null)"; then
    USAGE="$(printf '%s' "$ENVELOPE" | jq -c '.usage // {}' 2>/dev/null)"
  else
    REPLY_TEXT="$ENVELOPE"; USAGE='{}'
  fi
  JSON="$(printf '%s' "$REPLY_TEXT" | extract_json)"
  if printf '%s' "$JSON" | jq -e 'has("task_id") and has("prompt")' >/dev/null 2>&1; then
    # §3 telemetry: record the Opus-window spend this refinement cost. The usage is a
    # byproduct of the call we already made, so this is zero EXTRA Opus tokens.
    "$LIB/log-opus.sh" "$TASK_ID" "$ITERATION" "$ITERATE_MODEL" "$USAGE" "$BRIEF_CHARS" >/dev/null 2>&1 || true
    printf '%s' "$JSON" | jq '.'
    exit 0
  fi
  if [[ $attempt -gt $ITERATE_RETRIES ]]; then
    echo "iterate: Opus returned no valid spec JSON after $attempt attempts" >&2
    echo "iterate: last raw reply was:" >&2
    printf '%s\n' "$ENVELOPE" | head -20 >&2
    exit 5
  fi
  echo "iterate: malformed reply (attempt $attempt), retrying refinement" >&2
done
