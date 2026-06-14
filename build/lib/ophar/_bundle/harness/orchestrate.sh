#!/usr/bin/env bash
#
# orchestrate.sh <task-spec.json>
#
# The full Opus-orchestrates-Composer loop (Phases 3–5).
#
#   1. dispatch.sh + ground-truth.sh  (via run.sh — handles mechanical retries)
#   2. verdict.sh                     (deterministic: accept / iterate / reject / block)
#   3a. accept  -> ledger + done
#   3b. iterate -> ledger + iterate.sh (Opus refines prompt) -> go to 1 with new spec
#   3c. reject  -> ledger + stop
#   3d. block   -> ledger + stop (infra issue, no usable ground truth)
#
# run.sh handles unreliable-dispatch retries internally (timeout/badjson).
# orchestrate.sh handles logical iterations (Opus refines the spec when
# dispatch was reliable but the code was wrong).
#
# Env:
#   MAX_ITERATIONS  — logical iterations before reject (default 3)
#   RETRIES         — mechanical retries inside run.sh  (default 2)
#   TEST_CMD        — passed through to run.sh / ground-truth.sh
#   CURSOR_AGENT_CMD, TIMEOUT, MODEL — passed through to dispatch.sh
#   HISTORY         — 1 (default) to snapshot per-iteration artifacts under state/history/<task>/iter<N>/
#
set -uo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC="${1:?usage: orchestrate.sh <task-spec.json>}"
MAX_ITERATIONS="${MAX_ITERATIONS:-3}"

[[ -f "$SPEC" ]] || { echo "orchestrate: task spec not found: $SPEC" >&2; exit 2; }
TASK_ID="$(jq -r .task_id "$SPEC")"

# --- per-task verification commands (§6.2): the spec is the source of truth. A task
# carries its own test/typecheck/lint commands; these OVERRIDE the inherited global
# defaults from settings.json (e.g. the FastAPI worker's `npm test --silent`), so a
# Python task is never verified with a Node test runner. Read from the ORIGINAL spec
# once (not the per-iteration refined spec, which may not echo these fields). Absent
# fields leave the inherited env untouched, preserving the global fallback. ---
for pair in test_cmd:TEST_CMD typecheck_cmd:TYPECHECK_CMD lint_cmd:LINT_CMD; do
  spec_key="${pair%%:*}"; env_key="${pair##*:}"
  val="$(jq -r --arg k "$spec_key" '.[$k] // empty' "$SPEC")"
  [[ -n "$val" ]] && export "$env_key=$val"
done

# Refined specs must live OUTSIDE the run-dir: dispatch.sh wipes runs/$TASK_ID
# at the start of every attempt, which would otherwise delete the spec we just
# generated before the next iteration can read it.
SPECS_DIR="$HARNESS_DIR/../state/specs"
mkdir -p "$SPECS_DIR"

HISTORY="${HISTORY:-1}"
HISTORY_DIR="$HARNESS_DIR/../state/history"
if [[ "$HISTORY" == "1" ]]; then mkdir -p "$HISTORY_DIR"; fi

# --- per-iteration snapshot: durable copy of this iteration's artifacts into
# state/history/<task>/iter<N>/ BEFORE the next dispatch wipes runs/<task>.
# MUST fire AFTER the reserve-held-out block (which mutates heldout.json post-verdict)
# and BEFORE any terminal exit so the final iteration is captured. ---
snapshot_iteration() {
  [[ "$HISTORY" == "1" ]] || return 0
  local rd="$1" iter="$2"
  local dest="$HISTORY_DIR/$TASK_ID/iter$iter"
  mkdir -p "$dest"
  for artefact in run.json dispatch.json ground-truth.json heldout.json report.json \
                   visible-tests.log typecheck.log lint.log executor.log; do
    [[ -f "$rd/$artefact" ]] && cp "$rd/$artefact" "$dest/" 2>/dev/null || true
  done
  # git diff from base to the artifact commit (what the executor actually changed).
  local base target_repo
  base="$(jq -r '.base_sha // "HEAD"' "$rd/run.json" 2>/dev/null)"
  target_repo="$(jq -r '.target_repo // ""' "$rd/run.json" 2>/dev/null)"
  if [[ -n "$target_repo" && -n "$base" ]]; then
    git -C "$target_repo" diff "$base..$(git -C "$rd/worktree" rev-parse HEAD 2>/dev/null)" 2>/dev/null > "$dest/diff.patch" || true
  fi
}

