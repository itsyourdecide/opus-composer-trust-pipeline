#!/usr/bin/env bash
#
# dispatch.sh <task-spec.json>
#
# Phase 1 + 2 glue. Creates an isolated git worktree of the target repo, runs the
# executor (cursor-agent, or the mock) HEADLESS with a hard timeout, and captures
# its stdout as the UNTRUSTED §6.1 report. It does NOT decide anything and does NOT
# trust the report — verification is ground-truth.sh's job.
#
# Task spec fields:
#   task_id        - id used for the run dir and branch
#   prompt         - the spec handed to the executor
#   target_repo    - path to the git repo being worked on
#   base_ref       - ref to branch the worktree from (default HEAD)
#   allowed_scope  - (read by ground-truth.sh, carried through here)
#
# Env knobs:
#   CURSOR_AGENT_CMD - executor binary (default: cursor-agent). Point at the mock to test.
#   TIMEOUT          - seconds before the executor is killed (default 120)
#   RUNS_DIR         - where run artifacts go (default <harness>/runs)
#   SANDBOX          - executor sandbox mode: enabled|disabled (default disabled). The
#                      cursor-agent sandbox is the preferred STRUCTURAL guard (Phase 5 / §5),
#                      but it cannot start on this host (AppArmor: "Sandbox failed to start"),
#                      which makes the executor exit before editing (dispatch -> invalid_json).
#                      We therefore default to allowlist mode here; the harness still confines
#                      the executor via an isolated git worktree + post-hoc ENFORCE_SCOPE guard,
#                      so out-of-scope/out-of-repo writes are still caught structurally.
#                      Set SANDBOX=enabled on hosts where the cursor sandbox works.
#   INJECT_AGENTS    - 1 to drop the repo's AGENTS.md into the worktree for the executor to
#                      read (removed before the artifact snapshot, so it never pollutes
#                      diff/scope/land). Default 1. Skipped if the worktree already has one.
#   ENFORCE_SCOPE    - 1 (default) to PREVENT out-of-scope writes structurally, not just
#                      detect them post-hoc (Phase 5/§5). Before the executor runs, the
#                      worktree is made read-only EXCEPT for the allowed_scope roots, so an
#                      out-of-scope write fails at the filesystem level. Released right after
#                      the executor exits (ground truth + land run normally). Set 0 to fall
#                      back to detect-only (ground-truth.sh still flags violations either way).
#   RUN_AS_USER      - optional unprivileged OS user to run the executor as, via `sudo -u`
#                      (the lightweight §9.2 isolation: a separate user with no read access to
#                      the trusted held-out store). Empty (default) = run as the current user.
#
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HARNESS_DIR/.." && pwd)"
SPEC="${1:?usage: dispatch.sh <task-spec.json>}"
[[ -f "$SPEC" ]] || { echo "dispatch: spec not found: $SPEC" >&2; exit 2; }

TASK_ID="$(jq -r '.task_id' "$SPEC")"
PROMPT="$(jq -r '.prompt' "$SPEC")"
TARGET_REPO="$(jq -r '.target_repo' "$SPEC")"
BASE_REF="$(jq -r '.base_ref // "HEAD"' "$SPEC")"

