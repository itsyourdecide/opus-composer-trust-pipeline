#!/usr/bin/env bash
#
# verify-heldout.sh <run-dir> [phase]
#
# §9.3 mixing-at-verification flow. Held-out checks live ONLY on the trusted side
# (this repo's heldout/<set>/), never in the executor's worktree — and they are
# mixed in only AFTER the executor session has ended, into a throwaway checkout
# that is destroyed afterwards. So even if sandbox isolation leaked, the held-out
# code was never physically present while the executor was running.
#
#   executor's artifact commit (in runs/<task>/worktree)
#         │  git archive HEAD  → a SEPARATE verification-checkout (tmp dir, no .git)
#         ▼
#   copy held-out from heldout/<set>/ INTO the verification-checkout
#         ▼
#   run held-out checks; capture pass/fail
#         ▼
#   DESTROY the verification-checkout (held-out never persist where a next iteration sees them)
#
# phase (§9.5 leak management):
#   iterate (default) — mix only the `place` pool (the iteration-visible checks). The
#                       `reserve` pool is NEVER copied in here, so it stays physically
#                       absent across the whole refine loop and cannot be learned.
#   final             — mix `place` + `reserve`. Run as the LAST gate just before an accept
#                       lands, so the reserved checks are a clean measurement on the final
#                       artifact (an overfit that learned the iteration pool is still caught).
#
# Emits runs/<task>/heldout.json:
#   {ran, passed, exit_code, set, phase, mixed_files, reserve_ran, store_outside_worktree}.
# If the task configures no held-out set (or the store is missing) -> {ran:false}.
#
# Env:
#   HELDOUT_PYTEST - interpreter for the held-out cmd (default: python3 -m pytest)
#
set -uo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HARNESS_DIR/.."
RUN_DIR="${1:?usage: verify-heldout.sh <run-dir> [phase]}"
PHASE="${2:-iterate}"
RUN_JSON="$RUN_DIR/run.json"
[[ -f "$RUN_JSON" ]] || { echo "verify-heldout: run.json not found in $RUN_DIR" >&2; exit 2; }

WORKTREE="$(jq -r '.worktree' "$RUN_JSON")"
SET="$(jq -r '.heldout_set // ""' "$RUN_JSON")"
OUT="$RUN_DIR/heldout.json"

emit_unran() { # reason
  jq -n --arg r "$1" '{ran:false, reason:$r}' | tee "$OUT"
}

[[ -n "$SET" ]] || { emit_unran "no heldout_set configured for task"; exit 0; }
STORE="$ROOT/heldout/$SET"
MANIFEST="$STORE/manifest.json"
[[ -f "$MANIFEST" ]] || { emit_unran "no held-out store at heldout/$SET"; exit 0; }

# --- §9.2 isolation, defence in depth ---------------------------------------------------
# (1) Lock the trusted store down to owner-only (0700). On a multi-user box this denies a
#     restricted RUN_AS_USER executor any read; against the SAME unprivileged user it is not
#     sufficient by itself (the owner can always read) — that case is closed by the §9.3
#     timing below and, for a hard guarantee, by a container / restricted user at runtime.
chmod 700 "$STORE" 2>/dev/null || true
# (2) Timing/path invariant: the store must live OUTSIDE the executor's worktree, so the
#     held-out code is never physically reachable from inside the executor's tree.
store_real="$(realpath "$STORE" 2>/dev/null || echo "$STORE")"
wt_real="$(realpath "$WORKTREE" 2>/dev/null || echo "$WORKTREE")"
STORE_OUTSIDE=true
case "$store_real/" in "$wt_real/"*) STORE_OUTSIDE=false ;; esac
if [[ "$STORE_OUTSIDE" != "true" ]]; then
  # A held-out store inside the executor's tree is a hard violation, not a soft signal.
  jq -n --arg set "$SET" '{ran:false, reason:"held-out store is INSIDE the executor worktree (isolation violation)", set:$set, store_outside_worktree:false}' | tee "$OUT"
  exit 0
fi

# --- build the throwaway verification-checkout from the executor's committed tree ---
VCHECK="$(mktemp -d "${TMPDIR:-/tmp}/vcheck-$SET.XXXXXX")"
cleanup() { rm -rf "$VCHECK"; }   # held-out must not survive the verify step
trap cleanup EXIT

if ! git -C "$WORKTREE" archive HEAD 2>/dev/null | tar -x -C "$VCHECK" 2>/dev/null; then
  emit_unran "could not archive executor commit (empty tree?)"; exit 0
fi

# --- which pools to mix for this phase (§9.5) ---
# `place` is always mixed. `reserve` is mixed ONLY at the final gate, never during iterate,
# so it is physically absent across the refine loop.
mix_pool() { # <manifest-key> -> count of files copied, echoed
  local key="$1" entry from to n=0
  while IFS= read -r entry; do
    [[ -z "$entry" || "$entry" == "null" ]] && continue
    from="$(jq -r '.from' <<<"$entry")"
    to="$(jq -r '.to'   <<<"$entry")"
    mkdir -p "$VCHECK/$(dirname "$to")"
    cp "$STORE/$from" "$VCHECK/$to"
    n=$((n+1))
  done < <(jq -c --arg k "$key" '(.[$k] // [])[]' "$MANIFEST")
  echo "$n"
}

mixed="$(mix_pool place)"
RESERVE_RAN=false
HAS_RESERVE="$(jq -r '((.reserve // []) | length) > 0' "$MANIFEST")"
if [[ "$PHASE" == "final" && "$HAS_RESERVE" == "true" ]]; then
  r="$(mix_pool reserve)"
  mixed=$((mixed + r))
  RESERVE_RAN=true
fi

# --- run the held-out checks in the isolated checkout ---
HELDOUT_LOG="$RUN_DIR/heldout.log"
CMD="$(jq -r '.cmd' "$MANIFEST")"
( cd "$VCHECK" && eval "$CMD" ) >"$HELDOUT_LOG" 2>&1
rc=$?
# If this is the final gate and a reserve pool exists, the reserved checks must pass too.
if [[ "$RESERVE_RAN" == "true" ]]; then
  RCMD="$(jq -r '.reserve_cmd // .cmd' "$MANIFEST")"
  ( cd "$VCHECK" && eval "$RCMD" ) >>"$HELDOUT_LOG" 2>&1
  rrc=$?
  [[ $rc -eq 0 ]] && rc=$rrc   # fail if EITHER pool fails; keep the first nonzero
fi
[[ $rc -eq 0 ]] && passed=true || passed=false

# verification-checkout is destroyed by the EXIT trap.
jq -n --argjson passed "$passed" --argjson rc "$rc" --arg set "$SET" --arg phase "$PHASE" \
  --argjson mixed "$mixed" --argjson reserve "$RESERVE_RAN" --argjson outside "$STORE_OUTSIDE" \
  '{ran:true, passed:$passed, exit_code:$rc, set:$set, phase:$phase,
    mixed_files:$mixed, reserve_ran:$reserve, store_outside_worktree:$outside}' | tee "$OUT"
