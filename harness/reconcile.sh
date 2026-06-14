#!/usr/bin/env bash
#
# reconcile.sh [state-file]
#
# Session-start reconciliation (§4): a fresh Opus must NOT trust STATE.md's prose
# on its word. It runs the hard checks (git log, tests, file contents, ledger) and
# verifies every machine-checkable claim STATE.md makes about reality. Any claim
# that fails is a DISCREPANCY — the §3 metric "discrepancies at session-start
# reconciliation" must be 0; anything above 0 means the doc drifted from ground
# truth and the prose can no longer be trusted until reconciled.
#
# STATE.md carries a fenced ```json block of claims. Each claim is one of:
#   {"kind":"ledger","task":"T-0002","event":"accept"}          ledger has the event
#   {"kind":"git","repo":".","grep":"Narrow slice"}            git log mentions it
#   {"kind":"file","path":"src/x.py","contains":"foo"}          file contains string
#   {"kind":"test","cwd":".","cmd":"...","expect":"pass"}       cmd exits 0 (or "fail")
#
# Emits state/reconcile.json with {discrepancies, checked, results[]} and exits
# nonzero if any discrepancy is found.
#
set -uo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HARNESS_DIR/.."
STATE_FILE="${1:-$ROOT/state/STATE.md}"
LEDGER="$ROOT/state/ledger.jsonl"
OUT="$ROOT/state/reconcile.json"

[[ -f "$STATE_FILE" ]] || { echo "reconcile: STATE.md not found: $STATE_FILE" >&2; exit 2; }

# --- pull the fenced json claims block out of the markdown ---
CLAIMS="$(awk '
  /^```json/ { grab=1; next }
  /^```/     { grab=0 }
  grab       { print }
' "$STATE_FILE")"

if ! printf '%s' "$CLAIMS" | jq -e 'type=="array"' >/dev/null 2>&1; then
  echo "reconcile: no valid fenced json claims array in $STATE_FILE" >&2
  exit 2
fi

results='[]'
discrepancies=0
checked=0

add_result() { # ok(bool) claim(json) detail(str)
  results="$(jq -c --argjson ok "$1" --argjson claim "$2" --arg detail "$3" \
    '. + [{ok:$ok, claim:$claim, detail:$detail}]' <<<"$results")"
  checked=$((checked+1))
  [[ "$1" == "true" ]] || discrepancies=$((discrepancies+1))
}

n="$(jq 'length' <<<"$CLAIMS")"
for ((i=0; i<n; i++)); do
  claim="$(jq -c ".[$i]" <<<"$CLAIMS")"
  kind="$(jq -r '.kind' <<<"$claim")"
  case "$kind" in
    ledger)
      task="$(jq -r '.task'  <<<"$claim")"
      event="$(jq -r '.event' <<<"$claim")"
      if [[ -f "$LEDGER" ]] && jq -e --arg t "$task" --arg e "$event" \
           'select(.task_id==$t and .event==$e)' "$LEDGER" >/dev/null 2>&1; then
        add_result true "$claim" "ledger has $event for $task"
      else
        add_result false "$claim" "ledger has NO $event for $task"
      fi
      ;;
    git)
      repo="$(jq -r '.repo' <<<"$claim")"; [[ "$repo" == "." ]] && repo="$ROOT"
      pat="$(jq -r '.grep' <<<"$claim")"
      if git -C "$repo" log --oneline 2>/dev/null | grep -qF -- "$pat"; then
        add_result true "$claim" "git log mentions '$pat'"
      else
        add_result false "$claim" "git log does NOT mention '$pat'"
      fi
      ;;
    file)
      path="$(jq -r '.path' <<<"$claim")"
      [[ "$path" = /* ]] || path="$ROOT/$path"
      sub="$(jq -r '.contains' <<<"$claim")"
      if [[ -f "$path" ]] && grep -qF -- "$sub" "$path"; then
        add_result true "$claim" "file contains '$sub'"
      else
        add_result false "$claim" "file missing or lacks '$sub'"
      fi
      ;;
    test)
      cwd="$(jq -r '.cwd // "."' <<<"$claim")"; [[ "$cwd" == "." ]] && cwd="$ROOT"
      cmd="$(jq -r '.cmd' <<<"$claim")"
      expect="$(jq -r '.expect // "pass"' <<<"$claim")"
      ( cd "$cwd" && eval "$cmd" ) >/dev/null 2>&1; rc=$?
      got="pass"; [[ $rc -ne 0 ]] && got="fail"
      if [[ "$got" == "$expect" ]]; then
        add_result true "$claim" "test $got as expected"
      else
        add_result false "$claim" "test $got, expected $expect"
      fi
      ;;
    *)
      add_result false "$claim" "unknown claim kind '$kind'"
      ;;
  esac
done

mkdir -p "$ROOT/state"
jq -n --argjson d "$discrepancies" --argjson c "$checked" --argjson r "$results" \
  '{discrepancies:$d, checked:$c, results:$r}' | tee "$OUT"

[[ $discrepancies -eq 0 ]] || { echo "reconcile: $discrepancies discrepancy(ies) — STATE.md drifted from ground truth" >&2; exit 1; }
