#!/usr/bin/env bash
#
# §2-Phase-0 / §5 gate: the routing decision layer turns the per-task dud table into a
# route decision, with the sample-size guard and model-version awareness.
#
#   hard/5 : 3/4 tasks are duds (never-passed / >=3 iters / reward-hack) -> route_around
#   easy/1 : 0/3 duds                                                    -> pipeline
#   thin/2 : 1/1 dud but n < ROUTE_MIN_N                                 -> pipeline (thin data)
#
# Pure jq over a synthetic fixture; zero quota.
#
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$(mktemp)"; trap 'rm -f "$FIX"' EXIT
fail=0

# Per-task iteration records. hard/5 has one task (H4) on a different model -> mixed versions.
cat > "$FIX" <<'JSONL'
{"ts":"2026-06-14T10:00:00Z","task_id":"H1","class":"hard","complexity":5,"model":"composer-2.5","dispatch_status":"ok","work_ok":false,"claimed_success":true}
{"ts":"2026-06-14T10:00:00Z","task_id":"H2","class":"hard","complexity":5,"model":"composer-2.5","dispatch_status":"ok","work_ok":false}
{"ts":"2026-06-14T10:01:00Z","task_id":"H2","class":"hard","complexity":5,"model":"composer-2.5","dispatch_status":"ok","work_ok":false}
{"ts":"2026-06-14T10:02:00Z","task_id":"H2","class":"hard","complexity":5,"model":"composer-2.5","dispatch_status":"ok","work_ok":true}
{"ts":"2026-06-14T10:00:00Z","task_id":"H3","class":"hard","complexity":5,"model":"composer-2.5","dispatch_status":"ok","work_ok":false,"reward_hack_suspected":true}
{"ts":"2026-06-14T10:00:00Z","task_id":"H4","class":"hard","complexity":5,"model":"composer-2.5-fast","dispatch_status":"ok","work_ok":true}
{"ts":"2026-06-14T10:00:00Z","task_id":"E1","class":"easy","complexity":1,"model":"composer-2.5","dispatch_status":"ok","work_ok":true}
{"ts":"2026-06-14T10:00:00Z","task_id":"E2","class":"easy","complexity":1,"model":"composer-2.5","dispatch_status":"ok","work_ok":true}
{"ts":"2026-06-14T10:00:00Z","task_id":"E3","class":"easy","complexity":1,"model":"composer-2.5","dispatch_status":"ok","work_ok":true}
{"ts":"2026-06-14T10:00:00Z","task_id":"T1","class":"thin","complexity":2,"model":"composer-2.5","dispatch_status":"ok","work_ok":false}
JSONL

# DUD_THRESHOLD 0.5, DUD_ITERS 3, ROUTE_MIN_N 3 so the small fixture exercises every branch.
S="$(DUD_THRESHOLD=0.5 DUD_ITERS=3 ROUTE_MIN_N=3 EXPLORATION_SHARE=0.1 \
      bash "$ROOT/harness/route-report.sh" "$FIX" 2>/dev/null)"

assert() { local got; got="$(jq -r "$2" <<<"$S")"; if [[ "$got" == "$3" ]]; then echo "  -> $1 = $got: OK"; else echo "  -> $1 = $got (want $3): FAIL"; fail=1; fi; }

echo "### routing table over an 8-task fixture"
assert "tasks_seen"                 ".tasks_seen" "8"
assert "hard/5 n"                   '.by_cell["hard/5"].n' "4"
assert "hard/5 duds"                '.by_cell["hard/5"].duds' "3"
assert "hard/5 decision"            '.by_cell["hard/5"].decision' "route_around"
assert "hard/5 mixed models"        '.by_cell["hard/5"].mixed_model_versions' "true"
assert "easy/1 decision"            '.by_cell["easy/1"].decision' "pipeline"
assert "thin/2 low_confidence"      '.by_cell["thin/2"].low_confidence' "true"
assert "thin/2 decision (thin)"     '.by_cell["thin/2"].decision' "pipeline"
assert "route_around lists hard/5"  '(.route_around | index("hard/5")) != null' "true"
assert "components.never_passed"    ".components.never_passed" "3"
assert "components.reward_hack"     ".components.reward_hack" "1"
assert "components.many_iterations" ".components.many_iterations" "1"
assert "by_class hard decision"     '.by_class.hard.decision' "route_around"

echo; [[ $fail -eq 0 ]] && echo "ROUTING (§2/§5) GATE: GREEN" || echo "ROUTING (§2/§5) GATE: RED"
exit $fail
