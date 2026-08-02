# AP-1 Plan — Runtime performance profiling in the plan/build loop

**Supersedes** `~/claude-plugins-central/hcf-xhgui-plan.md` (May 2026, blocked on
retired pb-gitnexus). **Date:** 2026-08-02. **Status: ALL PHASES DONE (0, 1', 2, 3, 4) — 2026-08-03.**

- Phase 2 (pps): playbook wired via .claude/CLAUDE.md pointer; in-container agent discovers+reads it unprompted (host-side didn't — .claude/CLAUDE.md only loads in-container). Query-in-plan is prompt-dependent (Phase 1' queried+cited numbers when engaged).
- **Phase 3 — regression compare ✅** — `scripts/perf-compare.sh` (in `claude-skills-central/scripts/`): save-baseline/check/gate on **wall time** (`main_wt`). Discovered live that `main_ct` is meaningless (always 1 = `main()`'s own count), so the gate is wall-only; query-count stays a reviewer judgement via profile-JSON parse (playbook Query 3). 12 unit tests (stub-mysql, no live DB). Live-fired on pps: baseline 291.5ms → cold-cache after 1738ms → correctly flagged REGRESSION. Exposed the **cache-state caveat** (warm both captures) — now documented in the playbook + gate message.
- **Phase 4 — perf-gate ✅** — `hooks/perf-gate.sh`, PreToolUse on `git commit`, mirrors test-gate. STRICTLY opt-in (`.claude/perf-gate.json` `{enabled:true}` + a saved baseline; no auto-detect → zero fleet noise). FAILS OPEN on missing after-data (blocks only on a measured regression). Kill switch `CLAUDE_PERF_GATE_ALLOWED=1`, warn mode `CLAUDE_PERF_GATE_MODE=warn`. 10 hook tests. Wired into **host** settings.json (inert without config).
- **Deferred (ops, not build):** wiring the gate into **container/fleet** settings + arming it on pps (`.claude/perf-gate.json` + committed baseline) waits on the pps go-live freeze lifting + the LIVE-branch rule for container config. Also still pending from Phase 2: committing pps `xhprof_mode:xhgui` + `.claude/xhgui.md` (same freeze).

## ⚡ Phase 0 findings (2026-08-02) — the design simplified

Probed on pps (`ddev xhprof on`, `xhprof_mode: xhgui`). Decisive result:

- **xhgui stores traces in a MySQL table `xhgui.results`** (PDO save handler),
  on the same DB server as the project — NOT MongoDB, NOT an HTTP-only UI.
- **URL-level metrics are directly SQL-queryable** — flat columns `main_wt`
  (wall time µs), `main_cpu`, `main_mu`/`main_pmu` (memory), `main_ct` (call
  count), plus `url`, `simple_url`, `request_ts`. Verified: our test request
  landed as a row (`/`, main_wt 7.09s cold).
- **Function-level drill-down is in the `profile` longtext (xhprof JSON)**, keyed
  `caller==>callee` with ct/wt/cpu/mu/pmu. **MySQL `JSON_EXTRACT` works on it** —
  verified pulling `main()` wall time. So top-functions + SQL-query-count are
  derivable in SQL (or a small view), no external parser needed.

**Consequence: no custom read-MCP wrapper is needed.** The agent already has a
database MCP (`mcp__database__execute_query` / `mcp__magento2-dev__db-query`), so
read access to perf data is *just SQL against `xhgui.results`*. This deletes the
entire "Phase 1/2 MCP wrapper" from the May plan — a big maintenance-surface win,
consistent with the minimize-burden principle.

### Revised (simpler) design
1. **Access = SQL via the existing DB MCP** — nothing to build or maintain.
2. **A context-doc playbook** `.claude/xhgui.md` teaching the agent the queries
   (how-slow-is-this-URL; recent-trend; top-functions; before/after compare).
3. **Optional: a SQL view** (`xhgui_top_functions`) that unpacks the profile JSON
   for drill-down + SQL-query-count, so the agent queries a clean view.
4. **Wire into HCF phases via the playbook** (pre-plan perf-context;
   post-implementation regression compare; optional pre-commit perf-gate).

### Revised phases
- ~~Phase 0 probe~~ **DONE.**
- ~~Phase 1 MCP read tools~~ **DELETED** — SQL via existing DB MCP replaces it.
- **Phase 1' — playbook** ✅ DONE + LIVE-FIRED 2026-08-02: agent given the playbook autonomously queried xhgui.results (homepage 3551ms vs login 320ms) AND parsed the profile JSON to name the hotspot (ObjectManager Developer::create, 50% of page) with a cache-state caveat. Playbook at seed/marketplaces/hcf-xhgui/templates/xhgui.md. Was: write `.claude/xhgui.md` with the
  query patterns + the optional top-functions SQL view. Live-fire: ask the agent
  "how slow is the homepage and what's the top function" → it queries and answers.
- **Phase 2 — HCF pre-plan wiring** (~half day): wire the playbook so plans pull
  perf context for touched URLs (the `hcf-xhgui` plugin, mirroring pb-codegraph —
  but now it's a context-doc + wire skill only, no MCP server).
- **Phase 3 — regression compare** (~half day, was ~1 day): a query/helper that
  diffs before/after `main_wt` + query-count for a URL; post-implementation
  perf-reviewer cites it. Trace capture via Playwright (already present).
- **Phase 4 — perf-gate** *(optional)*: block commit on hot-path regression.

The 80/20 is now even cheaper: **Phase 1'+2 ≈ 1 day** (was ~1.5), because the
MCP-wrapper build evaporated.

---

## Original plan (pre-Phase-0) — retained for reference below

## Objective

Give the coding agent runtime performance data during both **planning** and
**building**, so plans account for where time actually goes and builds catch
regressions — the one blind spot the static-analysis stack structurally cannot
see. Use **xhgui** (free; DDEV ships it as an xhprof mode) so there's no paid
profiler and no separate install.

## What changed since the May plan (unblocks it)

- **pb-gitnexus retired** → **pb-codegraph** is the codegraph sibling and already
  has a working MCP (`mcp__pb-codegraph__*`). Mirror *its* structure, not the
  retired one. The "blocked on pb-gitnexus" gate is void.
- **DDEV xhprof has `xhgui` mode built-in** (`xhprof_mode: xhgui`, `ddev xhprof on`)
  — persistent, queryable profiles with no separate xhgui deployment.
- **HCF v2 richer phases** — hook into `pre-plan`, `post-implementation`, and
  `pre-commit` (the current pb-hcf agents run at these), not just devils-advocate.

## Architecture — three layers

**1. Capture (free, built-in).** `ddev xhprof on` with `xhprof_mode: xhgui`.
Profiles accrue as the site is exercised. Capture a **baseline** per key URL
(home, PLP, PDP, cart, checkout, a couple of admin actions).

**2. Access — a small MCP server** (stdio, host-launched via npx; same pattern as
the magento2-dev MCP). Reuse the May plan's tool set — it's good:
- `top_functions_for_url(url)` — aggregated hot functions (wall/cpu/query count).
- `list_recent_traces(url?, since?)` — recent trace ids.
- `get_trace(id)` — full function tree for one trace.
- `compare_traces(before, after)` — wall-time + query-count + call-count diff.

Phase 0 caveat (kept from the old plan): **xhgui's HTTP surface isn't a stable
public API** — probe what the current DDEV xhgui version actually exposes before
wrapping it; pin to the observed formats; surface clear errors on drift.

**3. Integration into the HCF loop — the new part:**

| Phase | Step | What it does |
|---|---|---|
| **pre-plan** | perf-context | For URLs/areas the plan will touch, pull `top_functions_for_url` → feed "here's where time goes + query counts" into the plan and the devil's-advocate. Plans stop being perf-blind. |
| **post-implementation** | perf-reviewer (sibling to codegraph-reviewer) | Profile the changed code path, `compare_traces` vs baseline → flag regressions **with numbers** in the review. |
| **pre-commit** *(optional)* | **perf-gate** | A hook that BLOCKS commit if a hot path regressed beyond a threshold — the perf analogue of the test-gate. Opt-in per project via `.claude/perf-gate.json`. |

## Phased delivery — smallest first, each live-fired

- **Phase 0 — probe** (~2h): `ddev xhprof on` (xhgui mode) on pps; generate
  traffic; probe the xhgui endpoints; decide JSON API vs direct store read.
- **Phase 1 — MCP read tools** (~half day): `top_functions_for_url` +
  `list_recent_traces`. **Live-fire:** ask the agent to profile a known-slow page
  and cite the top function by wall time. This alone gives plan-time value.
- **Phase 2 — HCF pre-plan wiring** (~half day): `hcf-xhgui` plugin mirroring
  pb-codegraph (wire skill + `.claude/xhgui.md` playbook + central mcp.json entry).
  **Live-fire:** run a plan touching a hot path; confirm the plan cites perf data.
- **Phase 3 — regression check** (~1 day): `compare_traces` + the
  post-implementation perf-reviewer. **Live-fire:** make a deliberately-slow
  change (add an N+1); confirm the reviewer flags it with numbers.
- **Phase 4 — perf-gate** *(optional, ~half day)*: block commit on hot-path
  regression. **Live-fire:** the slow change from Phase 3 should be blocked.

## The 80/20

**Phases 0–2 (plan-time perf context) are the 80/20.** They give the biggest win
— plans that see runtime cost — for ~1.5 days, and prove the value before
building the heavier build-time regression check (Phase 3) and gate (Phase 4).
Recommend: do 0–2, use it for a couple of real plans, then decide on 3–4.

## Open decisions for you

1. **Scope:** stop at plan-time context (Phases 0–2), or commit to the full
   regression check + perf-gate (0–4)?
2. **Build-time trace capture (Phase 3+):** how does the agent generate
   deterministic before/after traces? You have Playwright — driving the page to
   generate a trace is the cleanest option; alternative is curl with a session
   cookie. Decide when we reach Phase 3.
3. **Perf-gate threshold (Phase 4):** what regression is "too much" — a fixed %
   wall-time increase on a hot path, a query-count increase, or both?

## Verification discipline

Every phase is **live-fired** against a real agent session (the discipline that
caught the test-gate payload bug and the eval-harness self-bug this session):
"it works in theory" is where the check begins, not ends.

## Reference

- Mirror: `~/claude-plugins-central/seed/marketplaces/pb-codegraph/` (structure + MCP).
- DDEV xhprof/xhgui: https://ddev.readthedocs.io/en/stable/users/debugging-profiling/xhprof-profiling/
- xhgui upstream: https://github.com/perftools/xhgui
- Superseded plan: `~/claude-plugins-central/hcf-xhgui-plan.md`.
