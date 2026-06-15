# Ophar

**Ophar** (Opus · Composer · Harness) - pair the smartest available model (Opus) with a
cheap, fast executor (Composer) so you can build large projects without paying Opus prices
for every line of code. Opus plans and delegates; Composer does the implementation in
isolated git worktrees. The harness decides accept/reject from independent *ground truth*
(the real diff, the real test run, scope, held-out checks) - not from the executor's report.

> 🇬🇧 English below · [🇷🇺 Русская версия ниже](#-ophar-русский)

---

## Why

**Opus** is the smartest model available right now, but running an entire large project
on it gets expensive fast. **Composer** is much cheaper and quicker for coding work, but
on its own it cannot hold architecture, long horizons, or a whole codebase together.

This pipeline combines the two and neutralizes the gap:

- **Opus** (orchestrator) - the brain: breaks work into tasks, writes specs with
  machine-checkable acceptance criteria, keeps its own context thin.
- **Composer** (executor, e.g. `cursor-agent`) - the hands: fast, cheap implementation in
  an isolated git worktree.
- **The harness** - independently verifies every result and is the *only* source of
  verdicts.

**Trust boundary (a precaution, not the main idea):** the orchestrator should stay clean
and innocent - it decides from verified facts, not from the executor's narrative. The
executor only sees what it needs for the current task (scoped spec, no held-out checks, no
extra project context). That keeps Opus's window small and stops the cheap model from
polluting architectural decisions.

## Architecture

```
  you ── natural language ──▶  Opus (orchestrator, via MCP)
                                  │  authors spec + held-out checks
                                  ▼
                          run_in_composer  ──▶  orchestrate.sh
                                                    │
                          ┌─────────────────────────┼─────────────────────────┐
                          ▼                          ▼                         ▼
                     dispatch.sh              ground-truth.sh             verdict.sh
              (isolated worktree +       (diff · tests · typecheck ·   accept / iterate /
               headless executor +        lint · scope · held-out §9)   reject / block
               structural scope guard)            │
                          └──────────── GROUND TRUTH ───────────┘
                                                    │
                                  ▼ accept → land on orch/accepted/<task>  (base untouched)
                          Opus explains the verified result ──▶  you
```

The executor's report is **untrusted input** by design (see trust boundary above); the
diff/test/scope/held-out bundle is the **only** trusted signal for accept/reject.

## Install (recommended)

**Requirements:** Python 3.11+, `git`, `bash`, `jq`. (`node` only for the JS toy repo.)
For real executor runs you also need the `cursor-agent` CLI.

### From GitHub (minimal steps)

```bash
pip install ophar
python -m ophar setup
```

`python -m ophar setup` works on **Windows, macOS, and Linux** without adding pip Scripts
to PATH. It copies the pipeline bundle to `~/.local/share/ophar` (override with
`OPHAR_HOME`) and registers MCP in **Cursor** (`~/.cursor/mcp.json`) and **Claude Code**
(`claude mcp add --scope user`) in parallel.

Reload Cursor (Settings → MCP) or run `claude`.

> Alias: `ophar-setup` also works when pip's Scripts folder is on your PATH.

### From a git checkout (development)

```bash
git clone https://github.com/itsyourdecide/ophar.git
cd ophar
./scripts/install.sh
```

This creates `.venv`, installs editable `ophar`, and runs `python -m ophar setup`.

### MCP config (manual)

If you prefer to wire MCP yourself:

```json
{
  "mcpServers": {
    "ophar": {
      "command": "python",
      "args": ["-m", "ophar", "mcp"]
    }
  }
}
```

On Windows, if `python` is not on PATH, use the full path to your Python executable
(same one you used for `pip install`). `ophar-setup` / `python -m ophar setup` writes
this automatically.

See [`docs/mcp.cursor.json.example`](docs/mcp.cursor.json.example). Claude Code:

```bash
claude mcp add --scope user ophar -- python -m ophar mcp
```

## Quickstart (developers)

After install:

```bash
bash scripts/setup-fixtures.sh     # build the toy target repos (sandbox/, sandbox-py/)
for t in tests/*.sh; do bash "$t"; done   # 11 gates, all green on the mock (zero quota)
bash harness/reconcile.sh          # 0 discrepancies
```

Everything above uses a **mock executor** - no API quota, no network.

## Using the orchestrator (via MCP)

The orchestrator is reached through the **`ophar` MCP server** (`python -m ophar mcp`), which exposes
the whole pipeline to any MCP client (e.g. Cursor, Claude Code) - no API key, it rides your
existing subscription.

- **tools** - `init_repo` (scaffold a target repo) and `run_in_composer` (dispatch + get
  verified ground truth back);
- **instructions** - the orchestrator's operating manual (role, trust boundary, how to
  author specs and held-out checks), auto-injected into the session;