# A relative target_repo is resolved against the harness root, so committed fixtures
# (target_repo: "sandbox-py") are portable across clones. Absolute paths — what the MCP
# orchestrator always sends — are used verbatim.
case "$TARGET_REPO" in
  /*) ;;
  *)  TARGET_REPO="$ROOT/$TARGET_REPO" ;;
esac

CURSOR_AGENT_CMD="${CURSOR_AGENT_CMD:-cursor-agent}"
# Pin the EXACT model id. The bare alias "composer" is ambiguous and Cursor's listed
# default is composer-2.5-fast — NOT what the plan targets. Use the full variant unless
# explicitly overridden. (`cursor-agent --list-models` shows the valid ids.)
MODEL="${MODEL:-composer-2.5}"
TIMEOUT="${TIMEOUT:-120}"
RUNS_DIR="${RUNS_DIR:-$HARNESS_DIR/../runs}"
SANDBOX="${SANDBOX:-disabled}"
INJECT_AGENTS="${INJECT_AGENTS:-1}"
ENFORCE_SCOPE="${ENFORCE_SCOPE:-1}"
RUN_AS_USER="${RUN_AS_USER:-}"

RUN_DIR="$RUNS_DIR/$TASK_ID"
WORKTREE="$RUN_DIR/worktree"
BRANCH="orch/$TASK_ID"

rm -rf "$RUN_DIR" 2>/dev/null || { chmod -R u+w "$RUN_DIR" 2>/dev/null || true; rm -rf "$RUN_DIR"; }
mkdir -p "$RUN_DIR"

# Resolve the base to a concrete sha now, so ground truth diffs against a fixed point.
BASE_SHA="$(git -C "$TARGET_REPO" rev-parse "$BASE_REF")"

# Isolation: linked worktree on a fresh branch. The executor never touches the
# user's working copy. (`-f` so re-runs of a stale branch don't wedge us.)
git -C "$TARGET_REPO" worktree prune
git -C "$TARGET_REPO" branch -D "$BRANCH" >/dev/null 2>&1 || true
git -C "$TARGET_REPO" worktree add -f -B "$BRANCH" "$WORKTREE" "$BASE_SHA" >/dev/null

# Carry run metadata for the next stage, including the a-priori [балл Opus] fields
# (class / complexity / spec_clarity). These are LOCKED here at dispatch — §3 anti-
# circularity: they must not be edited after the outcome is known.
jq -n --arg task_id "$TASK_ID" --arg base_sha "$BASE_SHA" \
      --arg worktree "$WORKTREE" --arg target "$TARGET_REPO" --arg model "$MODEL" \
      --argjson scope "$(jq '.allowed_scope // []' "$SPEC")" \
      --arg class "$(jq -r '.class // "unclassified"' "$SPEC")" \
      --argjson complexity "$(jq '.complexity // null' "$SPEC")" \
      --argjson spec_clarity "$(jq '.spec_clarity // null' "$SPEC")" \
      --arg heldout_set "$(jq -r '.heldout_set // ""' "$SPEC")" \
  '{task_id:$task_id, base_sha:$base_sha, worktree:$worktree, target_repo:$target,
    model:$model, allowed_scope:$scope, heldout_set:$heldout_set,
    a_priori:{class:$class, complexity:$complexity, spec_clarity:$spec_clarity}}' \
  > "$RUN_DIR/run.json"

# --- Inject executor guardrails (Phase 5): the repo's AGENTS.md is dropped into the
# worktree so the executor reads its boundaries, then REMOVED before the artifact snapshot
# so it never shows up in the diff / scope / landed branch. Skipped if the target repo
# already ships its own AGENTS.md (don't clobber a real project's rules). ---
AGENTS_INJECTED=0
if [[ "$INJECT_AGENTS" == "1" && -f "$ROOT/AGENTS.md" && ! -e "$WORKTREE/AGENTS.md" ]]; then
  cp "$ROOT/AGENTS.md" "$WORKTREE/AGENTS.md"
  AGENTS_INJECTED=1
fi

# --- Structural scope guard (Phase 5/§5): PREVENT out-of-scope writes, don't just detect
# them. Make the whole worktree read-only except the allowed_scope roots, so a write outside
# scope FAILS at the filesystem layer instead of being caught after the fact by ground truth.
# Released the instant the executor exits, so the artifact snapshot + ground truth + land run
# against a normal tree. `.git` is never touched (the executor must still be able to commit).
# Detection in ground-truth.sh stays as a second line of defence if this is bypassed. ---
SCOPE_LOCKED=0
scope_lock() {
  [[ "$ENFORCE_SCOPE" == "1" ]] || return 0
  local n; n="$(jq '.allowed_scope | length' "$RUN_DIR/run.json" 2>/dev/null || echo 0)"
  [[ "$n" -gt 0 ]] || return 0          # no scope declared -> nothing to confine
  # Lock everything except the git metadata pointer.
  find "$WORKTREE" -path "$WORKTREE/.git" -prune -o -print0 2>/dev/null \
    | xargs -0 -r chmod a-w 2>/dev/null || true
  # Re-open just the allowed roots (the dir prefix before the first glob wildcard).
  local glob root
  while IFS= read -r glob; do
    [[ -z "$glob" ]] && continue
    root="${glob%%[*?[]*}"; root="${root%/}"   # strip from first * ? or [
    [[ -z "$root" ]] && continue               # a bare "**" would unlock everything; skip
    [[ -e "$WORKTREE/$root" ]] && chmod -R u+w "$WORKTREE/$root" 2>/dev/null || true
  done < <(jq -r '.allowed_scope[]' "$RUN_DIR/run.json" 2>/dev/null)
  SCOPE_LOCKED=1
}
scope_release() {
  [[ "$SCOPE_LOCKED" == "1" ]] || return 0
  find "$WORKTREE" -path "$WORKTREE/.git" -prune -o -print0 2>/dev/null \
    | xargs -0 -r chmod u+w 2>/dev/null || true
  SCOPE_LOCKED=0
}

# --- Run the executor headless, with a hard timeout (known headless hang bug). ---
# Flags mirror the real cursor-agent invocation; the mock ignores all but the prompt.
# --sandbox is the structural permission guard; --force only suppresses interactive prompts.
# Optionally drop to an unprivileged user (RUN_AS_USER) for §9.2 OS-level isolation.
RUNNER=( "$CURSOR_AGENT_CMD" -p --force --sandbox "$SANDBOX" --model "$MODEL" --output-format json "$PROMPT" )
[[ -n "$RUN_AS_USER" ]] && RUNNER=( sudo -n -u "$RUN_AS_USER" "${RUNNER[@]}" )

trap 'scope_release' EXIT INT TERM   # cancel-safe: release read-only lock even on kill
scope_lock   # confine writes to allowed_scope for the duration of the executor session
START=$(date +%s)
set +e
timeout -k 5 "$TIMEOUT" \
  env -C "$WORKTREE" TASK_ID="$TASK_ID" \
  "${RUNNER[@]}" \
  >"$RUN_DIR/report.raw" 2>"$RUN_DIR/executor.log"
EXEC_RC=$?
set -e
END=$(date +%s)
scope_release   # back to a normal tree before snapshot / ground truth / land

# Remove the injected guardrails BEFORE snapshotting, so AGENTS.md is invisible to ground
# truth (diff/scope) and never lands. (Only if we created it.)
[[ "$AGENTS_INJECTED" == "1" ]] && rm -f "$WORKTREE/AGENTS.md"

# Real executors (unlike the mock) often leave changes uncommitted. Snapshot whatever
# the executor produced as a real artifact commit, so there's a stable SHA to verify
# and ground truth diffs against committed state, not a dirty tree.
if [[ -n "$(git -C "$WORKTREE" status --porcelain)" ]]; then
  git -C "$WORKTREE" add -A
  git -C "$WORKTREE" -c user.name="orchestrator" -c user.email="orch@local" \
    commit -q -m "executor artifact: $TASK_ID"
fi

# Classify the run for the reliability metrics (§3): timeout vs bad-json vs ok.
if [[ $EXEC_RC -eq 124 || $EXEC_RC -eq 137 ]]; then
  DISPATCH_STATUS="timeout"
elif jq -e . "$RUN_DIR/report.raw" >/dev/null 2>&1; then
  DISPATCH_STATUS="ok"
  cp "$RUN_DIR/report.raw" "$RUN_DIR/report.json"
else
  DISPATCH_STATUS="invalid_json"
fi

jq -n --arg status "$DISPATCH_STATUS" --argjson rc "$EXEC_RC" \
      --argjson secs "$((END - START))" --argjson timeout "$TIMEOUT" \
  '{dispatch_status:$status, executor_rc:$rc, wall_clock_s:$secs, timeout_s:$timeout}' \
  > "$RUN_DIR/dispatch.json"

echo "$RUN_DIR"
