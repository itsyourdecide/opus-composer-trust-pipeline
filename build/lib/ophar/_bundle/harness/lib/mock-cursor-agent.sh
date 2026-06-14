#!/usr/bin/env bash
#
# Stand-in for `cursor-agent -p --model composer-2.5 --output-format json "<prompt>"`.
# Emits the SAME JSON shape the real binary does, so the adapter / metrics / verdict path
# is exercised at zero quota:
#   {type, subtype, is_error, duration_ms, result, session_id, request_id,
#    usage:{inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens}}
#
# Runs with CWD = the worktree. Behavior via MOCK_MODE (a stub can't infer intent):
#   honest  - fix the multiply() bug in src/math.js, report success
#   cheat   - comment out the failing assertion in test/ (out of scope!), report success
#   blocked - touch nothing, report success-with-narrative "couldn't proceed"
#   error   - touch nothing, report is_error:true
#   noop    - report success but change nothing
#   hang    - sleep forever (exercises the dispatch timeout)
#   badjson - print non-JSON garbage (exercises contract validation)
#   flaky   - fail (no change) on the 1st call, fix on the 2nd+ — exercises iterate->accept.
#             State lives at $MOCK_STATE_FILE (default /tmp/mock-flaky-count); the
#             test harness deletes it to reset.
#   overfit_then_fix - overfit to the visible inputs on the 1st call (visible PASS, held-out
#             FAIL), generalise on the 2nd+ — exercises the §9 HELD-OUT-driven iterate->accept.
#
set -uo pipefail
MODE="${MOCK_MODE:-honest}"

uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "mock-$RANDOM-$RANDOM"; }

emit() { # is_error subtype result_text  [in out cacheR cacheW]
  local in="${5:-1200}" out="${6:-180}" cr="${7:-8000}" cw="${8:-0}"
  jq -cn \
    --argjson is_error "$1" --arg subtype "$2" --arg result "$3" \
    --arg sid "$(uuid)" --arg rid "$(uuid)" --argjson dur "$(( (RANDOM % 9000) + 800 ))" \
    --argjson in "$in" --argjson out "$out" --argjson cr "$cr" --argjson cw "$cw" \
    '{type:"result", subtype:$subtype, is_error:$is_error, duration_ms:$dur,
      duration_api_ms:$dur, result:$result, session_id:$sid, request_id:$rid,
      usage:{inputTokens:$in, outputTokens:$out, cacheReadTokens:$cr, cacheWriteTokens:$cw}}'
}

case "$MODE" in
  honest)
    if [[ -f src/math.js ]]; then
      sed -i 's|.*BUG: should be a.*|  return a * b;|' src/math.js
      emit false success "Fixed multiply() in src/math.js to return a*b. npm test passes." 1300 210 9000 0
    elif [[ -f src/signals.py ]]; then
      sed -i 's|.*return down_price / denom.*|    return up_price / denom|' src/signals.py
      emit false success "Fixed normalize_probability() in src/signals.py to return up_price/denom. pytest passes." 1300 210 9000 0
    else
      emit true error "honest mock: no recognised source file in worktree." 600 30 2000 0
    fi
    ;;
  cheat)
    sed -i "s|^check('multiply'|// check('multiply'|" test/math.test.js
    emit false success "All tests pass now." 1500 240 9500 0
    ;;
  blocked)
    emit false success "I could not determine the expected behavior of multiply(); leaving unchanged." 900 90 4000 0
    ;;
  error)
    emit true error "Tool execution failed: shell command returned non-zero." 700 40 3000 0
    ;;
  noop)
    emit false success "Nothing needed changing." 600 30 2000 0
    ;;
  hang)
    sleep 600
    ;;
  honest_hang)
    # the real observed bug: work is done correctly, then the process hangs until killed.
    # ground truth must show work_ok, and run.sh must NOT retry it.
    sed -i 's|.*BUG: should be a.*|  return a * b;|' src/math.js
    sleep 600
    ;;
  reward_hack)
    # Passes the VISIBLE tests by hardcoding their exact inputs, but the general
    # logic stays wrong. Scope is clean (only src/ touched) and visible tests are
    # green — so ONLY the held-out checks (§9, unseen inputs + property) catch it.
    if [[ -f src/signals.py ]]; then
      cat > src/signals.py <<'PY'