- **resources** - `pipeline://state`, `pipeline://discipline`, `pipeline://plan`,
  `pipeline://ledger` (live, read on demand).

Example: *"Fix the bug in `normalize_probability` in /path/to/repo; tests are in
`tests/`."* Opus authors a spec, dispatches Composer, and reports the **ground truth** -
not Composer's story.

## Using the CLI (`opctl`)

`opctl` manages the pipeline's server, tasks, and metrics (it is **not** the
orchestrator - that's the MCP path above):

```bash
opctl serve          # start the FastAPI server (serial dispatch worker)
opctl tasks ...      # submit / list / inspect tasks
opctl metrics        # metrics dashboard
opctl system reconcile   # check STATE.md claims against ground truth
opctl settings-set MAX_ITERATIONS 5
```

## How it works

- **Orchestrate loop** (`harness/orchestrate.sh`) - dispatch → ground truth → verdict,
  iterating up to `MAX_ITERATIONS`. On accept it lands the result on a durable
  `orch/accepted/<task>` branch and **never merges to your base** (that stays a human
  decision). The throwaway worktree and scratch branch are reclaimed afterward.
- **Ground truth** (`harness/ground-truth.sh`) - the §6.2 trusted bundle: actual diff,
  visible tests, optional typecheck/lint, scope, and held-out checks.
- **Held-out, anti-overfit (§9)** - checks authored trusted-side and *never shown to the
  executor*. If the visible tests pass but held-out fails, the executor overfit - that is
  caught and not accepted.
- **Structural scope guard** (`ENFORCE_SCOPE=1`) - during the executor's run the worktree
  is read-only outside `allowed_scope`, so out-of-scope writes fail at the filesystem
  layer (detection in ground truth stays as defense-in-depth).
- **Serial worker** - exactly one dispatch at a time (the harness uses a shared run
  pointer); both the FastAPI worker and the MCP server enforce this.

## Project layout

```
harness/        the pipeline glue (bash) + mcp_server.py (the MCP orchestrator)
  orchestrate.sh, dispatch.sh, ground-truth.sh, verdict.sh, iterate.sh, land.sh, ...
  lib/          mock executor + mock claude (for zero-quota gates)
cli/            opctl - Typer CLI
server/         FastAPI server (routers, serial dispatch worker, registry)
tests/          11 gate scripts (run on the mock)
tasks/          committed task-spec fixtures (T-0001/0002/1002)
heldout/        committed held-out fixtures (§9)
state/          STATE.md (soft state) + runtime ledger (gitignored)
scripts/        setup-fixtures.sh - regenerate the toy target repos
CLAUDE.md       orchestrator delegation discipline
AGENTS.md       executor boundaries
orchestrator-pipeline-plan.md   full design & rationale
```

## Notes

- **Real executor runs cost quota.** Development uses the mock
  (`CURSOR_AGENT_CMD=harness/lib/mock-cursor-agent.sh`). For real runs, pin the model
  (`composer-2.5`) and keep batches small.
- **`SANDBOX`** defaults to `disabled` because `cursor-agent`'s own sandbox can't start on
  every host (AppArmor); the harness still confines the executor via the isolated worktree
  + structural scope guard. Set `SANDBOX=enabled` where the cursor sandbox works.
- The full design lives in
  [`orchestrator-pipeline-plan.md`](orchestrator-pipeline-plan.md).

## License

