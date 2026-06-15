# STATE — Ophar

> Soft state (§4). Author: Opus only. A fresh session must run `harness/reconcile.sh`
> BEFORE trusting anything below — the prose is a hint, the claims block is checked.

## Where we are

The full pipeline is built and green on the mock executor (zero quota): an Opus
orchestrator plans and verifies, a Composer executor does the work, and every verdict
comes from independent **ground truth** (`harness/ground-truth.sh`) — never from the
executor's self-report. That trust boundary is the whole point of the project.

What exists:

- **Orchestrate loop** (`harness/orchestrate.sh`): dispatch → ground truth → verdict →
  iterate/accept/reject/block, with a durable `orch/accepted/<task>` landing branch and
  the user's base left untouched.
- **Trust boundary** (`harness/ground-truth.sh`): independent verification of diff,
  visible tests, typecheck/lint, scope, and held-out checks (§9 anti-overfit).
- **Structural scope guard** (`ENFORCE_SCOPE=1`): the worktree is read-only outside
  `allowed_scope` during the executor's run — out-of-scope writes fail at the FS layer.
- **MCP orchestrator** (`harness/mcp_server.py`): exposes the pipeline to any MCP client
  (e.g. Claude Code) as `init_repo` + `run_in_composer` tools, plus `instructions` and
  `pipeline://` resources. This is the conversational entry point — no API key needed.
- **CLI + API server** (`cli/`, `server/`): `opctl` for tasks/metrics/settings and a
  FastAPI server with a strictly serial dispatch worker.
- **Gate suite** (`tests/*.sh`): 12 gates, all green on the mock.

## First-run setup

The two toy target repositories the gates dispatch against are **not** committed (each is
its own git repo). Regenerate them after cloning:

```bash
bash scripts/setup-fixtures.sh   # creates sandbox/ and sandbox-py/
bash harness/reconcile.sh        # 0 discrepancies once fixtures exist
```

## Machine-checked claims
<!-- reconcile.sh verifies each entry against git/tests/files. No ledger claims here:
     the ledger is runtime-local (gitignored), so a clone has none. Keep honest. -->
```json
[
  {"kind":"git","repo":".","grep":"Initial commit"},
  {"kind":"file","path":"harness/verdict.sh","contains":"block"},
  {"kind":"file","path":"harness/verdict.sh","contains":"lint failed"},
  {"kind":"file","path":"harness/ground-truth.sh","contains":"TYPECHECK_CMD"},
  {"kind":"file","path":"harness/orchestrate.sh","contains":"refined spec"},
  {"kind":"file","path":"harness/orchestrate.sh","contains":"cleanup_run_worktree"},
  {"kind":"file","path":"harness/verify-heldout.sh","contains":"mixing-at-verification"},
  {"kind":"file","path":"harness/land.sh","contains":"orch/accepted"},
  {"kind":"file","path":"harness/metrics-report.sh","contains":"overclaim_rate"},
  {"kind":"file","path":"harness/metrics-report.sh","contains":"opus_tokens_total"},
  {"kind":"file","path":"harness/dispatch.sh","contains":"--sandbox"},
  {"kind":"file","path":"harness/dispatch.sh","contains":"ENFORCE_SCOPE"},
  {"kind":"file","path":"harness/iterate.sh","contains":"log-opus.sh"},
  {"kind":"file","path":"harness/lib/log-opus.sh","contains":"opus-metrics.jsonl"},
  {"kind":"file","path":"harness/mcp_server.py","contains":"run_in_composer"},
  {"kind":"file","path":"harness/mcp_server.py","contains":"pipeline://state"},
  {"kind":"file","path":"CLAUDE.md","contains":"delegation discipline"},
  {"kind":"file","path":"AGENTS.md","contains":"Executor boundaries"},
  {"kind":"file","path":"heldout/T-0002/manifest.json","contains":"test_heldout_signals"},
  {"kind":"file","path":"harness/verify-heldout.sh","contains":"store_outside_worktree"},
  {"kind":"file","path":"harness/verify-heldout.sh","contains":"reserve"},
  {"kind":"file","path":"harness/orchestrate.sh","contains":"RESERVED final checks"},
  {"kind":"file","path":"harness/checkpoint.sh","contains":"checkpoint_recommended"},
  {"kind":"file","path":"heldout/T-RESERVE-DEMO/manifest.json","contains":"reserve"},
  {"kind":"file","path":"harness/route-report.sh","contains":"route_around"},
  {"kind":"file","path":"harness/lib/mock-cursor-agent.sh","contains":"overfit_then_fix"},
  {"kind":"file","path":"tasks/T-1002.json","contains":"do not special-case"},
  {"kind":"test","cwd":".","cmd":"bash tests/scope-guard.sh","expect":"pass"},
  {"kind":"test","cwd":".","cmd":"bash tests/heldout-reserve.sh","expect":"pass"},
  {"kind":"test","cwd":".","cmd":"bash tests/checkpoint.sh","expect":"pass"},
  {"kind":"test","cwd":".","cmd":"bash tests/route.sh","expect":"pass"},
  {"kind":"test","cwd":".","cmd":"bash tests/iterate-heldout.sh","expect":"pass"}
]
```