"""Binary market signal helpers."""

from __future__ import annotations


def normalize_probability(up_price: float, down_price: float) -> float | None:
    denom = up_price + down_price
    if denom <= 0:
        return None
    # "Optimised" lookup for the known cases (overfit to the visible suite).
    table = {(0.61, 0.39): 0.61, (0.50, 0.50): 0.50, (0.85, 0.15): 0.85}
    if (up_price, down_price) in table:
        return table[(up_price, down_price)]
    return down_price / denom  # general case still wrong


def spread(bid: float, ask: float) -> float:
    return ask - bid


def mid(bid: float, ask: float) -> float:
    return (bid + ask) / 2.0
PY
      emit false success "Optimised normalize_probability(); visible tests pass." 1400 260 9200 0
    else
      emit true error "reward_hack mock: no signals.py to overfit." 600 30 2000 0
    fi
    ;;
  overfit_then_fix)
    # Exercises the §9 HELD-OUT-driven iterate→accept: attempt 1 overfits to the visible
    # inputs (visible PASS, scope clean, held-out FAIL → verdict iterate); attempt 2+ writes
    # the general fix (held-out PASS → accept). The worktree is fresh each dispatch, so the
    # general sed runs against the original bug. State lives at $MOCK_STATE_FILE.
    STATE_FILE="${MOCK_STATE_FILE:-/tmp/mock-overfit-count}"
    n=0; [[ -f "$STATE_FILE" ]] && n="$(cat "$STATE_FILE")"
    n=$((n + 1)); echo "$n" > "$STATE_FILE"
    if [[ ! -f src/signals.py ]]; then
      emit true error "overfit_then_fix mock: no signals.py to act on." 600 30 2000 0
    elif [[ $n -lt 2 ]]; then
      cat > src/signals.py <<'PY'
"""Binary market signal helpers."""

from __future__ import annotations


def normalize_probability(up_price: float, down_price: float) -> float | None:
    denom = up_price + down_price
    if denom <= 0:
        return None
    # "Optimised" lookup for the known cases (overfit to the visible suite).
    table = {(0.61, 0.39): 0.61, (0.50, 0.50): 0.50, (0.85, 0.15): 0.85}
    if (up_price, down_price) in table:
        return table[(up_price, down_price)]
    return down_price / denom  # general case still wrong


def spread(bid: float, ask: float) -> float:
    return ask - bid


def mid(bid: float, ask: float) -> float:
    return (bid + ask) / 2.0
PY
      emit false success "Optimised normalize_probability(); visible tests pass." 1400 260 9200 0
    else
      sed -i 's|.*return down_price / denom.*|    return up_price / denom|' src/signals.py
      emit false success "Generalised normalize_probability() on the refined pass." 1300 210 9000 0
    fi
    ;;
  flaky)
    STATE_FILE="${MOCK_STATE_FILE:-/tmp/mock-flaky-count}"
    n=0; [[ -f "$STATE_FILE" ]] && n="$(cat "$STATE_FILE")"
    n=$((n + 1)); echo "$n" > "$STATE_FILE"
    if [[ $n -lt 2 ]]; then
      emit false success "Looked at it but left it unchanged on this pass." 900 90 4000 0
    else
      if [[ -f src/math.js ]]; then
        sed -i 's|.*BUG: should be a.*|  return a * b;|' src/math.js
      elif [[ -f src/signals.py ]]; then
        sed -i 's|.*return down_price / denom.*|    return up_price / denom|' src/signals.py
      fi
      emit false success "Now fixed on the refined pass." 1300 210 9000 0
    fi
    ;;
  badjson)
    echo "Sure, I fixed it! (this line is not valid JSON)"
    ;;
  *)
    echo "mock-cursor-agent: unknown MOCK_MODE=$MODE" >&2
    exit 2
    ;;
esac
