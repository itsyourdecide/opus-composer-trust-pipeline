#!/usr/bin/env bash
#
# ground-truth.sh <run-dir>
#
# The TRUSTED half of the boundary (§6.2). Reads nothing from the executor's report
# except as something to compare against. Re-derives reality independently inside the
# worktree: what actually changed, whether tests actually pass, and whether the
# executor stayed inside its allowed scope. Emits the ground-truth bundle.
#
# Held-out checks are deferred (narrow slice) -> held_out_checks.ran = false.
#
# Env knobs:
#   TEST_CMD      - command to run the visible test suite (default: npm test --silent)
#   TYPECHECK_CMD - optional typechecker (e.g. "mypy src", "tsc --noEmit"). Unset -> not run.
#   LINT_CMD      - optional linter      (e.g. "ruff check src").             Unset -> not run.
# TYPECHECK_CMD / LINT_CMD complete the §6.2 trusted bundle. They are part of ground truth:
# when set they become real acceptance gates (work_ok requires them green); when unset the
# bundle reports {ran:false} and they do not affect the verdict (back-compat / mock gates).
#
set -uo pipefail

RUN_DIR="${1:?usage: ground-truth.sh <run-dir>}"
RUN_JSON="$RUN_DIR/run.json"
[[ -f "$RUN_JSON" ]] || { echo "ground-truth: run.json not found in $RUN_DIR" >&2; exit 2; }

TASK_ID="$(jq -r '.task_id' "$RUN_JSON")"
BASE_SHA="$(jq -r '.base_sha' "$RUN_JSON")"
WORKTREE="$(jq -r '.worktree' "$RUN_JSON")"
ALLOWED_SCOPE="$(jq -c '.allowed_scope' "$RUN_JSON")"
TEST_CMD="${TEST_CMD:-npm test --silent}"

# --- What actually changed (committed + uncommitted) vs the fixed base. ---
ACTUAL_SHA="$(git -C "$WORKTREE" rev-parse HEAD)"
DIFF_STAT="$(git -C "$WORKTREE" diff --shortstat "$BASE_SHA" | sed 's/^ *//')"
mapfile -t CHANGED < <(git -C "$WORKTREE" diff --name-only "$BASE_SHA")
DIFF_NAMES_JSON="$(printf '%s\n' "${CHANGED[@]}" | jq -R . | jq -s 'map(select(length>0))')"

# --- Did the visible tests actually pass? (boolean + tail; counts are runner-specific) ---
TEST_LOG="$RUN_DIR/visible-tests.log"
set +e
( cd "$WORKTREE" && eval "$TEST_CMD" ) >"$TEST_LOG" 2>&1
TEST_RC=$?
set -e
[[ $TEST_RC -eq 0 ]] && TEST_PASSED=true || TEST_PASSED=false

# --- Optional typecheck / lint (§6.2). Run independently in the worktree; only when
# configured. An unset knob -> {ran:false}, which is neutral for the verdict. ---
run_optional_check() { # <env-cmd> <log-path> -> echoes a json {ran,passed,exit_code}
  local cmd="$1" log="$2"
  if [[ -z "$cmd" ]]; then
    echo '{"ran":false}'
    return
  fi
  set +e
  ( cd "$WORKTREE" && eval "$cmd" ) >"$log" 2>&1
  local rc=$?
  set -e
  local passed=true; [[ $rc -eq 0 ]] || passed=false
  jq -n --argjson passed "$passed" --argjson rc "$rc" '{ran:true, passed:$passed, exit_code:$rc}'
}
TYPECHECK_JSON="$(run_optional_check "${TYPECHECK_CMD:-}" "$RUN_DIR/typecheck.log")"
LINT_JSON="$(run_optional_check "${LINT_CMD:-}" "$RUN_DIR/lint.log")"

# --- Scope: which changed files fall outside the allowed globs (§6.2 scope). ---
glob_to_regex() {
  # ** -> .*  ;  * -> [^/]*  ; escape literal dots. Pure bash to avoid sed delimiter clashes.
  local g="$1"
  g="${g//./\\.}"          # escape dots
  g="${g//\*\*/$'\x01'}"   # stash ** as a placeholder
  g="${g//\*/[^/]*}"       # single * -> one path segment
  g="${g//$'\x01'/.*}"     # ** -> anything
  printf '%s' "$g"
}
OUT_OF_SCOPE=()
for f in "${CHANGED[@]}"; do
  [[ -z "$f" ]] && continue
  matched=false
  while IFS= read -r glob; do
    [[ -z "$glob" ]] && continue
    re="^$(glob_to_regex "$glob")$"
    if grep -qE "$re" <<<"$f"; then matched=true; break; fi
  done < <(jq -r '.[]' <<<"$ALLOWED_SCOPE")
  $matched || OUT_OF_SCOPE+=("$f")
done
OUT_OF_SCOPE_JSON="$(printf '%s\n' "${OUT_OF_SCOPE[@]}" | jq -R . | jq -s 'map(select(length>0))')"

# --- Held-out checks (§9): mix-at-verification in a throwaway checkout, then destroy.
# Done HERE so the §6.2 bundle carries held_out_checks alongside visible_tests. The
# executor never sees these — they live trusted-side and run after its session ended. ---
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$HARNESS_DIR/verify-heldout.sh" "$RUN_DIR" >/dev/null 2>&1 || true
if [[ -f "$RUN_DIR/heldout.json" ]]; then
  HELD_OUT_JSON="$(cat "$RUN_DIR/heldout.json")"
else
  HELD_OUT_JSON='{"ran":false}'
fi

# --- Emit the trusted bundle (§6.2). ---
jq -n \
  --arg task_id "$TASK_ID" \
  --arg actual_sha "$ACTUAL_SHA" \
  --argjson diff_names "$DIFF_NAMES_JSON" \
  --arg diff_stat "${DIFF_STAT:-no changes}" \
  --argjson tests_passed "$TEST_PASSED" \
  --argjson test_rc "$TEST_RC" \
  --argjson typecheck "$TYPECHECK_JSON" \
  --argjson lint "$LINT_JSON" \
  --argjson allowed "$ALLOWED_SCOPE" \
  --argjson oos "$OUT_OF_SCOPE_JSON" \
  --argjson held_out "$HELD_OUT_JSON" \
  '{
     task_id: $task_id,
     actual_commit_sha: $actual_sha,
     diff_name_only: $diff_names,
     diff_stat: $diff_stat,
     visible_tests: { ran: true, passed: $tests_passed, exit_code: $test_rc },
     typecheck: $typecheck,
     lint: $lint,
     held_out_checks: $held_out,
     scope: { allowed: $allowed, out_of_scope_touched: $oos }
   }' | tee "$RUN_DIR/ground-truth.json"
