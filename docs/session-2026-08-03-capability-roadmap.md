# Session 2026-08-02/03 — Agent Capability Roadmap delivered (AP-1..6)

One session closed the entire AGENT-CAPABILITY-ROADMAP.md: the agent now sees
runtime cost, runtime errors, production scale, visual truth, and dependency
risk — and production access for agents was rejected as a principle, not built.
Plus a chatroom ack button and several infra fixes found along the way.

## The through-line

The roadmap's premise: the agent was rich in *static* context (code graph,
DI introspection, history) but blind to *runtime/production reality*. Every
gap got closed **without ever pointing an agent at a production server** —
push the data out to a sink, or have the operator capture it (one-liners).

## AP-1 — Runtime performance in the plan/build loop ✅

- **`scripts/perf-compare.sh`** — deterministic before/after wall-time compare
  from xhgui traces (baseline watermark → only newer traces count). Gates on
  `main_wt` only — discovered `main_ct` is NOT total calls (always 1 =
  `main()`'s own count). 12 unit tests, stub-mysql.
- **`hooks/perf-gate.sh`** — PreToolUse commit gate mirroring test-gate.
  Strictly opt-in (`.claude/perf-gate.json {enabled:true}` + saved baseline),
  FAILS OPEN on missing after-data, kill switch `CLAUDE_PERF_GATE_ALLOWED=1`.
  10 hook tests. Wired host + fleet settings.json.
- **Armed on pps**, 3-act live demo: warm commit passed → cold-cache regression
  (117ms→3138ms, +2593%) BLOCKED with numbers → fix + re-baseline → passed.
- **Cache caveat** (found live): baseline and after must share cache state —
  documented in playbook + gate message.
- Playbook: `hcf-xhgui/templates/xhgui.md` (plugins-central).

## AP-2 — Production errors queryable ✅

- **Bugsink droplet** (DO, SYD1, 1GB, $6/mo): `https://errors.proxiblue.com.au`
  — caddy auto-TLS, ufw, unattended-upgrades, DO backups (operator-enabled).
  Runbook + rebuild cloud-init: `infra/do-bugsink/`. Workstation bugsink
  RETIRED (volume kept). Security-verified: key-only SSH, no signup, 401 API,
  TLS 1.3.
- **Architecture:** prod + ddev PUSH to the sink; agents QUERY the sink. No
  agent↔prod contact ever.
- **Dev feed LIVE:** `justbetter/magento2-sentry` ^4.6 on pps branch
  `feature/sentry-bugsink` (off loki; merge post-go-live). Verified: real CLI
  exception → issue PPS-1 in seconds. Three traps found + documented in the
  pb-hcf sentry template: v4 uses `enabled` not `active`;
  `mage_mode_development: true` needed in ddev; admin flag
  `sentry/general/enable_php_tracking=1` is default-OFF (nothing sends).
- **Prod feed:** DSN config rides the next deploy train post-go-live
  (checklist in `pb-hcf/templates/sentry/README.md`). `pps` (dev) / `pps-prod`
  (prod) project split.
- **issue-sentinel ENROLLED** (the point of it all — "no issues silently
  logged"): stamped `phase: post-batch, order: 30` into
  `~/claude-code-magento-agents` (mounts :ro into 13 projects). Post-batch it
  queries "issues first_seen since batch start" → PASS/PUSHBACK with
  file:line. Degrades to var/report scan on unwired projects.
- Registry: `~/.pb-hcf/bugsink.env` repointed to droplet (old config backed
  up). Playbook: `pb-hcf/templates/playbooks/bugsink.md`.
- Fallback kept dormant: `scripts/bugsink-prod-pull.py` (SSH log-puller,
  operator-configured, unconfigured = silent skip).

## AP-3 — Production data shape ✅

- **`scripts/prod-shape-collect.sh`** — read-only aggregates (counts +
  distributions, zero rows/PII) → JSON. Operator runs it over own SSH
  (~10s, monthly-ish); output at `<project>/.claude/prod-shape.json`.
- **Captured from hypernode_pps live**: sales_order 81,787 (dev: 1,031 — 80×),
  sales_order_item 267,263 (250×), customers 26,002 (8×), items/order 3.3
  (dev 1.0), 485 orders/month. Dev DB was lying by two orders of magnitude.
- Playbook `prod-shape.md`: pre-plan read, cite the number in the plan,
  self-surfacing staleness (>60d → agent nags at plan time; no cron noise).

## AP-4 — Visual ground truth ✅

- Lucas's m2-hyva-playwright framework already had the mechanism (48 header +
  cart baselines). Added **`visual-golden-path.spec.ts`**: home/PLP/PDP ×
  375/768/1024 × 4 browsers = 36 full-page baselines, **seeded from loki**
  (the incoming production truth — green at go-live by construction). Seed +
  compare runs both 36/36. Committed to `ProxiBlue/pps-example-tests`
  (nested repo; pps repo's tests/ is gitignored — freeze untouched).
- Playbook `visual.md`: frontend diff → run specs → **read the diff images** →
  intended change = deliberate `--update-snapshots` committed WITH the change;
  never blind-update (that launders regressions). Ticket design-spec outranks
  baselines when one exists.

## AP-5 — Dependency & SAST intel ✅

- **`scripts/dep-audit.sh`** — daily composer-advisory watch over
  tooling-scope projects; host composer with in-container fallback (private
  repo auth); state-hashed → alerts ONLY on new advisory sets (CVEs are news,
  not commit gates). **Live-fire caught 4 real guzzle advisories in webhooks**
  → chatroom escalation. Found+fixed ddev-exec-eats-stdin loop bug.
- **semgrep 1.172.0** repaired (2023 pip install orphaned by python 3.12 →
  venv at `~/.local/venvs/semgrep`). p/php + p/security-audit over all
  Uptactics modules: clean, 6s.
- Security playbook extended: open advisory on a touched package must be
  addressed in the plan; quorum specialists open with the semgrep sweep.

## AP-6 — Agent prod access ✕ CLOSED WON'T-BUILD

Every prod need was met without it (push-to-sink / operator-capture). Lucas's
"no agents near live" is now the standing pattern. Reopen only for a need that
structurally can't be met that way.

## Side quests shipped

- **pb-chatroom ack button** (`46c2417`, deployed): per-thread dashboard ack
  as the seed recipient; single-recipient closes, broadcast records partial.
- **harness-release-watch noise fix** (`10e485e`): transient npm blips retry
  3×, stay silent <3 consecutive days; persistent failure gets an actionable
  message. (Origin: cryptic 05:40 "npm view failed" email.)
- **`/model` clobber caught**: in-session settings writes rewrite the whole
  file — restored the wiped perf-gate hook + stripped leaked ANSI from the
  model value (`53340df`). Watch for this pattern.
- **Duplicate dep-audit threads acked** (testing artifact, won't recur).

## Operational notes / pending

- **pps go-live (loki→live):** after it lands — merge `feature/sentry-bugsink`,
  then on live: env.php sentry block (prod DSN, `environment: production`, no
  `mage_mode_development`) + `config:set sentry/general/enable_php_tracking 1`.
  Also commit `.ddev/config.yaml` (`xhprof_mode: xhgui`) once on live.
- **webhooks:** bump `guzzlehttp/guzzle` (4 medium advisories) on a branch.
- **lcd-mageos:** web service exited — dep-audit skips until healthy.
- **Droplet admin password** (`infra/do-bugsink/.admin-password`) + bugsink
  agent token → password manager.
- **Empty remote branch** `feature/visual-baselines` on pps origin — delete at
  leisure (`git push origin --delete feature/visual-baselines`) or ignore.
- perf-gate in-container needs a pps `ddev restart` to refresh the stale
  settings.json single-file mount (host sessions already have it).

## Where everything lives

| Repo | Key commits |
|---|---|
| claude-skills-central | `9290dc3` perf engine+gate · `10e485e` harness fix · `b0e7ecf` fleet wiring · `5cee385`/`80862eb` droplet · `e26d612` log-puller · `460e514` prod-shape · `be75b78` dep-audit · roadmap close |
| pb-hcf | `376f521` bugsink playbook · `776b030` sentry template truth · `22663f0` prod-shape playbook · `40d29af` visual playbook · `f79860e` security+deps |
| claude-code-magento-agents | `cd69755` issue-sentinel enrollment |
| pb-chatroom | `46c2417` ack button |
| plugins-central | `7920411` xhgui playbook |
| pps (`feature/sentry-bugsink`) | `798732ee` sentry module |
| pps-example-tests | `6a8e2f7` visual baselines |
