# Python Dev Guide (fleet profile: python)

## Always-on core (situational rules load on trigger via core-triggers; mechanics enforced by hooks)

@.claude/rules/model-tiering.md
@.claude/rules/core-triggers.md

This container runs the **python** fleet profile (`PB_STACK=python`). Stack-specific
truth lives in the project, not here: read the project root `CLAUDE.md`,
`.claude/testing.md` and `.claude/code-standards.md` before writing code. If those
disagree with this file, the project files win.

## Agent Delegation (read first)

For one-off result-only tasks, delegate to a subagent. The subagent's exploration trace dies with its window; only the result enters main context.

**Delegate:** "find / where / which", "audit / review for X", "does the codebase do Y", "investigate why Y", "summarize what changed", any task needing more than ~3 unrelated file reads.

**Don't delegate:** editing files, step-by-step refactor planning, iterative back-and-forth, single-file or single-command tasks.

**Pick the specialist first.** `.claude/agents/` holds `fastapi-developer`, `python-reviewer`, `python-security-analyst`, `deploy-engineer` plus the pb-hcf pipeline agents. Use a specialist when one fits; fall back to `Explore` / `general-purpose` otherwise.

## Agent Teams

Teams spawn multiple Claude instances for parallel work; 4-15x tokens. Use for multi-file changes only. Templates in `.claude/teams/` (Magento-flavoured; adapt file ownership to `src/<pkg>/` + `tests/`). Team lead final verification: the full-suite and lint commands from `.claude/testing.md`.

## Toolchain (defaults; project `testing.md` overrides)

| Job | Command |
|---|---|
| Env / deps | `uv sync --frozen` (lockfile `uv.lock`; `requirements.txt` is an export for prod pip) |
| Tests, targeted | `uv run pytest -x tests/path/test_x.py::test_name` |
| Tests, full | `uv run pytest -q` |
| Coverage | `uv run pytest --cov --cov-report=xml` → `var/coverage.xml` (Cobertura) |
| Lint / format | `uv run ruff check src tests` · `uv run ruff format src tests` |
| Modernise | `uv run ruff check --select UP --fix` (Python twin of rector) |
| Types | `uv run basedpyright` |
| Mutation | `uv run mutmut run` (config in `[tool.mutmut]`) |
| Dep CVEs | `uv run pip-audit` |
| Debugger | `mcp-debugger` MCP (debugpy over DAP) — see `python-debugging` rule |

`.venv/bin/<tool>` is equivalent to `uv run <tool>`. Run inside the DDEV container; never `ddev exec` from inside it.

## Coding Standards (fleet baseline)

- Python 3.13, src layout (`src/<pkg>/`), tests mirror source (`src/<pkg>/a/b.py` → `tests/a/test_b.py`).
- Type hints on every signature; PEP 604 unions; pydantic v2 for I/O models and settings (`pydantic-settings`, env-prefixed).
- No global mutable state; inject config/DB/clients (FastAPI `Depends()`).
- `structlog` for logs; never `print()` for diagnostics (guarded by `python-debug-guard`). Never log secrets.
- `subprocess.run([...], check=True, capture_output=True, text=True)`; never `shell=True`.
- `pathlib.Path` over string paths. Async only where I/O happens.
- Never bare `except Exception:` without re-raise or traceback log.

## Runtime errors

Runtime errors go to Bugsink via `sentry-sdk[fastapi]`, one Bugsink project per
environment (`<project>-dev`, `<project>-live`). Ask Bugsink before grepping logs
(see `investigation` rule). Dev log: `.ddev/uvicorn.log`. Prod: journald on the host.

## Playwright (DDEV)

**DNS bug:** `<project>.ddev.site` can resolve to 127.0.0.1 instead of the ddev-router IP. Fix with `ddev fix-dns` or /etc/hosts. Verify: `getent hosts <project>.ddev.site` returns 172.x.x.x.

## Git Workflow

- Before switching branches: check for uncommitted changes; stop and ask if any exist. Feature/bug work branches from `live`.
- After switching to a working branch, merge current `live` into it.
- We NEVER push feature branches to origin. Merge locally, push `live` (or `uat` where the project has one).
- Single developer; no GitHub PR flow.
- Deploy trigger is per project (GitHub Actions on push to `live`, or buddy.works) — read the project CLAUDE.md. A push to a deploy branch deploys.
- Feature branches: `feature/<ticket>_<scope_keywords>` (short).

## Deployment & Git Safety (cardinal rules)

- **NEVER push, deploy, or merge without explicit user authorization in the current turn.** Earlier "continue/yes/go" does NOT authorize the NEXT push.
- **NEVER edit live/production directly** via SSH or any other path. SSH to live is read-only for investigation.
- **NEVER push to `live` or `uat` autonomously.** Pushes go through the `/deploy-check` skill.
- **NEVER `git push --force`** without explicit typed confirmation.
- Tests + diff review MUST complete before any push.
- Prod secrets files (e.g. `/etc/<app>.env`) are append-only by hand; a deploy never overwrites them.

## Environment Context (host vs DDEV container)

Before any task involving config files, MCP setup, mount permissions, or host paths — declare and verify your execution context:

- Run `hostname && pwd && ls /var/www/html 2>/dev/null && echo "HOME=$HOME"` and state whether you're in the host shell OR the DDEV web container.
- RO mounts inside the container: `/var/www/html/.claude/{settings.json,agents,rules,hooks,scripts,teams,plugins-seed}` and `~/.claude/{CLAUDE.md,mcp.json}`. Edits there fail; ask the user to edit from the host (sources live in `~/claude-skills-central/profiles/python/` and `~/claude-code-python-agents/`).
- Host paths (`~/workspace/...`) are not visible in the container.

## Tool Selection

- No code-graph MCP for Python (decision 2026-10-08). Use the LSP tool / `basedpyright`, then Grep/Read.
- Library docs: Context7 first.
- Knowledge: Graphiti, scoped `[<project>, fleet]`.

## Database

Use the project's own DB access path as documented in its CLAUDE.md (SQLite: `sqlite3 <db>` read-only queries). Never write to a prod DB.

## New tasks while existing task are being executed with todo lists

- Do not immediately pivot to the new task unless marked urgent.
- Add the new task to the todo list and show the list.
- At the end of the current ask, work the todo list without stopping to ask. First on, first off.
