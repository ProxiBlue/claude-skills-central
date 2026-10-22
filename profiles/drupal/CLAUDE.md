# Drupal Dev Guide (fleet profile: drupal)

## Always-on core (situational rules load on trigger via core-triggers; mechanics enforced by hooks)

@.claude/rules/model-tiering.md
@.claude/rules/core-triggers.md

This container runs the **drupal** fleet profile (`PB_STACK=drupal`). Stack-specific
truth lives in the project, not here: read the project root `CLAUDE.md`,
`.claude/testing.md` and `.claude/code-standards.md` before writing code. If those
disagree with this file, the project files win.

## Agent Delegation (read first)

For one-off result-only tasks, delegate to a subagent. The subagent's exploration trace dies with its window; only the result enters main context.

**Delegate:** "find / where / which", "audit / review for X", "does the codebase do Y", "investigate why Y", "summarize what changed", any task needing more than ~3 unrelated file reads.

**Don't delegate:** editing files, step-by-step refactor planning, iterative back-and-forth, single-file or single-command tasks.

**Pick the specialist first.** `.claude/agents/` holds `drupal-developer`, `drupal-reviewer`, `drupal-security-analyst` plus the pb-hcf pipeline agents. Use a specialist when one fits; fall back to `Explore` / `general-purpose` otherwise.

## Agent Teams

Teams spawn multiple Claude instances for parallel work; 4-15x tokens. Use for multi-file changes only. Templates in `.claude/teams/` (Magento-flavoured; adapt file ownership to `web/modules/custom/<mod>/` + `config/sync/` + `tests/`). Team lead final verification: the suite and lint commands from `.claude/testing.md`.

## Toolchain (defaults; project `testing.md` overrides)

| Job | Command |
|---|---|
| Drush | `vendor/bin/drush <cmd>` (inside the container; `drush` on PATH is the same) |
| Cache rebuild | `drush cr` — after any PHP, YAML, Twig or hook change |
| Config | `drush cex` (export to `config/sync/`), `drush cim` (import), `drush config:status` (diff) — respect config_split if present |
| DB updates | `drush updb` (runs `hook_update_N` / post_update), `drush updatedb:status` |
| Logs | `drush watchdog:show --count=50` (dblog) |
| Tests, PHP | `vendor/bin/phpunit -c web/core <path> --filter <name>` (Unit/Kernel need no browser; Functional needs `SIMPLETEST_DB` + `SIMPLETEST_BASE_URL`) |
| Tests, e2e | Playwright per the project `testing.md` |
| Standards | `vendor/bin/phpcs --standard=Drupal,DrupalPractice <paths>` (needs `drupal/coder`) |
| Static analysis | `vendor/bin/phpstan analyse` (with `mglaman/phpstan-drupal` + deprecation rules) |
| Modernise | `vendor/bin/rector process --dry-run` with `palantirnet/drupal-rector` (pb-hcf `rector-check.sh` scopes to `web/modules/custom` + `web/themes/custom`) |
| Dep CVEs | `composer audit` (Drupal security advisories ship as composer advisories) |
| Debugger | `xdebug` MCP (xstep / xtrace / xback / xprofile) — see `php-debugging` rule |

If a tool above is not in `vendor/bin`, say so; do not install dev dependencies without asking. Run inside the DDEV container; never `ddev exec` from inside it.

## Coding Standards (fleet baseline)

