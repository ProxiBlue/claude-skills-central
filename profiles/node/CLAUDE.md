# Node / TypeScript Dev Guide (fleet profile: node)

## Always-on core (situational rules load on trigger via core-triggers; mechanics enforced by hooks)

@.claude/rules/model-tiering.md
@.claude/rules/core-triggers.md

This container runs the **node** fleet profile (`PB_STACK=node`). Stack-specific
truth lives in the project, not here: read the project root `CLAUDE.md`,
`.claude/testing.md` and `.claude/code-standards.md` before writing code. If those
disagree with this file, the project files win.

## Agent Delegation (read first)

For one-off result-only tasks, delegate to a subagent. The subagent's exploration trace dies with its window; only the result enters main context.

**Delegate:** "find / where / which", "audit / review for X", "does the codebase do Y", "investigate why Y", "summarize what changed", any task needing more than ~3 unrelated file reads.

**Don't delegate:** editing files, step-by-step refactor planning, iterative back-and-forth, single-file or single-command tasks.

**Pick the specialist first.** `.claude/agents/` holds `node-developer`, `node-reviewer`, `node-security-analyst` plus the pb-hcf pipeline agents. Use a specialist when one fits; fall back to `Explore` / `general-purpose` otherwise.

## Agent Teams

Teams spawn multiple Claude instances for parallel work; 4-15x tokens. Use for multi-file changes only. Templates in `.claude/teams/` (Magento-flavoured; adapt file ownership to `src/` + `tests/`). Team lead final verification: the full-suite, typecheck and lint commands from `.claude/testing.md`.

## Toolchain (defaults; project `testing.md` / `package.json` scripts override)

Package manager = whichever lockfile exists (`pnpm-lock.yaml` → pnpm, `package-lock.json` → npm, `yarn.lock` → yarn). Prefer the project's `package.json` scripts over raw binaries.

| Job | Command (pnpm shown) |
|---|---|
| Deps | `pnpm install --frozen-lockfile` (never `pnpm update` / add deps without asking) |
| Tests, targeted | `pnpm test <path>` / `pnpm exec vitest run <path> -t "<name>"` |
| Tests, full | `pnpm test` (unit + integration), `pnpm test:e2e` (Playwright) |
| Types | `pnpm typecheck` (`tsc --noEmit`) — `tsc-edit-check` hook also runs on edits |
| Lint / format | `pnpm lint` (biome or eslint, per project) · format only when asked |
| Mutation | Stryker (`pnpm exec stryker run`) if installed; else say so |
| Dep CVEs | `pnpm audit` |
| Debugger | `node --inspect` + Chrome DevTools / `chrome-devtools` MCP for the browser side |

Run inside the DDEV container; never `ddev exec` from inside it.

## Coding Standards (fleet baseline)

- TypeScript `strict`; no `any` without a one-line justification; `unknown` + narrowing at I/O boundaries.
- ESM (`"type": "module"`); explicit return types on exported functions.
- Validate every external input (HTTP body/query/params, env, LLM output) with a schema at the boundary; never trust shape from `JSON.parse`.
- No global mutable state; inject config/DB/clients.
- Parameterised queries only — never string-built SQL; query-builder raw escapes (`sql.raw`, `$queryRawUnsafe`) only with a justification comment.
- `child_process.execFile`/`spawn` with arg arrays; never `exec` with interpolated strings.
- No `dangerouslySetInnerHTML` on user/LLM text. Client bundles never carry secrets (Vite exposes every `VITE_*` var).
- Structured logger for diagnostics; no stray `console.log` left in `src/` (debugging belongs in the debugger). Never log secrets or API keys.
- Async: always `await` or explicitly handle promises; no floating promises.

## Runtime errors

If the project is wired to Bugsink (`.claude/bugsink.md`), ask Bugsink before grepping logs (see `investigation` rule). Otherwise read the dev server output / project log path named in the project CLAUDE.md.

## Playwright (DDEV)

**DNS bug:** `<project>.ddev.site` can resolve to 127.0.0.1 instead of the ddev-router IP. Fix with `ddev fix-dns` or /etc/hosts. Verify: `getent hosts <project>.ddev.site` returns 172.x.x.x.

## Git Workflow

- Before switching branches: check for uncommitted changes; stop and ask if any exist. Feature/bug work branches from the LIVE-equivalent branch named in the project CLAUDE.md (`live` or `main`).
- After switching to a working branch, merge the current LIVE branch into it.
- We NEVER push feature branches to origin. Merge locally, push the LIVE branch (or `uat` where the project has one).
- Single developer; no GitHub PR flow.
- Deploy trigger is per project (GitHub Actions, buddy.works, or none) — read the project CLAUDE.md. A push to a deploy branch may deploy.
- Feature branches: `feature/<ticket>_<scope_keywords>` (short).

## Deployment & Git Safety (cardinal rules)

- **NEVER push, deploy, or merge without explicit user authorization in the current turn.** Earlier "continue/yes/go" does NOT authorize the NEXT push.
- **NEVER edit live/production directly** via SSH or any other path. SSH to live is read-only for investigation.
- **NEVER push to the LIVE branch or `uat` autonomously.** Pushes go through the `/deploy-check` skill.
- **NEVER `git push --force`** without explicit typed confirmation.
- Tests + typecheck + diff review MUST complete before any push.

## Environment Context (host vs DDEV container)

Before any task involving config files, MCP setup, mount permissions, or host paths — declare and verify your execution context:

- Run `hostname && pwd && ls /var/www/html 2>/dev/null && echo "HOME=$HOME"` and state whether you're in the host shell OR the DDEV web container.
- RO mounts inside the container: `/var/www/html/.claude/{settings.json,agents,rules,hooks,scripts,teams,plugins-seed}` and `~/.claude/{CLAUDE.md,mcp.json}`. Edits there fail; ask the user to edit from the host (sources live in `~/claude-skills-central/profiles/node/` and `~/claude-code-node-agents/`).
- Host paths (`~/workspace/...`) are not visible in the container.

## Tool Selection

- No code-graph MCP for Node. Use the LSP tool / `tsc`, then Grep/Read.
- Library docs: Context7 first (React, Vite, Fastify, Vitest, Playwright, SDKs).
- Knowledge: Graphiti, scoped `[<project>, fleet]` (project may declare its own group id — the project CLAUDE.md wins).

## Database

Use the project's own DB access path as documented in its CLAUDE.md (SQLite: `sqlite3 <db>` read-only queries). Never write to a prod DB.

## New tasks while existing task are being executed with todo lists

- Do not immediately pivot to the new task unless marked urgent.
- Add the new task to the todo list and show the list.
- At the end of the current ask, work the todo list without stopping to ask. First on, first off.
