#!/usr/bin/env bash
#
# Phase 4 gate (§4): session-start reconciliation catches STATE.md drift.
#
#   (a) honest claims  -> 0 discrepancies, exit 0   (prose backed by ground truth)
#   (b) drifted claims -> >=1 discrepancy, exit 1   ("feature done" that isn't)
#
# Pure ground-truth checks (git/file/ledger) — no model calls, zero quota.
#
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

# --- (a) honest STATE.md: claims that are actually true right now ---
cat > "$TMP/STATE-honest.md" <<'MD'
# STATE (honest fixture)
## Machine-checked claims
```json
[
  {"kind":"file","path":"harness/reconcile.sh","contains":"discrepancies"},
  {"kind":"file","path":"harness/verdict.sh","contains":"block"},
  {"kind":"git","repo":".","grep":"Narrow slice"}
]
```
MD

echo "### honest STATE.md -> expect 0 discrepancies"
out="$(bash "$ROOT/harness/reconcile.sh" "$TMP/STATE-honest.md" 2>/dev/null)"; rc=$?
d="$(jq -r .discrepancies <<<"$out")"
echo "  discrepancies=$d exit=$rc"
[[ "$d" == "0" && $rc -eq 0 ]] || { echo "  -> FAIL (honest claims flagged)"; fail=1; }

# --- (b) drifted STATE.md: a "done" claim that ground truth contradicts ---
cat > "$TMP/STATE-drift.md" <<'MD'
# STATE (drifted fixture)
## Machine-checked claims
```json
[
  {"kind":"file","path":"harness/verdict.sh","contains":"block"},
  {"kind":"file","path":"harness/reconcile.sh","contains":"THIS_STRING_IS_NOT_IN_THE_FILE"},
  {"kind":"ledger","task":"T-DOES-NOT-EXIST","event":"accept"}
]
```
MD

echo "### drifted STATE.md -> expect >=1 discrepancy, exit 1"
out="$(bash "$ROOT/harness/reconcile.sh" "$TMP/STATE-drift.md" 2>/dev/null)"; rc=$?
d="$(jq -r .discrepancies <<<"$out")"
echo "  discrepancies=$d exit=$rc"
echo "  caught: $(jq -c '[.results[]|select(.ok==false)|.detail]' <<<"$out")"
[[ "$d" -ge 1 && $rc -ne 0 ]] || { echo "  -> FAIL (drift NOT caught)"; fail=1; }

echo; [[ $fail -eq 0 ]] && echo "PHASE 4 RECONCILE GATE: GREEN" || echo "PHASE 4 RECONCILE GATE: RED"
exit $fail
