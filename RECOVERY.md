# Fleet Tooling Recovery Runbook

Purpose: restore the full Claude/AI dev tooling on a fresh machine after HD crash.
Audience: Lucas or any AI session. Keep this file current — it lives in
`ProxiBlue/claude-skills-central` (private), so the map survives with the territory.
Last verified: 2026-07-31.

## What is backed up where (all private, github.com/ProxiBlue)

| Repo | Restores to | Contents |
|---|---|---|
| `dotfiles` | `~/` | shell/git config, host crontab snapshot |
| `claude-skills-central` | `~/claude-skills-central` | fleet rules (8× mounted via ~/.claude/CLAUDE.md), guard hooks, scripts (statusline, backup, gh-comment), teams, mcps/.mcp.json, container settings.json template, THIS FILE |
| `claude-plugins-central` | `~/claude-plugins-central` | seed marketplaces layer (pb-gitnexus, pb-hcf-playwright-tdd, proxiblue-skills manifest, hyva-ai-tools, builder-skills manifest, known_marketplaces, WORKFLOW.md) |
| `pb-hcf` | `seed/marketplaces/pb-hcf` | HCF v2 integration: 10 agents, wire skill, playbook templates, captainhook template, **Bugsink compose** (`services/bugsink/`) |
| `pb-graphiti` | `seed/marketplaces/pb-graphiti` | Graphiti MCP + docker-compose (Neo4j+MCP), ingestion skills, cron scripts |
| `pb-chatroom` | `seed/marketplaces/pb-chatroom` | chatroom server+MCP source, ddev-cron executor recipe |
| `pb-codegraph` | `seed/marketplaces/pb-codegraph` | impact-check plugin |
| `claude-skills` | `seed/marketplaces/proxiblue-skills/skills` | the ~35-skill library (symlinked as `~/claude-skills-central/skills`) |
| `claude-code-magento-agents` | `~/claude-code-magento-agents` | pb-hcf enrolled agents (phase-stamped) + Magento agent library; upstream = rubenzantingh remote |
| `claude-host-memory` | `~/.claude/projects/-home-lucas/memory` | flat-file auto-memory (MEMORY.md index + facts) |

Continuous protection: `~/claude-skills-central/scripts/tooling-backup-push.sh`,
host cron `30 20 * * *`, log `~/monitor/tooling-backup.log`. If a repo is added to
the tooling, ADD IT to that script's REPOS list.

## NOT in git — needs manual recreation or separate backup

- **Graphiti Neo4j data** — the knowledge graph DB. Backup scripts written but
  NOT deployed (see memory `project_pb_graphiti_backup_todo`). Until fixed: crash
  = graph loss; re-ingest via pb-graphiti ingestion skills (tickets/email/sessions).
- **Bugsink data** — docker volume `bugsink_data`. Low value (dev errors); acceptable loss.
- **Chatroom SQLite** — thread history; acceptable loss.
- **Secrets:** `~/.bugsink-secret`, `~/.pb-hcf/bugsink.env` (Bugsink API token + DSN
  registry), `GH_TOKEN`, `~/.ssh`. Re-mint per pb-hcf `services/bugsink/README.md`;
  SSH/GH from password manager.
- **Project repos** — each ddev project is its own git repo with its own remote (uptactics/*, ittools/*).
- **`~/.claude/settings.json` (host)** — small; recreate from container template in
  skills-central (strip container paths) or from this checklist: statusLine → scripts/statusline-combined.sh,
  hooks: pre-commit-audit + merge-guard (PreToolUse), post-commit-wiki (PostToolUse),
  enabledPlugins: typescript-lsp, pb-graphiti, pb-chatroom, hcf.

## Restore order (fresh machine)

1. OS + docker + ddev + gh CLI; restore `~/.ssh` + GH_TOKEN from password manager.
2. `git clone git@github.com:ProxiBlue/dotfiles ~/dotfiles-tmp` → apply home files (its README).
3. Clone the four top-level dirs to their paths (table above). Inside
   `claude-plugins-central/seed/marketplaces/`, clone the 4 nested plugin repos +
   `claude-skills` into `proxiblue-skills/skills`; re-create symlink
   `~/claude-skills-central/skills → ../claude-plugins-central/seed/marketplaces/proxiblue-skills/skills`.
4. `~/.claude/CLAUDE.md`: 8 `@~/claude-skills-central/rules/*.md` mounts (copy from any project's mounted copy or git history).
5. Host services, in order:
   - Graphiti: `pb-graphiti/` compose (Neo4j :7474/:7687, MCP :8765). Restore DB backup if one exists; else re-ingest.
   - Chatroom: `pb-chatroom/server` (:7477).
   - Bugsink: `pb-hcf/services/bugsink/` compose (:7788) — README there covers secret,
     superuser, per-project DSN minting, API token.
6. Host crontab: from dotfiles snapshot + `30 20 * * *` tooling-backup-push + pb-graphiti ingest crons (see pb-graphiti README).
7. Per ddev project (config is in each project's repo — `.ddev/` mounts wire everything):
   `ddev start`, then in-container `claude` once to trust workspace,
   `/pb-hcf:wire` to verify probes, `vendor/bin/captainhook install -f`,
   `composer require --dev inchoo/magento-bricklayer` where wired (check `.claude/wires.json`).
8. Verify: session in pps → SessionStart shows graphiti recall + chatroom inbox;
   `git commit` fires captainhook; `/hcf:plan-create` blocked until `/model fable` (fable-reminder).

## Known-good state reference (2026-07-31)

- HCF v2.0.0 project-scope in pps; pb-hcf 0.4.9 enabled; 10 agents enrolled via
  `~/claude-code-magento-agents` RO mount; pb-gitnexus disabled (deprecated).
- pps gates: captainhook pre-commit (uat-merge-guard) + pre-push (Uptactics unit
  suite, `--stop-on-failure app/code/Uptactics/*/Test/Unit` + pre-push-check.sh).
- Claude-level guards (container): push-guard, merge-guard, pre-commit-audit,
  fable-reminder — via skills-central settings.json RO-mounted to `/var/www/html/.claude/settings.json`.
- Bugsink: pps project id 1; issue-sentinel agent planned (pb-hcf v0.5.0, task list).
