# Fleet Tooling — Complete-Loss Recovery Spec

**Purpose:** after total loss (dead disk, stolen laptop, new box), rebuild the
machine to a working state: **functional DDEV client dev-environments, ready to
code, with the full AI tooling installed and wired.** Phases 0–5 restore the
host + AI tooling + knowledge-graph data; **Phase 6 rebuilds the client dev
environments themselves — that is the end goal.** Follow the phases in order.
**Audience:** Lucas, or any AI session driving the rebuild.
**This file lives in `ProxiBlue/claude-skills-central` (private GitHub)** — so the
map survives with the territory. **Last verified: 2026-08-02. Reconciled against
live state 2026-08-07** (pb-hcf agent-enrollment architecture, wires.json
recovery behaviour, in-scope project list — see notes marked 2026-08-07 below).

> The one thing this spec CANNOT recover for you: the AES passphrase that
> decrypts the off-site Graphiti backups (`~/.config/graphiti-offsite-passphrase`).
> It must already be in your password manager. If it is not, the B2 backups are
> undecryptable and the knowledge graph is only recoverable by full re-ingest.
> **Check your password manager has it NOW, while the machine still works.**

---

## Phase 0 — Prerequisites (bare OS → tooling-ready)

Install on the fresh machine:

- **OS:** Ubuntu 24.04 LTS (or equivalent). Desktop if you want the GUI editors + desktop alerts.
- **Docker** + **docker compose** + (for GPU, if ever re-enabled) nvidia-container-toolkit.
- **DDEV** (ddev.com install script).
- **Node** (v22.x — matches v22.23.2) via nvm or nodesolid; needed for claude-code + rclone-independent tooling.
- **CLI tools:** `git gh jq openssl curl python3 docker.io` — plus `xmllint` (libxml2-utils), `n98-magerun2` (Magento projects).
- **rclone** (user-local): `curl -sSL https://downloads.rclone.org/rclone-current-linux-amd64.zip -o /tmp/r.zip && unzip -o /tmp/r.zip -d /tmp && cp /tmp/rclone-*/rclone ~/.local/bin/ && chmod +x ~/.local/bin/rclone`
- **claude-code, pinned:** native installer, not npm — `claude install <version>` (or the install script if `claude` itself isn't present yet: `curl -fsSL https://claude.ai/install.sh | bash -s <version>`). Read `host/pin-decision.json`'s `fleet_target` for the version to install; do NOT take latest — behaviour changes between versions break tuned config. Installs land in `~/.local/share/claude/versions/<version>/`, symlinked from `~/.local/bin/claude` — prior versions stay on disk, so rolling back is `ln -sf ~/.local/share/claude/versions/<prior-version> ~/.local/bin/claude`.

---

## Phase 1 — Secrets & accounts (restore from password manager)

None of these are in git. Restore each from your password manager / provider.
**This is the phase that gates everything else.**

| Secret / account | Restores | Where it goes |
|---|---|---|
| **`~/.ssh` private keys** | git push/pull, server access | `~/.ssh/` (chmod 600) |
| **`GH_TOKEN`** | GitHub API (gh CLI) | shell env / `~/.bashrc` |
| **graphiti-offsite passphrase** ⚠ | **decrypts the B2 Graphiti backups** | `~/.config/graphiti-offsite-passphrase` (chmod 600) |
| **Backblaze B2 keyID + applicationKey** | pull backups from B2 | rclone `b2` remote (Phase 4) |
| **`RESEND_API_KEY`** | monitor email alerts + booking-agent email | ai_assistant `.env` + read live by monitor |
| **Anthropic API key** | Graphiti entity extraction (Haiku 4.5) | graphiti-mcp container env / infra `.env` |
| **Voyage API key** | Graphiti embedder (voyage-4-lite) | graphiti infra `.env` |
| **`NEO4J_AUTH`** (user/pass) | Graphiti DB | graphiti infra `.env` |
| **IMAP creds** (host/user/pass) | email-ingest crons | `~/.pb-graphiti/env-<project>` |
| **Bugsink** (`~/.bugsink-secret`, `~/.pb-hcf/bugsink.env`) | error tracking | re-mint per pb-hcf `services/bugsink/README.md` |
| **Per-project crypt keys** (`app/etc/env.php`) | decrypt live-DB encrypted values after a DB pull | pull env.php from live, or keep each project's crypt key in the password manager (see Phase 6) |

If a secret is missing from the password manager, its subsystem stays down but
the rest recovers — EXCEPT the graphiti passphrase, which is unrecoverable.

---

## Phase 2 — Clone the git repos

All private, `github.com/ProxiBlue`. Continuous backup pushes these nightly
(`scripts/tooling-backup-push.sh`, cron `30 20 * * *`). Clone each to its path:

| Repo | Clones to |
|---|---|
| `dotfiles` | `~/` (apply per its README — shell/git config, **host crontab snapshot**) |
| `claude-skills-central` | `~/claude-skills-central` (rules, hooks, scripts, teams, host/ config, THIS FILE) |
| `claude-plugins-central` | `~/claude-plugins-central` (seed marketplaces layer) |
| `pb-hcf` | `~/claude-plugins-central/seed/marketplaces/pb-hcf` |
| `pb-graphiti` | `~/claude-plugins-central/seed/marketplaces/pb-graphiti` |
| `pb-chatroom` | `~/claude-plugins-central/seed/marketplaces/pb-chatroom` |
| `pb-codegraph` | `~/claude-plugins-central/seed/marketplaces/pb-codegraph` |
| `claude-skills` | `~/claude-plugins-central/seed/marketplaces/proxiblue-skills/skills` |
| `claude-code-magento-agents` | `~/claude-code-magento-agents` (HCF enrolled agents; upstream = rubenzantingh) |
| `claude-host-memory` | `~/.claude/projects/-home-lucas/memory` (flat-file auto-memory) |

Then recreate the skills symlink:
`ln -s ~/claude-plugins-central/seed/marketplaces/proxiblue-skills/skills ~/claude-skills-central/skills`

Each ddev **project** is its own git repo with its own remote (uptactics/*,
ittools/*, proxiblue/*) — clone them to `~/workspace/...` as needed.

**Not every plugin under `seed/marketplaces/` is a separate clone (2026-08-07).**
`pb-hcf`, `pb-graphiti`, `pb-chatroom`, `pb-codegraph`, and `proxiblue-skills/skills`
have their own `.git` + remote (listed in the table above) — clone each
independently. `hcf`, `hcf-xhgui`, `hyva-ai-tools`, and `pb-hcf-playwright-tdd`
have **no independent `.git`** — they're plain files tracked as part of
`claude-plugins-central`'s own history, so cloning `claude-plugins-central`
recovers them automatically, but ONLY as of whatever was last committed+pushed
there. Before relying on this doc, `cd ~/claude-plugins-central && git status
--short` — if any of those 4 dirs show dirty, commit+push first or the working
copy is what's actually at risk, not what git thinks is safe. (`hcf` also
exists as a real independent clone at `~/claude-plugins-central/hcf`
— `github.com/markshust/hcf`, upstream, read-only — the `seed/marketplaces/hcf`
copy is a manually-synced mirror of it, not the source of truth.)

**pb-hcf's agent-enrollment architecture, and why 2 places matter (2026-08-07).**
Bundled agents in `pb-hcf/agents/*.md` ship **dormant** — no `phase` key, by
design (mirrors how HCF ships `standards-enforcer` commented out). HCF's own
hook-discovery never globs a *different* plugin's `agents/` dir directly — it
only globs `.claude/agents/*.md` in the current project (which for fleet
Magento projects resolves via a `:ro` docker-compose bind-mount to
`~/claude-code-magento-agents`) plus whichever plugin's *own* skill is
currently running. So a pb-hcf agent is invisible to HCF until it's physically
copied into `~/claude-code-magento-agents` **with** `phase`/`order`/`mode`
stamped in — that's what `/pb-hcf:wire --enable=<name>` does. Recovering
`pb-hcf`'s repo alone does NOT re-enroll anything; recovering
`claude-code-magento-agents`'s repo restores whatever was enrolled as of its
last push (it's a normal git repo, Phase 2 table already covers it) — anything
committed-but-not-pushed there is lost same as any other uncommitted work.
**Live flag, will go stale:** as of 2026-08-07, `claude-code-magento-agents`
has 1 local commit (`1807a70`, enrolling `post-plan-playwright-bucket-split` +
`pre-batch-playwright-floor-guard`) not yet pushed — push it before treating
that enrollment as recovered.

**`.claude/wires.json` is gitignored per-project, every project — it is NOT
backed up and should not be.** It's `/pb-hcf:wire`'s own state cache; after any
rebuild, re-run `/pb-hcf:wire --enable=<name>[,<name>]` (or `--enable-all`) per
project to regenerate it rather than trying to restore a copy.

---

## Phase 3 — Host configuration

**3a. Symlink host Claude config into the repo** (source of truth is `host/`):
```bash
ln -sf ~/claude-skills-central/host/CLAUDE.md    ~/.claude/CLAUDE.md
ln -sf ~/claude-skills-central/host/settings.json ~/.claude/settings.json
```

**3b. Recreate non-git host config files** (secrets from Phase 1):
- `~/.config/graphiti-offsite-passphrase` — from password manager (chmod 600). **Critical.**
- `~/.config/graphiti-offsite.env` — `RCLONE_REMOTE="b2:dev-env/graphiti"` + `OFFSITE_RETENTION=14` (template: `host/graphiti-offsite.env.example`).
- `~/.config/monitor-notify.env` — sources `RESEND_API_KEY` from ai_assistant `.env`; `NOTIFY_EMAIL_TO` + `RESEND_FROM_EMAIL` (template: `host/monitor-notify.env.example`).
- `~/.config/project-reminders.tsv` — backburner reminders (recreate or restore from dotfiles).
- `~/.pb-graphiti/env-<project>` — IMAP ingest creds (Phase 1).

**3c. Restore the host crontab** (from the dotfiles snapshot). The full schedule:
```
30 20 * * *  tooling-backup-push.sh              # nightly repo backup
30 2  * * *  monitor.sh all-backup               # graphiti dump + encrypt + B2 push
40 5  * * *  monitor.sh all-daily                # harness-watch, pin-age, dashboard
30 6  * * 1  monitor.sh all-weekly               # drift, usage telemetry
0  5  1 * *  monitor.sh evals                     # monthly rule-evals
0  8,14,20 * * *  monitor.sh health --notify      # dead-collector alerts
0  9  * * 1  project-reminders.sh                 # weekly backburner nudges
0  2  * * *  ingest-email.sh (lcd-mageos)         # graphiti email ingest
20 2  * * *  ingest-email.sh (pvcpipesupplies)    # graphiti email ingest
# plus chatroom (host-broadcast/tick/digest/prune), git-lock-reaper, ddev-claude-upgrade
```

---

## Phase 4 — Host services (Docker) + restore the data

**4a. Graphiti** (Neo4j + MCP + log viewer):
```bash
cd ~/claude-plugins-central/seed/marketplaces/pb-graphiti
docker compose -f docker-compose.yml up -d      # Neo4j :7474/:7687, MCP :8765
```
Provider is cloud Anthropic Haiku (config.yaml `provider: anthropic`) — NOT local
Ollama (that was abandoned; GPU instability). Needs the Anthropic + Voyage + NEO4J_AUTH
secrets from Phase 1.

**4b. RESTORE the knowledge graph from B2** (the actual data recovery):
```bash
# configure the b2 remote (keyID + applicationKey from Phase 1)
~/.local/bin/rclone config create b2 b2 account=<keyID> key=<applicationKey>
# pull the newest encrypted dump
LATEST=$(~/.local/bin/rclone lsf b2:dev-env/graphiti/ | grep '\.dump\.enc$' | sort | tail -1)
~/.local/bin/rclone copy "b2:dev-env/graphiti/$LATEST" /tmp/restore/
# decrypt (passphrase from Phase 1)
openssl enc -d -aes-256-cbc -pbkdf2 -in "/tmp/restore/$LATEST" \
  -out /tmp/restore/neo4j.dump -pass file:~/.config/graphiti-offsite-passphrase
# load into Neo4j (see "Graphiti restore" below for the chmod-755 gotcha)
```
Then follow the **Graphiti restore** block below to load `neo4j.dump`.

**4c. Chatroom:** `docker compose` in `pb-chatroom/` (server :7477, MCP). Thread
history (SQLite) is acceptable loss — starts empty.

**4d. Bugsink:** `pb-hcf/services/bugsink/` compose (:7788). README covers secret,
superuser, per-project DSN minting, API token. Dev-error data is acceptable loss.

---

## Phase 5 — Verify off-site backup + alerting are live again

```bash
monitor.sh graphiti-offsite   # should encrypt + push a fresh dump to B2, exit 0
monitor.sh health             # all collectors "ok"
monitor.sh test-alert critical # confirm desktop popup + email arrive
```

---

## Phase 6 — Rebuild the DDEV client environments (ready to code)

**This is the actual goal of environment recovery.** A Magento dev environment
splits into three buckets — only two need recovering, the third rebuilds:

| Bucket | Source on recovery |
|---|---|
| **Code** (app/code, `.ddev/`, composer.json) | git — each project's own remote |
| **Canonical data** (database, `pub/media`, `app/etc/env.php`) | pull from the **LIVE server** (production is source of truth) |
| **Derived** (OpenSearch/ElasticSuite index, Redis, Varnish, `generated/`, `pub/static`, `vendor/`) | **rebuilt** — never backed up |

Do NOT back up OpenSearch, Redis, Varnish, generated code, static, or vendor —
they regenerate from code + DB. The only things not in git and not rebuildable
are the **DB**, **pub/media**, and **`app/etc/env.php`** (gitignored — holds the
**crypt key**; a mismatched key breaks encrypted DB values, so pull env.php from
live or keep its crypt key in the password manager).

### Per-project "ready to code" sequence

```bash
cd ~/workspace/<project>            # clone from its git remote first if needed
ddev start                          # builds containers + runs .ddev build hooks:
                                    # pinned claude-code@2.1.201, playwright, chrome,
                                    # gh, and the RO mounts of skills-central + plugins

# 1. env.php — restore from live / secure backup (CRYPT KEY must match the DB you load)
#    scp/pull app/etc/env.php from live, or ddev import a saved copy.

# 2. Database — pull from live (canonical), then import
ddev import-db --file=<dump-from-live>.sql.gz        # or a configured `ddev pull <provider>`

# 3. Media (optional — only needed to render images, not to code)
./sync_missing_images.sh            # or pull pub/media from live

# 4. Dependencies + build (regenerates ALL derived data)
ddev composer install               # rebuilds vendor/
ddev exec composer build-dev        # setup:upgrade + cache clear
ddev exec bin/magento setup:di:compile
ddev exec bin/magento indexer:reindex   # REBUILDS OpenSearch/ElasticSuite index
ddev exec bin/magento setup:static-content:deploy -f
# (Tailwind/Hyva projects also: composer build-tailwind / build-front)

# 5. AI tooling wire-up (the .ddev mounts are already restored by ddev start)
ddev exec vendor/bin/captainhook install -f
# in-container: run `claude` once to trust workspace; `/pb-hcf:wire` to verify probes
ddev exec composer require --dev inchoo/magento-bricklayer   # where wired (.claude/wires.json)
```

In-scope projects that need the AI tooling: **pvcpipesupplies, lcd-mageos,
webhooks, ntotankM1** (see `host/tooling-scope.txt` — authoritative; this line
drifted out of sync with it before 2026-08-07, corrected here). Others are out
of scope for the guards but still recover their dev environment via the same
sequence. Note: several more projects (`ntotank`, `pvcpipesupplies-loki`,
`ai_assistant`, `billing`, `PdfToVec`, `ddev_project_template`, `ahhgg`,
`ihop`, `tracker`) carry the `docker-compose.ai.mounts.yaml` RO-mount
infrastructure without being in `tooling-scope.txt` — per that file's own
comment, that's expected (mount present ≠ in scope for drift/guard telemetry),
not something to "fix" by adding them all.

**Bottom line for client envs:** git gives you the code, the live server gives you
the data, and one build sequence regenerates everything else. The only thing you
must independently preserve off-machine is each project's **crypt key** (in
`app/etc/env.php`) — everything else is either in git or on live.

---

## Phase 7 — Final verification checklist

- [ ] Session in pps → SessionStart shows graphiti recall + chatroom inbox.
- [ ] `git commit` in a project fires captainhook gates.
- [ ] Claude-level guards fire (try a bare `gh issue comment` → blocked).
- [ ] `monitor health` all green; dashboard renders at `~/monitor/dashboard.html`.
- [ ] `rule-evals.sh` → 8/8 on 2.1.201.
- [ ] `monitor graphiti-offsite` pushes to B2; a test download decrypts byte-identical.
- [ ] Knowledge graph node count roughly matches pre-loss (~9,950 on 2026-08-02).

---

## Off-site backups (Backblaze B2, encrypted) — LIVE + VERIFIED 2026-08-02

The nightly Graphiti dumps live on the same disk as the data, so alone they do
NOT survive an HD crash. `scripts/backup-offsite.sh` (chained after the dump in
`monitor all-backup`) encrypts the latest dump locally with openssl AES-256 and
pushes the ciphertext to Backblaze B2 (bucket `dev-env`) via rclone. Local
encryption means the client data is opaque at rest on the provider's servers.

**History:** Icedrive was the original target, abandoned 2026-08-02 — Icedrive
DISCONTINUED WebDAV (disabled for new users 2026-04-15, sunset for existing) with
no public API, so no headless path remains. B2 uses a native rclone backend over
plain HTTPS. Full round-trip (encrypt → push → download → decrypt → byte-identical)
was verified 2026-08-02.

**Restore from off-site:** see Phase 4b, then the Graphiti restore block below.

---

## Graphiti restore (TESTED 2026-08-02)

Load a dump into Neo4j. **Gotcha that cost real time in testing:** the directory
holding the dump must be world-traversable (`chmod 755`) or the container's neo4j
user gets `AccessDeniedException: /dumps`.

```bash
DUMP=~/backups/graphiti/graphiti-<date>.dump      # or the decrypted off-site .dump
IMG=$(docker inspect graphiti-neo4j --format '{{.Config.Image}}')  # neo4j:5.26.0
WORK=$(mktemp -d); cp "$DUMP" "$WORK/neo4j.dump"; chmod 755 "$WORK"; chmod 644 "$WORK/neo4j.dump"
docker stop graphiti-neo4j                          # offline load; skip if restoring to a NEW volume
docker run --rm -v "$WORK:/dumps:ro" -v graphiti-fleet_neo4j_data:/data "$IMG" \
  neo4j-admin database load neo4j --from-path=/dumps --overwrite-destination=true
docker start graphiti-neo4j
# verify: MATCH (n) RETURN count(n)  — was ~9950 on 2026-08-02
rm -rf "$WORK"
```

Verified end-to-end 2026-08-02: dump loaded into a throwaway volume, 9953 nodes,
real content present.

---

## Known-good state reference (2026-08-02)

- claude-code pinned **2.1.201** fleet-wide (`host/pin-decision.json`); host + 3
  in-scope containers aligned; auto-update off.
- Graphiti extraction on cloud Anthropic Haiku 4.5 (local Ollama abandoned — GPU instability).
- HCF v2 project-scope; pb-hcf agents enrolled via `~/claude-code-magento-agents` RO mount.
- Guards live host + container: merge-guard, push-guard, pre-commit-audit,
  gh-comment-guard, php-debug-guard, test-gate, test-evidence, test-failure-context.
- Telemetry: fleet-drift + usage + rule-evals + dashboard, all behind `monitor` dispatcher with heartbeats.
- Off-site: encrypted nightly to B2 bucket `dev-env`, restore verified.