# --- terminal cleanup: remove the throwaway linked worktree + the per-task scratch
# branch orch/<task>. Safe ONLY at terminal verdicts (accept/reject/block), never on
# iterate (the next dispatch reuses the worktree). The accepted artifact survives:
# land.sh has already pointed the durable orch/accepted/<task> branch at the commit,
# and the commit lives in the target repo's object store independent of the worktree.
# The runs/<task>/ artifacts (ground-truth.json, land.json, logs) are KEPT for audit;
# only the worktree subdir and scratch branch are reclaimed. ---
cleanup_run_worktree() {
  local rd="$1"
  local target_repo worktree
  target_repo="$(jq -r '.target_repo // ""' "$rd/run.json" 2>/dev/null)"
  worktree="$(jq -r '.worktree // ""' "$rd/run.json" 2>/dev/null)"
  [[ -n "$target_repo" ]] || return 0
  if [[ -n "$worktree" ]]; then
    git -C "$target_repo" worktree remove --force "$worktree" 2>/dev/null \
      || rm -rf "$worktree" 2>/dev/null || true
  fi
  git -C "$target_repo" worktree prune 2>/dev/null || true
  git -C "$target_repo" branch -D "orch/$TASK_ID" >/dev/null 2>&1 || true
}

echo "========================================================"
echo "  ORCHESTRATE  $TASK_ID  (max_iterations=$MAX_ITERATIONS)"
echo "========================================================"

"$HARNESS_DIR/ledger.sh" open "$TASK_ID" "$(jq -c '{spec_file:"'"$SPEC"'"}' "$SPEC" 2>/dev/null || echo '{}')"

iteration=0
CURRENT_SPEC="$SPEC"

