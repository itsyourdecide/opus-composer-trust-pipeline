#!/usr/bin/env bash
#
# §3 / §6.5 gate: metrics-report.sh computes the rolling-baseline rates correctly
# from a known fixture. Pure jq, no model calls.
#
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$(mktemp)"
trap 'rm -f "$FIX"' EXIT
fail=0

# 3 synthetic runs:
#  1) honest      : work_ok, visible+held-out pass, claimed success
#  2) reward_hack : visible pass, held-out FAIL, claimed success -> overclaim + reward-hack
#  3) red         : visible fail, no held-out, did not claim success
cat > "$FIX" <<'JSONL'
{"task_id":"A","class":"small","attempts":1,"dispatch_status":"ok","wall_clock_s":4,"work_ok":true,"tests_passed":true,"held_out_ran":true,"held_out_passed":true,"reward_hack_suspected":false,"claimed_success":true,"composer_tokens":{"total":1000}}
{"task_id":"B","class":"small","attempts":1,"dispatch_status":"ok","wall_clock_s":6,"work_ok":false,"tests_passed":true,"held_out_ran":true,"held_out_passed":false,"reward_hack_suspected":true,"claimed_success":true,"composer_tokens":{"total":1500}}
{"task_id":"C","class":"large","attempts":2,"dispatch_status":"ok","wall_clock_s":10,"work_ok":false,"tests_passed":false,"held_out_ran":false,"held_out_passed":null,"reward_hack_suspected":false,"claimed_success":false,"composer_tokens":{"total":2000}}
JSONL

S="$(bash "$ROOT/harness/metrics-report.sh" "$FIX" 2>/dev/null)"

assert() { # label jq-expr expected
  local got; got="$(jq -r "$2" <<<"$S")"
  if [[ "$got" == "$3" ]]; then echo "  -> $1 = $got: OK"; else echo "  -> $1 = $got (want $3): FAIL"; fail=1; fi
}

echo "### metrics rollup over a 3-run fixture"
assert "runs"                ".runs" "3"
assert "work_ok_rate"        "(.work_ok_rate*1000|round)" "333"          # 1/3
assert "overclaim_rate"      "(.overclaim_rate*1000|round)" "333"        # B only
assert "visible_pass_rate"   "(.visible_pass_rate*1000|round)" "667"     # A,B
assert "held_out_pass_rate"  "(.held_out_pass_rate*100|round)" "50"      # A pass, B fail
assert "held_out_runs"       ".held_out_runs" "2"
assert "reward_hack_count"   ".reward_hack_count" "1"
assert "composer_tokens"     ".composer_tokens_total" "4500"
assert "class small n"       ".by_class.small.n" "2"
assert "class large n"       ".by_class.large.n" "1"

# --- §3 quantile rigor: failures counted SEPARATELY; cost quantiles over COMPLETED only ---
FIX2="$(mktemp)"; trap 'rm -f "$FIX" "$FIX2"' EXIT
cat > "$FIX2" <<'JSONL'
{"task_id":"A","class":"small","dispatch_status":"ok","wall_clock_s":4,"work_ok":true,"attempts":1,"composer_tokens":{"total":100}}
{"task_id":"B","class":"small","dispatch_status":"ok","wall_clock_s":6,"work_ok":true,"attempts":1,"composer_tokens":{"total":200}}
{"task_id":"C","class":"small","dispatch_status":"ok","wall_clock_s":8,"work_ok":true,"attempts":2,"composer_tokens":{"total":300}}
{"task_id":"D","class":"small","dispatch_status":"timeout","wall_clock_s":120,"work_ok":false,"attempts":3,"composer_tokens":{"total":50}}
{"task_id":"E","class":"small","dispatch_status":"invalid_json","wall_clock_s":2,"work_ok":false,"attempts":3,"composer_tokens":{"total":0}}
JSONL
S="$(bash "$ROOT/harness/metrics-report.sh" "$FIX2" 2>/dev/null)"

echo "### quantile rigor over a 5-run fixture (3 ok, 1 timeout, 1 bad-json)"
assert "reliability.completed"        ".reliability.completed" "3"
assert "timeout_rate"                 "(.reliability.timeout_rate*100|round)" "20"
assert "invalid_json_rate"            "(.reliability.invalid_json_rate*100|round)" "20"
assert "failed_before_completion"     "(.reliability.failed_before_completion_rate*100|round)" "40"
# cost/latency quantiles must be over the 3 COMPLETED runs only — the 120s timeout excluded
assert "quantile basis n"             ".quantiles.wall_clock_s.n" "3"
assert "wall p50 (completed only)"    ".quantiles.wall_clock_s.p50" "6"
assert "wall p95 excludes timeout"    ".quantiles.wall_clock_s.p95" "8"
assert "p95 flagged low-confidence"   ".quantiles.wall_clock_s.low_confidence_p95" "true"
assert "p90 flagged low-confidence"   ".quantiles.wall_clock_s.low_confidence_p90" "true"
assert "comp tokens p50 (completed)"  ".quantiles.composer_tokens.p50" "200"

echo; [[ $fail -eq 0 ]] && echo "METRICS (§3/§6.5) GATE: GREEN" || echo "METRICS (§3/§6.5) GATE: RED"
exit $fail
