# Fleet Tooling Recovery Runbook

Purpose: restore the full Claude/AI dev tooling on a fresh machine after HD crash.
Audience: Lucas or any AI session. Keep this file current — it lives in
`ProxiBlue/claude-skills-central` (private), so the map survives with the territory.
Last verified: 2026-08-02.

## What is backed up where (all private, github.com/ProxiBlue)

| Repo | Restores to | Contents |
|---|---|---|
| `dotfiles` | `~/` | shell/git config, host crontab snapshot |
| `claude-skills-central` | `~/claude-skills-central` | fleet rules (8× mounted via ~/.claude/CLAUDE.md), guard hooks, scripts (statusline, backup, gh-comment), teams, mcps/.mcp.json, container settings.json template, THIS FILE |
| `claude-plugins-central` | `~/claude-plugins-central` | seed marketplaces layer (pb-hcf-playwright-tdd, proxiblue-skills manifest, hyva-ai-tools, builder-skills manifest, known_marketplaces, WORKFLOW.md) |
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

- **Graphiti Neo4j data** — the knowledge graph DB. **Backup DEPLOYED + restore
  TESTED 2026-08-02.** Nightly dump (`monitor all-backup`, 02:30) →
  `~/backups/graphiti/graphiti-<date>.dump` (~308M). Off-site copy is encrypted
  and pushed to Backblaze B2 — see "Off-site backups" + "Graphiti restore" below.
  On total loss with no dump, re-ingest via pb-graphiti ingestion skills.
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

## Off-site backups (Backblaze B2, encrypted) — LIVE + VERIFIED 2026-08-02

The nightly Graphiti dumps live on the same disk as the data, so on their own
they do NOT survive an HD crash. `scripts/backup-offsite.sh` (chained after the
dump in `monitor all-backup`) encrypts the latest dump locally with openssl
AES-256 and pushes the ciphertext to Backblaze B2 via rclone. Local encryption
means the client data is opaque at rest on the provider's servers.

**History:** Icedrive was the original target, abandoned 2026-08-02 — Icedrive
DISCONTINUED WebDAV (disabled for new users 2026-04-15, sunset for existing),
and it has no public API, so no headless path remains. B2 uses a native rclone
backend over plain HTTPS — reliable, ~cents/month for this data volume.

**To enable (one-time):**
1. Backblaze → B2 Cloud Storage → create a PRIVATE bucket (e.g.
   `proxiblue-backups`). App Keys → Add a New Application Key scoped to that
   bucket → note the **keyID** and **applicationKey** (applicationKey shows once).
2. `~/.local/bin/rclone config create b2 b2 account=<keyID> key=<applicationKey>`
   Test: `rclone lsd b2:` then `rclone mkdir b2:dev-env/graphiti`.
3. `~/.config/graphiti-offsite.env` (template: `host/graphiti-offsite.env.example`):
   `RCLONE_REMOTE="b2:dev-env/graphiti"` and `OFFSITE_RETENTION=14`.
4. **CRITICAL:** copy `~/.config/graphiti-offsite-passphrase` into the password
   manager NOW. If the only copy is on the disk that crashes, every off-site
   backup is permanently undecryptable. This passphrase is the single point of
   failure for the whole off-site strategy.
5. Test: `monitor graphiti-offsite` → should encrypt + push one dump.

**Restore from off-site:** `rclone copy b2:dev-env/graphiti/<file>.dump.enc .`
then `openssl enc -d -aes-256-cbc -pbkdf2 -in <file>.dump.enc -out neo4j.dump -pass file:<passphrase>`
then follow "Graphiti restore" below.

## Graphiti restore (TESTED 2026-08-02)

Restore a dump into Neo4j. **Gotcha that cost real time in testing:** the
directory holding the dump must be world-traversable (`chmod 755`) or the
container's neo4j user gets `AccessDeniedException: /dumps`.

```bash
DUMP=~/backups/graphiti/graphiti-<date>.dump      # or decrypted off-site .dump
IMG=$(docker inspect graphiti-neo4j --format '{{.Config.Image}}')  # neo4j:5.26.0
WORK=$(mktemp -d); cp "$DUMP" "$WORK/neo4j.dump"; chmod 755 "$WORK"; chmod 644 "$WORK/neo4j.dump"
docker stop graphiti-neo4j                          # offline load; skip if restoring to a NEW volume
docker run --rm -v "$WORK:/dumps:ro" -v graphiti-fleet_neo4j_data:/data "$IMG" \
  neo4j-admin database load neo4j --from-path=/dumps --overwrite-destination=true
docker start graphiti-neo4j
# verify: MATCH (n) RETURN count(n)  — was ~9950 on 2026-08-02
rm -rf "$WORK"
```

Verified end-to-end 2026-08-02: latest dump loaded into a throwaway volume,
9953 nodes, real content present.

## Known-good state reference (2026-07-31)

- HCF v2.0.0 project-scope in pps; pb-hcf 0.4.9 enabled; 10 agents enrolled via
  `~/claude-code-magento-agents` RO mount; legacy code-graph plugin removed.
- pps gates: captainhook pre-commit (uat-merge-guard) + pre-push (Uptactics unit
  suite, `--stop-on-failure app/code/Uptactics/*/Test/Unit` + pre-push-check.sh).
- Claude-level guards (container): push-guard, merge-guard, pre-commit-audit,
  fable-reminder — via skills-central settings.json RO-mounted to `/var/www/html/.claude/settings.json`.
- Bugsink: pps project id 1; issue-sentinel agent planned (pb-hcf v0.5.0, task list).