while :; do
  iteration=$((iteration + 1))
  echo ""
  echo "-------- iteration $iteration / $MAX_ITERATIONS --------"

  # --- mechanical dispatch + ground-truth (run.sh handles timeout/badjson retries) ---
  RUNS_DIR="$HARNESS_DIR/../runs"
  "$HARNESS_DIR/run.sh" "$CURRENT_SPEC"
  RUN_DIR="$(cat "$RUNS_DIR/.last-run-dir" 2>/dev/null)"
  [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]] || { echo "orchestrate: could not locate run dir" >&2; exit 2; }

  "$HARNESS_DIR/ledger.sh" dispatch "$TASK_ID" \
    "$(jq -cn --arg rd "$RUN_DIR" --argjson i "$iteration" '{run_dir:$rd, iteration:$i}')"

  # --- deterministic verdict (reject threshold keyed to logical iteration) ---
  VERDICT_JSON="$("$HARNESS_DIR/verdict.sh" "$RUN_DIR" "$MAX_ITERATIONS" "$iteration")"
  VERDICT="$(echo "$VERDICT_JSON" | jq -r .verdict)"
  REASON="$(echo  "$VERDICT_JSON" | jq -r .reason)"

  # --- §9.5 reserved held-out as the FINAL gate. The verdict above used the iteration
  # held-out pool (the only one mixed during the loop). Before an accept actually LANDS,
  # re-verify with the RESERVED pool (never shown across iterations): an overfit that
  # learned the iteration checks is still caught here on the final artifact. Only runs
  # when the task ships a reserve pool; a no-reserve task is unaffected. ---
  if [[ "$VERDICT" == "accept" ]]; then
    "$HARNESS_DIR/verify-heldout.sh" "$RUN_DIR" final >/dev/null 2>&1 || true
    if [[ "$(jq -r '.reserve_ran // false' "$RUN_DIR/heldout.json" 2>/dev/null)" == "true" \
          && "$(jq -r '.passed // true'    "$RUN_DIR/heldout.json" 2>/dev/null)" == "false" ]]; then
      if [[ $iteration -lt $MAX_ITERATIONS ]]; then VERDICT="iterate"; else VERDICT="reject"; fi
      # §9.5: hint stays GENERALIZED — never name the reserved assertion.
      REASON="passes the iteration held-out pool but fails the RESERVED final checks — solution overfits; require general correctness"
      echo ">>> FINAL HELD-OUT (reserve) caught an overfit on the final artifact — downgrading accept -> $VERDICT"
    fi
  fi

  # --- durable snapshot of this iteration (AFTER reserve-held-out may have
  # mutated heldout.json / verdict) — terminal branches land/exit below, iterate
  # branch will be wiped by the next dispatch. ---
  snapshot_iteration "$RUN_DIR" "$iteration"

  echo ""
  echo ">>> VERDICT: $VERDICT — $REASON"

  case "$VERDICT" in
    accept)
      # held-out already passed (work_ok) → safe to deliver. Land onto a durable
      # branch; do NOT merge to base/main (that stays a human/Opus decision).
      LAND_JSON="$("$HARNESS_DIR/land.sh" "$RUN_DIR" 2>/dev/null)"
      RESULT_BRANCH="$(echo "$LAND_JSON" | jq -r '.result_branch // "?"')"
      LANDED_SHA="$(echo "$LAND_JSON" | jq -r '.sha // "?"' | cut -c1-12)"
      "$HARNESS_DIR/ledger.sh" accept "$TASK_ID" \
        "$(jq -cn --arg rd "$RUN_DIR" --argjson i "$iteration" --arg b "$RESULT_BRANCH" --arg s "$LANDED_SHA" \
           '{run_dir:$rd, iteration:$i, result_branch:$b, landed_sha:$s}')"
      echo ""
      echo "========================================================"
      echo "  ACCEPTED  $TASK_ID  after $iteration iteration(s)"
      echo "  landed -> $RESULT_BRANCH @ $LANDED_SHA  (in target repo; not merged to base)"
      echo "  run_dir=$RUN_DIR"
      echo "========================================================"
      cleanup_run_worktree "$RUN_DIR"
      exit 0
      ;;

    iterate)
      "$HARNESS_DIR/ledger.sh" iterate "$TASK_ID" \
        "$(jq -cn --arg rd "$RUN_DIR" --arg r "$REASON" --argjson i "$iteration" \
           '{run_dir:$rd, reason:$r, iteration:$i}')"

      echo ""
      echo "--- Opus refining spec (iteration $iteration → $((iteration+1))) ---"
      REFINED="$SPECS_DIR/${TASK_ID}-iter$((iteration+1)).json"
      # capture iterate.sh stdout to a stable location (the run-dir copy gets wiped next dispatch)
      "$HARNESS_DIR/iterate.sh" "$RUN_DIR" "$CURRENT_SPEC" "$iteration" > "$REFINED" 2>/dev/null
      if ! jq -e . "$REFINED" >/dev/null 2>&1; then
        echo "orchestrate: iterate.sh produced no valid refined spec (Opus output unparseable)" >&2
        rm -f "$REFINED"
        break
      fi
      CURRENT_SPEC="$REFINED"
      echo "refined spec -> $CURRENT_SPEC"
      ;;

    reject)
      "$HARNESS_DIR/ledger.sh" reject "$TASK_ID" \
        "$(jq -cn --arg rd "$RUN_DIR" --arg r "$REASON" --argjson i "$iteration" \
           '{run_dir:$rd, reason:$r, iteration:$i}')"
      echo ""
      echo "========================================================"
      echo "  REJECTED  $TASK_ID  after $iteration iteration(s): $REASON"
      echo "========================================================"
      cleanup_run_worktree "$RUN_DIR"
      exit 1
      ;;

    block)
      "$HARNESS_DIR/ledger.sh" block "$TASK_ID" \
        "$(jq -cn --arg rd "$RUN_DIR" --arg r "$REASON" '{run_dir:$rd, reason:$r}')"
      echo ""
      echo "========================================================"
      echo "  BLOCKED  $TASK_ID : $REASON"
      echo "  Infra issue — investigate dispatch reliability."
      echo "========================================================"
      cleanup_run_worktree "$RUN_DIR"
      exit 2
      ;;

    *)
      echo "orchestrate: unknown verdict '$VERDICT'" >&2
      exit 3
      ;;
  esac
done

echo "orchestrate: exited loop without terminal verdict" >&2
exit 3
