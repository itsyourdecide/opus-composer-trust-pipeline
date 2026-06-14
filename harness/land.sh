#!/usr/bin/env bash
#
# land.sh <run-dir>
#
# Deliver an ACCEPTED result (§6.4 accept path). Until now an accept left the fix in
# a worktree that the next dispatch wipes — the loop did real work but delivered
# nothing. land.sh makes the accepted artifact durable WITHOUT touching the user's
# main line: it points a dedicated branch `orch/accepted/<task>` in the target repo
# at the accepted commit. Merging that to base/main is a human/Opus decision, not
# something the glue does unprompted (an accept is an internal gate, a merge is
# outward-facing).
#
# Only ever called on an accept verdict (held-out already passed → not a reward-hack).
#
# Emits runs/<task>/land.json: {landed, result_branch, sha, target_repo, base_sha}.
#
set -uo pipefail
RUN_DIR="${1:?usage: land.sh <run-dir>}"
RUN_JSON="$RUN_DIR/run.json"
[[ -f "$RUN_JSON" ]] || { echo "land: run.json not found in $RUN_DIR" >&2; exit 2; }

TARGET_REPO="$(jq -r '.target_repo' "$RUN_JSON")"
TASK_ID="$(jq -r '.task_id' "$RUN_JSON")"
WORKTREE="$(jq -r '.worktree' "$RUN_JSON")"
BASE_SHA="$(jq -r '.base_sha' "$RUN_JSON")"
RESULT_BRANCH="orch/accepted/$TASK_ID"

# The accepted commit. Prefer ground truth's recorded sha; fall back to the worktree HEAD.
ARTIFACT_SHA="$(jq -r '.actual_commit_sha // empty' "$RUN_DIR/ground-truth.json" 2>/dev/null)"
[[ -n "$ARTIFACT_SHA" ]] || ARTIFACT_SHA="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null)"
[[ -n "$ARTIFACT_SHA" ]] || { echo "land: could not resolve accepted commit sha" >&2; exit 2; }

# Point the durable result branch at the accepted commit. The commit already lives in
# the target repo's object store (the worktree is linked), so the ref resolves even
# after the worktree is gone. `branch -f` survives the next dispatch's `branch -D orch/<task>`
# because the result branch has a different name.
git -C "$TARGET_REPO" branch -f "$RESULT_BRANCH" "$ARTIFACT_SHA" >/dev/null 2>&1 \
  || { echo "land: failed to create result branch $RESULT_BRANCH" >&2; exit 2; }

jq -n \
  --argjson landed true \
  --arg branch "$RESULT_BRANCH" \
  --arg sha "$ARTIFACT_SHA" \
  --arg target "$TARGET_REPO" \
  --arg base "$BASE_SHA" \
  '{landed:$landed, result_branch:$branch, sha:$sha, target_repo:$target, base_sha:$base}' \
  | tee "$RUN_DIR/land.json"
