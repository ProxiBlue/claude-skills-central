# Agent Capability Roadmap — closing the runtime-reality gaps

**The through-line:** the coding agent is rich in *static, structural, and
historical* context (code graph, runtime DI via Bricklayer, domain history via
Graphiti, xdebug, Playwright, test gate) but poor in *production/runtime reality*
— it plans and builds largely blind to how the system behaves under real load,
real data, and real users. Every action point below closes a slice of that gap.

Ranked by leverage. Work top-down. Each is a capability the agent is *given*, so
plan/build quality improves — not more process.

**Safety rule for all of these:** anything that grants production access gets the
same deterministic-guard treatment as everything else — a hook that HARD-BLOCKS
writes, not a prompt that says "read only." Read-only-in-prose is not read-only.

---

## AP-1 — Runtime performance in the plan/build loop ⭐ (priority)

**Gap:** the agent plans and builds with zero visibility into runtime cost. A
change that adds an N+1 query or a slow block passes the tests, the security
quorum, AND code review — then tanks a production page. This is the one blind
spot the excellent static-analysis stack structurally cannot see.

**Give it:** backend PHP profiling wired as a tool the agent uses, both phases.
- **Plan time:** profile the feature area first → the plan accounts for where
  time actually goes.
- **Build time:** profile the diff → catch regressions before commit.

**How:** DDEV ships xhprof built in; the parked `hcf-xhgui` plan is exactly this
(give HCF agents xhgui/xhprof runtime perf context). Steps:
1. Confirm `ddev xhprof` (or xhgui) captures profiles in the target project.
2. Expose profile query to the agent (MCP tool or CLI the agent can call).
3. Plug into HCF phases: a `pre-plan` perf-context step + a `post-implementation`
   perf-regression check (compare diff-area profile vs baseline).
4. Optional: a gate — block commit if the change regresses a hot path beyond a
   threshold (the perf analogue of the test gate).

**Also considered (Lucas, 2026-08-02):** adding performance tooling more broadly
(frontend perf via chrome-devtools Lighthouse/trace, which is already available
but not in the loop; Blackfire/Tideways as heavier alternatives to xhprof).
Start with xhprof (free, in DDEV); evaluate the rest after.

**Effort:** medium. **Status:** TODO — priority.

---

## AP-2 — Production error data, queryable

**Gap:** Bugsink *captures* errors but the agent can't *query* it, so planning
isn't grounded in "what's actually breaking in this area."

**Give it:** read access to Bugsink (+ the slow-query log) as an agent tool. Data
already exists; it just isn't reachable. Plan-time: "what errors/slow queries
touch this feature area?"

**Effort:** low (data exists). **Status:** TODO.

---

## AP-3 — Production data shape (not the data)

**Gap:** the agent works against a dev DB (possibly a stale subset). Real scale
— catalog size, order volume, edge-case distributions — changes design
(indexing, batch sizes, pagination).

**Give it:** production data *profiles* — counts and distributions, NOT the data
itself (privacy-safe). A periodic export of table row counts / cardinalities the
agent can read at plan time.

**Effort:** low–medium. **Status:** TODO.

---

## AP-4 — Frontend visual / design ground truth

**Gap:** for Hyva/Tailwind work the agent can screenshot + run Lighthouse, but
has no *design reference* to compare against and no *visual-regression baseline*.
It confirms "renders," not "matches intended design / didn't visually regress."

**Give it:** design references (Figma/spec links in the ticket or graphiti) +
a visual-regression baseline (screenshot-diff on key pages in the build loop).

**Effort:** medium. **Status:** TODO.

---

## AP-5 — Dependency / security intelligence in the loop

**Gap:** the security quorum reviews *your code*; nothing scans your
*dependencies*.

**Give it:** `composer audit` (CVE check) + a SAST pass (Semgrep) wired into the
plan (flag known-vulnerable deps) and build (block flagged patterns). Augments
the human-style security quorum with automated intel.

**Effort:** low–medium. **Status:** TODO.

---

## AP-6 — First-class read-only production access

**Gap:** SSH-read to live is allowed but *manual*; the agent can't investigate
production autonomously during planning.

**Give it:** a read-only production-replica query tool + log tail as agent tools,
behind a hard write-blocking guard (per the safety rule above).

**Effort:** medium (needs the guard done right). **Status:** TODO.

---

## Not gaps (already covered — do NOT add here)

Code structure (pb-codegraph), runtime DI/plugin resolution (Bricklayer),
debugging (xdebug), E2E behaviour (Playwright), domain history (Graphiti), test
enforcement (test gate). These are solid; effort spent here is wasted.