- Drupal coding standards (`Drupal`, `DrupalPractice`); PSR-4 under `web/modules/custom/<mod>/src/`.
- Dependency injection everywhere a class exists: services in `<mod>.services.yml`, `create(ContainerInterface)` on controllers/forms/plugins. `\Drupal::service()` only in procedural `.module` code.
- Hooks thin, logic in services. OOP `#[Hook]` attributes only if the project is on Drupal 11.1+ and already uses them.
- Every route declares access (`_permission` / `_entity_access` / `_custom_access`; `_csrf_token: 'TRUE'` on state-changing GET). Entity queries call `->accessCheck()` explicitly.
- Render arrays + Twig; `#plain_text` for user text; never `|raw` / `Markup::create()` on user data. Strings through `t()` with `@` / `%` placeholders.
- Cacheability metadata on everything rendered (`#cache` tags/contexts/max-age; `AccessResult` cacheability).
- Schema/data changes via `hook_update_N()` / `hook_post_update_NAME()`; never edit a released update hook.
- Config changes always exported (`drush cex`) and committed with the code that needs them; never hand-edit UUIDs; secrets live in `settings.php` / env, never in `config/sync/`.
- No echo-debugging (`var_dump`, `print_r`, `dpm`, `kint`, `dump`) — guarded by `php-debug-guard`.
- Contrib patches via `cweagans/composer-patches` in `composer.json` + `patches/`, never edits under `web/modules/contrib` or `web/core`.

## Runtime errors

Ask Bugsink before grepping logs if the project is wired to it (`.claude/bugsink.md`), else `drush watchdog:show` (see `investigation` rule). Never SSH to uat/live for logs unless the project CLAUDE.md says that is the only path, and then read-only.

## Playwright (DDEV)

**DNS bug:** `<project>.ddev.site` can resolve to 127.0.0.1 instead of the ddev-router IP. Fix with `ddev fix-dns` or /etc/hosts. Verify: `getent hosts <project>.ddev.site` returns 172.x.x.x.

## Git Workflow

- Before switching branches: check for uncommitted changes; stop and ask if any exist. Feature/bug work branches from `live`.
- After switching to a working branch, merge current `live` into it.
- We NEVER push feature branches to origin. Merge locally, push `live` (or `uat` where the project has one).
- Single developer; no GitHub PR flow.
- Deploy trigger is per project — read the project CLAUDE.md. A push to a deploy branch may deploy.
- Feature branches: `feature/<ticket>_<scope_keywords>` (short).

## Deployment & Git Safety (cardinal rules)

- **NEVER push, deploy, or merge without explicit user authorization in the current turn.** Earlier "continue/yes/go" does NOT authorize the NEXT push.
- **NEVER edit live/production directly** via SSH or any other path. SSH to live is read-only for investigation.
- **NEVER push to `live` or `uat` autonomously.** Pushes go through the `/deploy-check` skill.
- **NEVER `git push --force`** without explicit typed confirmation.
- **NEVER run `drush cim`, `drush updb`, `drush sql:*` or `drush php:*` against a remote alias** (`@live`, `@uat`, `@prod`). Drush aliases are local-only for agents.
- Tests + diff review MUST complete before any push.

## Environment Context (host vs DDEV container)

Before any task involving config files, MCP setup, mount permissions, or host paths — declare and verify your execution context:

- Run `hostname && pwd && ls /var/www/html 2>/dev/null && echo "HOME=$HOME"` and state whether you're in the host shell OR the DDEV web container.
- RO mounts inside the container: `/var/www/html/.claude/{settings.json,agents,rules,hooks,scripts,teams,plugins-seed}` and `~/.claude/{CLAUDE.md,mcp.json}`. Edits there fail; ask the user to edit from the host (sources live in `~/claude-skills-central/profiles/drupal/` and `~/claude-code-drupal-agents/`).
- Host paths (`~/workspace/...`) are not visible in the container.

## Tool Selection

- No code-graph MCP for Drupal. Use the LSP tool / phpstan, then Grep/Read (`*.services.yml`, `*.routing.yml`, `*.module` are where wiring lives).
- Library docs: Context7 first (Drupal core, Symfony, contrib).
- Knowledge: Graphiti, scoped `[<project>, fleet]`.

## Database

`database` MCP (read-only) or `drush sql:query` / `mysql` against the local DDEV DB. Dev DB scale is not prod scale — see the `core-triggers` rule before reasoning from row counts. Never write to a prod DB.

## New tasks while existing task are being executed with todo lists

- Do not immediately pivot to the new task unless marked urgent.
- Add the new task to the todo list and show the list.
- At the end of the current ask, work the todo list without stopping to ask. First on, first off.
