#!/usr/bin/env bash
#
# §9.5 gate: held-out reserve / leak-management across iterations.
#
# A `reserve` pool is mixed in ONLY at the final gate (phase=final); during the refine
# loop (phase=iterate) it is physically absent. So an overfit that learned the iteration
# `place` pool is still caught on the final artifact:
#
#   overfit  + iterate -> PASS (reserve hidden)   ; reserve_ran=false
#   overfit  + final   -> FAIL (reserve catches)  ; reserve_ran=true
#   correct  + final   -> PASS                     ; reserve_ran=true
#
# Also asserts the §9 invariants: the reserved code never lands in the executor's tree,
# and the verification-checkout is destroyed (no leftovers).
#
# Pure ground-truth: builds throwaway git repos; held-out run via the collector venv.
#
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export HELDOUT_PYTEST="${HELDOUT_PYTEST:-python3 -m pytest}"
SET="T-RESERVE-DEMO"
fail=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OVERFIT="$TMP/overfit.py"; cat > "$OVERFIT" <<'PY'
def f(x):
    table = {1: 10, 2: 20}   # correct only for the visible inputs
    if x in table:
        return table[x]
    return 0                 # general case deliberately wrong
PY
CORRECT="$TMP/correct.py"; cat > "$CORRECT" <<'PY'
def f(x):
    return x * 10
PY

build_run() { # <solution.py> -> echoes run-dir
  local sol="$1" repo rd
  repo="$TMP/repo.$RANDOM.$RANDOM"
  mkdir -p "$repo/src"
  cp "$sol" "$repo/src/calc.py"
  printf '[pytest]\npythonpath = .\n' > "$repo/pytest.ini"
  git -C "$repo" init -q
  git -C "$repo" -c user.name=t -c user.email=t@t add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -qm init
  rd="$TMP/run.$RANDOM.$RANDOM"; mkdir -p "$rd"
  cp -r "$repo" "$rd/worktree"
  jq -n --arg wt "$rd/worktree" --arg set "$SET" \
    '{task_id:"T-RES", worktree:$wt, heldout_set:$set, allowed_scope:["src/**"]}' > "$rd/run.json"
  echo "$rd"
}
ho() { jq -r "$2" "$1/heldout.json"; }

echo "### overfit + iterate: reserve hidden -> PASS"
RD="$(build_run "$OVERFIT")"
"$ROOT/harness/verify-heldout.sh" "$RD" iterate >/dev/null 2>&1
echo "  passed=$(ho "$RD" .passed) reserve_ran=$(ho "$RD" .reserve_ran)"
[[ "$(ho "$RD" .passed)" == "true" && "$(ho "$RD" .reserve_ran)" == "false" ]] \
  || { echo "  -> FAIL"; fail=1; }
[[ -f "$RD/worktree/tests/test_reserve.py" ]] && { echo "  -> LEAK: reserve in worktree!"; fail=1; } \
  || echo "  -> no reserve leak into worktree: OK"

echo "### overfit + final: reserve mixed -> FAIL (overfit caught)"
RD="$(build_run "$OVERFIT")"
"$ROOT/harness/verify-heldout.sh" "$RD" final >/dev/null 2>&1
echo "  passed=$(ho "$RD" .passed) reserve_ran=$(ho "$RD" .reserve_ran)"
[[ "$(ho "$RD" .passed)" == "false" && "$(ho "$RD" .reserve_ran)" == "true" ]] \
  || { echo "  -> FAIL: reserve did not catch the overfit at the final gate"; fail=1; }

echo "### correct + final: reserve mixed -> PASS"
RD="$(build_run "$CORRECT")"
"$ROOT/harness/verify-heldout.sh" "$RD" final >/dev/null 2>&1
echo "  passed=$(ho "$RD" .passed) reserve_ran=$(ho "$RD" .reserve_ran)"
[[ "$(ho "$RD" .passed)" == "true" && "$(ho "$RD" .reserve_ran)" == "true" ]] \
  || { echo "  -> FAIL: a generally correct solution was rejected by reserve"; fail=1; }

leftover="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "vcheck-$SET.*" 2>/dev/null | wc -l)"
echo "### leftover verification-checkouts: $leftover (want 0)"
[[ "$leftover" -eq 0 ]] || { echo "  -> FAIL: verify-checkout not destroyed"; fail=1; }

echo; [[ $fail -eq 0 ]] && echo "HELD-OUT RESERVE (§9.5) GATE: GREEN" || echo "HELD-OUT RESERVE (§9.5) GATE: RED"
exit $fail
