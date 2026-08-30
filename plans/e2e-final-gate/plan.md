# Final Gate — e2e test stack simplification plan

**Date:** 2026-08-27
**Scope:** `pvcpipesupplies` (pps), `lcdscreen_mageos` (lcd), `ProxiBlue/m2-hyva-playwright` (framework), `claude-skills-central` (hooks)
**Status:** DRAFT — awaiting Lucas review

## North star

Tests are the **final gate**. Requirements, in priority order:

1. Tests must be trustworthy — a green run means the shop works; no tautological or self-nullifying tests.
2. One obvious report per run: what ran, what failed, why — human-scannable AND machine-readable.
3. End state: autonomous loop — failed test → triage → code fix → retest → repeat until green, escalate after N.

**Locked decisions (Lucas, 2026-08-27):**
- The authoring-simplification layer of m2-hyva-playwright is **obsolete**. AI writes the tests; page-object mandates, runtime locator/data overlay magic, and skipBaseTests exist to speed up human authoring and are retired.
- External reusability of the framework is **no longer a goal** — "others can use it easily" is pointless when AI writes tests faster than hand-authoring. No public-repo compatibility constraint on any change.
- Consistency comes from **deterministic enforcement (hooks)**, not framework convention.
- Keep: Playwright, the runtime fixture harness (auth, per-worker admin users, faker data, console-error gate, video/trace), the shared base spec corpus as a cross-shop regression pack, reporting infra.

## Phase 0 — Stop the bleeding (bugs + baseline)

Goal: current suites honest and green; record a baseline before restructuring.