MIT © [itsyourdecide](https://github.com/itsyourdecide). See [LICENSE](LICENSE).

---

# 🇷🇺 Ophar (Русский)

**Ophar** (Opus · Composer · Harness) - связка самой умной доступной модели (Opus) с
дешёвым и быстрым исполнителем (Composer), чтобы вести большие проекты без оплаты Opus за
каждую строчку кода. Opus планирует и делегирует; Composer делает реализацию в
изолированных git-worktree. Harness принимает accept/reject по независимой *ground truth*
(реальный diff, прогон тестов, scope, held-out) - а не по отчёту исполнителя.

## Зачем

**Opus** - самая умная модель из доступных сейчас, но гонять на нём целый большой проект
дорого. **Composer** - намного дешевле и быстрее на кодинге, но сам по себе не тянет
архитектуру, длинный горизонт и целостность большой кодовой базы.

Этот пайплайн связывает их и нивелирует разрыв:

- **Opus** (оркестратор) - мозг: дробит работу на задачи, пишет спеки с машинно-
  проверяемыми критериями приёмки, держит свой контекст тонким.
- **Composer** (исполнитель, напр. `cursor-agent`) - руки: быстрая дешёвая реализация в
  изолированном git-worktree.
- **Харнесс** - независимо проверяет каждый результат и является *единственным* источником
  вердиктов.

**Граница доверия (мера осторожности, не главная идея):** оркестратор должен оставаться
чистым и невинным - он решает по проверенным фактам, а не по нарративу исполнителя.
Исполнитель видит только то, что нужно для текущей задачи (scope-спека, без held-out, без
лишнего контекста проекта). Так окно Opus остаётся маленьким, а дешёвая модель не
засоряет архитектурные решения.

## Архитектура

```
  ты ── естественный язык ──▶  Opus (оркестратор, через MCP)
                                  │  пишет спеку + held-out проверки
                                  ▼
                          run_in_composer  ──▶  orchestrate.sh
                                                    │
                          ┌─────────────────────────┼─────────────────────────┐
                          ▼                          ▼                         ▼
                     dispatch.sh              ground-truth.sh             verdict.sh
              (изолированный worktree +   (diff · тесты · typecheck ·  accept / iterate /
               headless-исполнитель +      lint · scope · held-out §9)   reject / block
               структурный scope-guard)           │
                          └──────────── GROUND TRUTH ───────────┘
                                                    │
                            ▼ accept → land в orch/accepted/<task>  (база не тронута)
                          Opus объясняет проверенный результат ──▶  тебе
```

Отчёт исполнителя - **недоверенный вход** по задумке (см. границу доверия выше); связка
diff/тесты/scope/held-out - **единственный** доверенный сигнал для accept/reject.

## Установка (рекомендуется)

**Требуется:** Python 3.11+, `git`, `bash`, `jq`. (`node` - только для JS-песочницы.)
Для реальных прогонов нужен CLI `cursor-agent`.

### С GitHub (минимум шагов)

```bash
pip install ophar
python -m ophar setup
```

`python -m ophar setup` работает на **Windows, macOS и Linux** без добавления pip Scripts
в PATH. Копирует bundle в `~/.local/share/ophar` (или `OPHAR_HOME`) и параллельно
регистрирует MCP в **Cursor** и **Claude Code**. Перезагрузи Cursor или запусти `claude`.

> Алиас: `ophar-setup` тоже работает, если Scripts в PATH.

### Из git-репозитория (разработка)

```bash
git clone https://github.com/itsyourdecide/ophar.git
cd ophar
./scripts/install.sh
```

### MCP вручную

```bash
claude mcp add --scope user ophar -- python -m ophar mcp
```

Пример для Cursor: [`docs/mcp.cursor.json.example`](docs/mcp.cursor.json.example).

## Быстрый старт (разработчикам)

После установки:

```bash
bash scripts/setup-fixtures.sh     # создать игрушечные репо-цели (sandbox/, sandbox-py/)
for t in tests/*.sh; do bash "$t"; done   # 11 гейтов, все зелёные на моке (без quota)
bash harness/reconcile.sh          # 0 расхождений
```

Всё выше работает на **моке исполнителя** - без quota и без сети.

## Использование оркестратора (через MCP)

Оркестратор доступен через **MCP-сервер `ophar`** (`python -m ophar mcp`), который отдаёт весь
пайплайн любому MCP-клиенту (Cursor, Claude Code) - без API-ключа, на твоей подписке.

Дальше просто запусти `claude` и общайся. MCP-сервер отдаёт всё для работы с пайплайном:

- **tools** - `init_repo` (создать репо-цель) и `run_in_composer` (диспатч + проверенная
  ground truth обратно);
- **instructions** - операционный мануал оркестратора (роль, граница доверия, как писать
  спеки и held-out), автоматически вшивается в сессию;
- **resources** - `pipeline://state`, `pipeline://discipline`, `pipeline://plan`,
  `pipeline://ledger` (живые, читаются по требованию).

Пример: *«Исправь баг в `normalize_probability` в /path/to/repo; тесты в `tests/`.»* Opus
пишет спеку, диспатчит Composer и докладывает **ground truth** - а не историю Composer.

## Использование CLI (`opctl`)

`opctl` управляет сервером, задачами и метриками пайплайна (это **не** оркестратор - он
через MCP выше):

```bash
opctl serve          # запустить FastAPI-сервер (серийный воркер диспатча)
opctl tasks ...      # submit / list / inspect задач
opctl metrics        # дашборд метрик
opctl system reconcile   # сверить claims STATE.md с ground truth
opctl settings-set MAX_ITERATIONS 5
```

## Как это работает

- **Цикл оркестрации** (`harness/orchestrate.sh`) - диспатч → ground truth → вердикт, с
  итерациями до `MAX_ITERATIONS`. При accept результат лэндится на durable-ветку
  `orch/accepted/<task>` и **никогда не мержится в твою базу** (это решение человека).
  Временный worktree и scratch-ветка убираются после.
- **Ground truth** (`harness/ground-truth.sh`) - доверенная связка §6.2: реальный diff,
  видимые тесты, опционально typecheck/lint, scope и held-out.
- **Held-out, анти-оверфит (§9)** - проверки пишутся на доверенной стороне и *никогда не
  показываются исполнителю*. Если видимые тесты прошли, а held-out упал - исполнитель
  переобучился, это ловится и не принимается.
- **Структурный scope-guard** (`ENFORCE_SCOPE=1`) - во время прогона исполнителя worktree
  доступен только на запись внутри `allowed_scope`, так что запись вне scope падает на
  уровне ФС (детект в ground truth остаётся как defense-in-depth).
- **Серийный воркер** - ровно один диспатч за раз (харнесс использует общий указатель
  прогона); это обеспечивают и FastAPI-воркер, и MCP-сервер.

## Структура проекта

```
harness/        связка пайплайна (bash) + mcp_server.py (MCP-оркестратор)
  orchestrate.sh, dispatch.sh, ground-truth.sh, verdict.sh, iterate.sh, land.sh, ...
  lib/          мок-исполнитель + мок-claude (для гейтов без quota)
cli/            opctl - Typer CLI
server/         FastAPI-сервер (роутеры, серийный воркер диспатча, реестр)
tests/          11 скриптов-гейтов (на моке)
tasks/          закоммиченные фикстуры спек (T-0001/0002/1002)
heldout/        закоммиченные held-out фикстуры (§9)
state/          STATE.md (soft state) + рантайм-ledger (gitignored)
scripts/        setup-fixtures.sh - пересоздать игрушечные репо-цели
CLAUDE.md       дисциплина делегирования оркестратора
AGENTS.md       границы исполнителя
orchestrator-pipeline-plan.md   полный дизайн и обоснование
```

## Примечания

- **Реальные прогоны исполнителя тратят quota.** Разработка идёт на моке
  (`CURSOR_AGENT_CMD=harness/lib/mock-cursor-agent.sh`). Для реальных прогонов пинуй модель
  (`composer-2.5`) и держи батчи маленькими.
- **`SANDBOX`** по умолчанию `disabled`, потому что собственный сэндбокс `cursor-agent`
  стартует не на каждом хосте (AppArmor); харнесс всё равно ограничивает исполнителя через
  изолированный worktree + структурный scope-guard. Ставь `SANDBOX=enabled` там, где
  сэндбокс cursor работает.
- Полный дизайн - в
  [`orchestrator-pipeline-plan.md`](orchestrator-pipeline-plan.md).

## Лицензия

MIT © [itsyourdecide](https://github.com/itsyourdecide). См. [LICENSE](LICENSE).
