# claude-skills-central

Host-global Claude Code customization for Lucas's fleet — rules, hooks, scripts, agent teams, and a symlinked skills marketplace. Mounted into ddev projects via `.ddev/claude-code/` so every container sees the same baseline.

## Layout

| Dir | Purpose |
|---|---|
| `rules/` | `@`-mounted into `~/.claude/CLAUDE.md`. Always-loaded mandatory rules. |
| `hooks/` | Shell hooks wired via `~/.claude/settings.json` (PreToolUse / PostToolUse / SessionStart). |
| `scripts/` | Helper scripts called from hooks, status line, or skills. |
| `teams/` | Agent-team templates (audit, feature-development, security quorum, etc.). |
| `mcps/` | MCP server bundles (currently empty). |
| `skills/` | Symlink → `~/claude-plugins-central/seed/marketplaces/proxiblue-skills/skills`. |
| `Claude.md` | Magento 2 / Mage-OS project guide (mounted into wired Magento projects). |

## Features

### Rules (mounted via `~/.claude/CLAUDE.md`)

- **investigation.md** — mandatory failure-investigation protocol (read artefacts before hypothesising).
- **php-debugging.md** — mandatory xdebug-mcp usage instead of `var_dump`/echo debugging.
- **caveman.md** — default response register (terse, drop articles).
- **gh-ticket-comments.md** — ticket comments are caveman + minimized off-topic.
- **hcf-plan-orchestrate.md** — pb-hcf wire + native HCF orchestration (wrapper retired).
- **graphiti-usage.md** — discipline for writing to / reading from the shared knowledge graph.
- **codegraph-default.md** — codegraph-first tooling order.

### Hooks (wired in `~/.claude/settings.json`)

- **pre-commit-audit.sh** — PreToolUse / Bash gate.
- **post-commit-wiki-check.sh** — PostToolUse / Bash check.
- **push-guard.sh**, **tsc-edit-check.sh**, **install-context-mode.sh**, **sync-plugin-marketplaces.sh** — opt-in helpers, not currently wired globally.

### Scripts

- **statusline-combined.sh** + extras — render claude status line.
- **gh-comment-hidden.sh** — post + minimize a GitHub comment in one call.

### Teams

`audit-team`, `feature-development`, `issue-resolution`, `module-development`, `quorum-analysis-team`, `team_security`.

## Things to know

Non-obvious behaviour, gotchas, and operational facts. Add new entries at the top.

### Memory recall is dual-source (owned by pb-graphiti as of v0.12.7)

When the user says "recall last session" or asks what was remembered about X, BOTH sources are queried:

1. **Disk** — `~/.claude/projects/<sanitized-cwd>/memory/*.md` (project TODOs, feedback rules, user profile).
2. **Graphiti** — shared knowledge graph (consolidated session episodes, operational/procedural detail).

Neither is a superset. Disk skews "what to do next"; Graphiti skews "how the system works / what happened".

The policy + the SessionStart nudge live in the `pb-graphiti` plugin (`scripts/session_start_disk_memory_nudge.sh`) so they ship with the plugin install — no manual `@`-mount or settings.json hook needed. See `pb-graphiti/README.md` § "Dual-source recall policy".

Originally implemented locally here (rule file + dedicated hook) on 2026-06-25 then folded into pb-graphiti the same day for portability.

### Rules are `@`-mounted, not copied

`~/.claude/CLAUDE.md` references each rule file with `@~/claude-skills-central/rules/<name>.md`. Editing the rule here changes behaviour in every claude session immediately — no sync, no restart needed. The same files are also mounted RO into ddev containers via `.ddev/claude-code/.claude/CLAUDE.md`.

### `skills/` is a symlink into the plugin seed

`skills/` → `~/claude-plugins-central/seed/marketplaces/proxiblue-skills/skills`. Editing a skill here = editing the seed = publishing it to every ddev project on next container restart. There is no separate publish step.

### Caveman is the default response register

`rules/caveman.md` makes every response terse (no articles, fragments OK) unless the user says "stop caveman" or "normal mode". Code, commits, and PR bodies stay normal English.

### Investigation rule is unconditional

`rules/reference/investigation.md` mandates: `git diff --stat HEAD` + `git status` FIRST on any failure report, then read ALL artefacts, then form hypothesis. Skipping = banned. Phrases like "must be a flake" / "not my code" are explicitly banned until evidence cited.

## Conventions for adding new features

1. **New rule** — add `.md` to `rules/`, then `@`-mount in `~/.claude/CLAUDE.md`. Add a one-liner to the Rules section above.
2. **New hook** — add to `hooks/` or `scripts/`, wire via `~/.claude/settings.json` (use the `update-config` skill if unsure). Add an entry to Hooks section AND a Things-to-know paragraph if behaviour is non-obvious.
3. **New team template** — add `.md` to `teams/`. Reference from `Claude.md` if it's a Magento default.

When in doubt about whether something is obvious from the code itself, add a Things-to-know entry. Future you (or another session) reads this README cold.
