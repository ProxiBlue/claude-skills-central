# Component Registry — experiment vs load-bearing

Every AI-tooling component gets a tier. **Load-bearing** = client-facing path
depends on it → must pass the ops checklist. **Experiment** = free to churn,
break, or die; NOT allowed in a client-facing path until promoted.

Origin: 2026-07-31 tooling review rec #2. Promotion = move the row up AND tick
the checklist. Drift check: `scripts/fleet-inventory.sh` (weekly cron, Mon
06:30, alerts via chatroom). Behaviour check: `scripts/rule-evals.sh` — 8
compliance probes vs the live setup (rec #3, Phases A+B, 8/8 on 2.1.201);
MANDATORY before any pin move and after any rule/hook edit. Real-usage
telemetry: `scripts/usage_telemetry.py` (weekly Mon 06:45) — guard-fire +
banned-phrase counts from real transcripts; reuses pb-graphiti
iter_sessions for discovery. Three-layer measurement (config drift /
synthetic behaviour / real usage) closes review rec #4.

## Ops checklist (every load-bearing row)

1. **Wired everywhere it claims** — verified by fleet-inventory sweep
2. **Version-aligned** — one version fleet-wide, or documented per-project pin
3. **Minimally tested** — synthetic suite AND live-fired on the real harness
   (2026-08-01 lesson: synthetics validated a wrong payload assumption; the
   live-fire caught it in minutes)
4. **Kill switch documented** — env var / config off / unwire, written down
5. **Payload/behaviour re-verified on every harness version bump**

## Load-bearing

| Component | What breaks if it breaks | Checklist state (2026-08-01) |
|---|---|---|
| claude-skills-central: rules/ + core-triggers | agent behaviour fleet-wide | wired ✓ (mount) · aligned ✓ · live-verified ✓ (/context pps) · kill: edit include/paths |
| hooks: merge-guard, push-guard | branch topology on client repos | wired host+fleet ✓ · tested (in service since 2026-07) · kill: CLAUDE_*_ALLOWED=1 |
| hooks: test-gate + test-evidence | commit/push without tests | wired ✓ · synthetic 40/40 + live-fired ✓ (2026-08-01, found+fixed payload bug) · kill: 3 documented · **pending: first real-Magento fire; 3 running containers stale until restart** |
| hooks: gh-comment-guard, php-debug-guard | client-facing comment style; diff pollution | wired ✓ · synthetic+in-session fire ✓ · kill: rules-disable |
| ~/claude-code-magento-agents | HCF review pipeline (10 phase-enrolled agents, 13 projects) | wired ✓ · git clean ✓ · NOT covered by inventory sweep until 2026-08-01 — now tracked |
| pb-graphiti plugin + Graphiti infra (Neo4j, Ollama, Voyage) | fleet memory, session recall | wired ✓ · **backup scripts uncommitted (known TODO)** — checklist FAIL until landed |
| HCF (upstream) + pb-hcf wire | plan orchestration | **version split-brain; 2 legacy pipeline.md; 4 projects unwired — phase-2 target** |
| pb-chatroom protocol + cron executors | autonomous PRs to client repos | wired pps+lcd · kill switches documented in ddev-cron-executor.md |
| gh-comment-hidden.sh | ticket-comment mandate | wired ✓ (hook now forces it) |
| xdebug-mcp | runtime debugging discipline | seeded per project · verify per-project on phase-2 visit |
| .ddev ai-mounts pattern + settings.json file-mount | everything above reaching containers | **file-mount inode fragility — settings edits need ddev restart; 3 stale now.** Consider dir-mounting a conf dir instead (phase-2 decision) |
| claude-code pin | harness behaviour stability | **Fleet target: 2.1.198** (decided 2026-08-01 — the version the hooks/rules stack is live-verified against). lcd aligned; remaining 152/109 refs align during each project's phase-2 visit. Re-eval trigger for future bumps: payload probe + /context check + rule-eval BEFORE moving the pin (recipe in hooks/TEST-GATE.md + graphiti host facts) |
| host ~/.claude/CLAUDE.md + settings.json | host agent behaviour | **FAIL: outside any git.** Fix: symlink into this repo or sync script — pick in phase 2 |

## Experiment (churn freely — keep OUT of client-facing paths)

| Component | State |
|---|---|
| pb-codegraph v0.2 (MIT engine + augmenter port) | direction locked 2026-07-31, in build — replaces retired GitNexus pipeline |
| statusline-* scripts, screen→tmux swap | cosmetic; tmux swap still untested by Lucas |
| hcf-xhgui | planned only |
| pb-graphiti folder-ingest defaults v0.13.0 | deferred behind 3090 benchmark |
| ralph-wiggum, context-mode, bricklayer, context-please MCPs | in-container conveniences; unaudited |
| test-failure-context.sh injection | scope-limited by harness (exit-0-only) — masked-failure net, not primary teaching |
| GPU crash monitor, morning digests | host ops conveniences |

## Promotion procedure

Experiment → load-bearing: add row above WITH all 5 checklist items evidenced,
in the same commit that wires it into any client-facing path. No evidence, no
promotion — "40/40 synthetic" alone does not satisfy item 3.