- [ ] Fix hardcoded `'lcd'` in `m2-hyva-playwright/src/apps/common/fixtures/index.ts:12` (completes #442 — pps artifacts currently split across `test-results/lcd/` and `test-results/pps/`). Also remove the hardcoded `Admin-Tests---Order-Email-Edits` special case in the same file.
- [ ] lcd: `test:all` never runs `tests/seo/*.spec.ts` (4 specs) — wire in or move up.
- [ ] lcd: delete/rewrite the 4 `expect(true).toBe(true)` tests in `seo/auto-relate.spec.ts`; fix self-nullifying fallback assertions in `contact_page_structure.spec.ts`, `faqs-jsonld.spec.ts:106,176`, `reviews-jsonld.spec.ts:141`.
- [ ] pps: `tests/configurable_product.spec.ts` imports `@hyva/fixtures` → bypasses console-error gate. Point at `../fixtures`.
- [ ] Stale docs: pps CLAUDE.md `test-dev`, lcd `.claude/testing.md` `test:app`, lcd `.claude/visual.md` (pps copy-paste), pps `tests/run.sh` (calls nonexistent script).
- [ ] Dead weight: lcd Cypress remnants (`tests/cypress.json`, old package.json), `checkout_has_shipping_options.spec.ts.NIU`, orphan `playwright.yml` at framework root, `debug_tests/layout.spec.ts` (pps, unreachable), `shipperhq-380-repro/` + ~50 committed debug PNGs at pps repo root.
- [ ] lcd: `frontend_option_price.spec.ts` describe-level `test.skip(true)` since June (#329) — fix or delete, no zombie specs.
- [x] Baseline pps (2026-08-28, in-container — HOST RUNS INVALID, see memory
      pps-e2e-runs-in-container): stripe 4P/13F (1.5h!), checkout 42P/8F/3S (22m),
      pps 287P/12F/160S (32m), hyva 171P/0F/120S (9.4m), pps-admin 6P/1F/4S (6.7m),
      admin 24P/1F/2S (13.4m). Total ~2h45m serial, 35 failures.
      ROOT CAUSE FOUND for the checkout/stripe/admin failure family: dev env.php had
      `checkmo.active=0` (env-level lock, untracked drift) — every checkout-completing
      spec waits for the checkmo radio. Re-enabled dev-only 2026-08-28; buckets rerunning.
      Harness self-tests (_console_error_gate/_trap) fail ONLY under workers=4 — pass
      22/22 in isolation → parallelism flake, make serial in P1.
      → P3b/P4 rider: PREFLIGHT env-precondition check that fails fast with a named
      cause instead of 1.5h of timeouts. Preconditions found so far (pps):
      (1) payment/checkmo/active=1 (env.php, dev-only — fixed 2026-08-28),
      (2) customer_grid indexer realtime (container cron is OFF by fleet policy, so
      by-schedule = permanently stale grid; set realtime 2026-08-28 — cured the
      deterministic tax-exempt-already-exempt-hidden failure, 2/2 green),
      (3) site build healthy (composer install + build-dev; PDP curl 200 check),
      (4) xdebug OFF (lcd 2026-08-29: xdebug+opcache under parallel browser load =
      fpm SIGSEGV crashloop → URL-specific 502s; `ddev xdebug off` cured it),
      (5) playwright browsers present (ddev restart wipes /opt/playwright-browsers).
      PATTERN (both shops, same day): "Cannot gather stats!" FileSystemException
      appears after heavy parallel suite runs — dev-mode on-demand static/generated
      materialization racing parallel browsers corrupts state; admin placeOrder then
      500s silently (UI swallows it, spec times out at 90s with no error surfaced).
      → P4 preflight: warm/deploy static BEFORE the suite (build-dev or
      setup:static-content:deploy) + curl-200 canary on PDP AND an admin route;
      loop should treat "Cannot gather stats" in exception.log as env-fault, not
      test-fault, and self-heal via build-dev.
      POST-FIX: stripe 17/17 green (23.6m, was 4P/13F@1.5h); checkout 49P/1F→fixed.
      CLEAN pps BASELINE (post env fixes): checkout 49P + stripe 17P green;
      pps 291P/8F/160S (all 8F = harness self-test parallel flake — P1: pin
      _console_error_* serial/chromium; didn't repro under light 4-worker mix,
      needs full-bucket load) ; hyva 171P/0F ; pps-admin 7P/0F ; admin 24P/1flaky.
      ONE real-bug candidate: checkout.grandtotal-invariant on Galaxy S24 —
      shipping total renders 0 + console errors on mobile (#445 invariant firing).
      Needs trace triage → possible live mobile checkout bug, escalate to Lucas.
      P1 note (lcd): test:all chains with && — first red bucket aborts the rest;
      port pps #428 non-aborting umbrella.
- [x] lcd P0 shipped 2026-08-28 (branch e2e-final-gate-p0 off live, dcd1b730b):
      auto-relate 13→9 honest, contact honest selectors, #329 zombie un-skipped
      (passes), 6 orphan specs wired into test:all, docs fixed, Cypress tree removed.
- [x] Baseline lcd full run (2026-08-29, post all fixes): admin 15P/9S ✅,
      admin:lcd 26P/8F/30S ❌, frontend:lcd 90P/3S ✅ (incl. rewritten specs),
      hyva 172P/2flaky/117S ✅. Non-aborting umbrella verified working.
      KNOWN ISSUE (lcd, infra not tests): the 8 admin:lcd failures = 4 specs ×2
      browsers (admin_checkout Direct Deposit + order_email ×3), all admin
      placeOrder 90s-hang. Pass in isolation/fresh; fail at the end of a ~1h
      bucket. php-fpm SIGSEGV crashloop persists (84 since restart; xdebug off
      did NOT cure; JIT off; cores go to host apport, no gdb in container).
      NEEDS dedicated debugging session (core backtrace on host). Until fixed,
      admin:lcd bucket is trustworthy only on a fresh container.
      Framework fixes shipped during validation (both checkouts): verifyPageTitle
      → toHaveText+useInnerText (visible-text resolver reads Hyva md:sr-only PDP
      h1 as ""), testResultsDir anchored on __dirname (cwd-relative overshot to
      /var/www/test-results from tests/lcd). P4 note: pps fixture artifacts now
      under tests/m2-hyva-playwright/test-results/ while reporters write
      project-root test-results/ — unify in the P4 report contract.

## Phase 1 — One spec, one owner (dedup)

Goal: every behavior asserted in exactly one place; no silent skip maps.

- [ ] pps: resolve 12 duplicate spec filenames (pps copy vs hyva copy both run in `test:all`). Per file: keep the better copy, delete the other's run (fork honestly or drop the shadow). `home.spec.ts` (9-line shadow) is a delete.
- [ ] lcd: same for the skip-then-fork suites (breadcrumb, search, home-search, contact).
- [ ] Retire `skipBaseTests` (title-keyed, cross-matches same-named suites). Replace with explicit per-shop exclude: `testIgnore` globs or a visible `--grep-invert` list in config. Skips must be greppable and unambiguous.
- [ ] Delete byte-copy data shadow files (pps: cms/configurable_product/home/navigation/sidecart/simple_product; lcd: 9 of 11 data files unreachable). `loadJsonData` fallback covers them; where a real override exists, keep only the delta... or inline data into the spec since overlay is retired (see Phase 3 policy).
- [ ] Prune near-empty locator stubs (pps: page/product/customer/cms/home.locator.ts 2-liners; the 62-line pure re-export cart.locator.ts).

**P1 STATUS 2026-08-29: COMPLETE.** pps: 12 dup pairs resolved, coverage
resurrected (Update email, wishlist-not-logged-in), fake-greens deleted,
harness self-tests isolated serial. lcd: 4 fully-replaced base files →
testIgnore, 4 config suites dropped. Data/locator audit BOTH shops: only 1
byte-identical file existed (pps sidecart.data.json, deleted); everything
else is load-bearing shop data — the analysis agents' "copies" claims did
not survive diffing. skipBaseTests partial entries remain until P1b.
Gate hardening en route: hash_exempt config (lock-file churn), tilde-cd fix,
no-commit-repo hash fix. Eval 5 green.

## Phase 1b — Flatten the structure (unlocked by dropping OSS constraint)

Goal: each shop's `tests/` is a plain, self-contained Playwright project. No nested git repos, no symlinks, no yarn-workspace gymnastics, no APP_NAME/TEST_BASE dispatcher.

- [ ] Vendor the framework INTO each shop repo: copy the runtime harness (fixtures, utils, base specs actually used) into `tests/`, tracked by the shop's own git. Kill: nested `m2-hyva-playwright` checkout, `src/apps/*` nested clones (checkout/luma), `setup-lcd-symlink.sh`, reciprocal symlinks, yarn workspaces.
- [ ] One `playwright.config.ts` per shop — no dispatcher shim, no runtime `require` re-export, no `TEST_BASE` testDir rewriting. Subsets via tags (Phase 2) + `testIgnore`.
- [ ] Base-spec corpus sync across shops becomes an occasional AI task ("diff pps vs lcd base specs, port improvements"), not runtime inheritance. Divergence per shop is allowed and expected.
- [ ] Archive `ProxiBlue/m2-hyva-playwright` (and the checkout/luma satellite repos) with a README pointer. No further upstream maintenance.
- [ ] Simplifies test-gate + agent loop: one config, one spec tree, one report path per shop.

## Phase 2 — Tags and subsets

Goal: run small, targeted slices; feed test-gate "related e2e specs" mechanically.

- [ ] Fixed taxonomy (closed set, additions need a human): `@smoke @cart @checkout @product @category @search @account @admin @seo @email @stripe @visual @nightly`.
- [ ] Tag sweep: every spec gets ≥1 tag via Playwright native `{ tag: [...] }`. Mechanical AI pass, both shops + framework base suites.
- [ ] Replace bucket-script sprawl with tag runners: `test:tag -- --grep @checkout` etc. Keep operational splits that encode runtime constraints (admin serial workers=1, stripe retries=5, nightly visual).
- [ ] `module-tag-map.json` per shop: path/module regex → tags (e.g. `app/code/*/Checkout/ → @checkout @cart`). Consumed by test-gate hint now, agent loop later.
- [ ] Guard hook: new/edited spec without a taxonomy tag → blocked (deterministic, PreToolUse).

## Phase 3 — Standards + enforcement

Goal: AI-era consistency by hook, not convention.

- [ ] `TESTING-STANDARDS.md` (short, in framework repo, mounted to shops): naming (one convention, pick `snake_case.spec.ts`), suite-title format, fixture import rules (shop specs import shop fixtures — never `@hyva/fixtures` or raw `@playwright/test` except `.internal.` harness tests), selector policy, assertion honesty, data policy (inline in spec or shop `data/` — no cross-app overlay).
- [ ] **Selector policy (recommendation):** inline resilient selectors (role/label/test-id) are OK in specs — the page-object mandate is dead. Shared *flows* (login, add-to-cart, checkout-to-payment) live in fixtures/helpers, not page-object class trees. Existing page objects stay until touched; no new ones required.
- [ ] Guard hooks (skills-central, wired fleet): block `expect(true).toBe(true)` and `expect(<precomputed bool>).toBe(true)` patterns; block raw `@playwright/test` import in shop spec dirs (allow `.internal.`); enforce tag presence; enforce naming.
- [ ] Fold into existing `playwright-debugging.md` trace-first discipline + test-gate e2e evidence (already shipped 2026-08-27).

## Phase 3b — Test the tests (accuracy verification)

Goal: a green run is PROOF of function, never decoration. Every test must be demonstrably capable of failing.

- [ ] **Hollow-run detector** (deterministic, cheap, highest value): run the full suite against a dead target — static server serving a blank 200 page on every route. Any spec that PASSES against nothing is asserting nothing → meta-check fails and names it. Catches the whole `expect(true)` / defensive-fallback class mechanically. Wire as `test:verify-tests`, run nightly + after any spec change batch.
- [ ] **Kill-proof at authoring**: protocol for new/changed specs — prove the test goes red before it may go green (sabotage the selector target, wrong SKU, or feature toggle off), then restore. Record as a `red_proof` note in the spec header or test-gate evidence. AI does this naturally when instructed; hook checks the header exists.
- [ ] **Adversarial spec review** (semantic layer): periodic agent pass over spec diffs asking one question — "could this test pass with the feature broken?" Flags conditional assertions (`if (visible) expect…`), multi-selector unions with regex fallbacks, `count() > 0` guards. Static hooks catch syntax; this catches intent.
- [ ] **Failure telemetry**: per-test last-failed date from run history (Phase 4 report data). A test that hasn't failed in N months gets auto-queued for kill-proof re-verification. Tests that can't be made to fail get deleted.

## Phase 4 — One report

Goal: single pane of glass; machine contract for the loop.

- [ ] Standard output contract per run, both shops: `test-results/<shop>/summary.md` (human) + `failures.json` (machine: spec file, test title, tags, error, trace path, screenshot path). Extend pps `markdown-reporter.ts`; drop divergent reporters.
- [ ] `test:all` ends with merged report (Playwright `merge-reports`, shard-safe) + summary print. One command, one verdict.
- [ ] Publish: keep lcd's `test-reports` GitHub Pages pattern, port to pps. Green-run gating stays.
- [ ] Notify: chatroom message on completed run with pass/fail counts + link (host-auto pattern already exists).
- [ ] `failures.json` is the **loop input contract** — freeze the schema here.

## Phase 5 — Performance baseline suite

Goal: dedicated `@perf` specs usable as repeatable profiling baselines (pre/post upgrade, pre/post optimization).

- [ ] New suite `tests/perf/` per shop: deterministic golden-path journeys (home → category → PDP → configure → cart → checkout-start) against **fixed** SKUs/categories — no faker, no content assertions, built for timing repeatability.
- [ ] Run protocol: serial (`workers=1`), warm-cache preamble pass, then N=5 measured repetitions; chromium only.
- [ ] Client metrics via CDP/Performance API per step: TTFB, LCP, CLS, total bytes, request count. Written to `perf-results.json` alongside the Phase 4 contract.
- [ ] Server pairing: trigger XHProf per measured request, correlate with xhgui (`xhgui.results` SQL — pb-hcf runtime-perf playbook already covers query side). One journey step ↔ one profile.
- [ ] Baseline file committed per shop (`perf-baseline.json`); runs report deltas with tolerance bands. **Report-only, never part of the pass/fail gate** — timing flake must not block commits.
- [ ] Cadence: nightly + on-demand (`test:perf`); mandatory before/after any Mage-OS upgrade (feeds upgrade-verification discipline).

## Phase 6 — Agent loop (design doc, then build)

Goal: failed → triage → fix → retest → until green.

- Sketch (detail in its own design doc before building):
  1. Run tag subset or full suite → `failures.json`.
  2. Per failure: triage from trace.zip first (playwright-debugging discipline) — classify test-bug vs code-bug vs flake (rerun once).
  3. Fix in isolated worktree; test-gate evidence applies to the fix commit.
  4. Retest exact test (`--grep <title>`), then affected tag subset, then full suite before declaring done.
  5. Cap: N iterations per failure (start N=3) → escalate to chatroom thread with trace + attempts.
- Executor: claudeclaw/cron `claude --print` pattern (proven on PVC+LCD chatroom autonomy, PR #396 recipe). No agents near live — loop runs against dev/uat.
- Prereqs: Phases 0–4 (esp. the failures.json contract and honest tests — a loop over tautological tests loops forever on lies).

## Scope (Lucas, 2026-08-29, revised)

Host session continues BOTH shops. lcd branch `e2e-final-gate-p0` carries the
P0 work; `GITHUB_400` carries a WIP commit parking scheduled_tasks.lock churn.
lcd fpm SIGSEGV debug still needs its own dedicated session (cores → host apport).

## Open decisions (need Lucas)

| # | Decision | Recommendation |
|---|---|---|
| 1 | Rollout order | pps first (live revenue, biggest suite, worst duplication), port pattern to lcd after. |
| 2 | Flatten timing — Phase 1b before or after tags/standards? | Do 1b right after 1: everything later (tags, hooks, report, loop) gets simpler with one flat tree; don't build tooling against structure about to be deleted. |
| 3 | Loop executor placement (per-shop container cron vs host claudeclaw) | Defer to Phase 6 design doc. |

## Sequencing

0 → 1 → 1b (honest, deduped, flat) → 2 + 3 + 3b (tags, hooks, test-the-tests — mechanical sweeps) → 4 (one report) → 5 (perf baseline) → 6 (agent loop, gated on all prior — a loop over dishonest tests loops forever on lies). Each phase lands independently; stop-anywhere safe.
