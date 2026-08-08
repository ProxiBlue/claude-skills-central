---
paths:
  - "**/*.spec.ts"
  - "**/*.spec.js"
  - "**/playwright.config.ts"
  - "**/playwright.config.js"
  - "**/test-results/**"
  - "**/playwright-report/**"
---

# Playwright debugging — MANDATORY trace-first, plus known gotchas

## Trace-first (mechanically enforced)

On any Playwright test timeout or failure, open `trace.zip` and cite the
actual failure line BEFORE editing the test, page object, or config. This is
the general `investigation.md` protocol applied to Playwright specifically,
and `playwright-trace-guard.sh` (PreToolUse) blocks edits to
`*.spec.ts`/`*.page.ts`/`playwright.config.ts` while a recent unopened
`trace.zip` exists in the repo.

```
mkdir -p /tmp/pw-trace && unzip -o <path>/trace.zip -d /tmp/pw-trace
grep -r 'locator resolved to' /tmp/pw-trace
```

Do not trust `error-context.md`'s final snapshot alone — it's often captured
AFTER `afterEach` (logout, cleanup) has already run, which shows the wrong
page and produces a misleading theory. The trace has the actual failure-time
DOM/locator state.

## Known gotcha: Mage-OS 3.3.0+ admin grid bulk-edit-panel row

Mage-OS 3.3.0 admin data-grids inject
`<tr class="data-grid-bulk-edit-panel" data-bind="visible: active">` as the
FIRST tbody child of every admin grid. It's hidden until bulk-edit mode is
toggled. Any test using bare `tbody >> tr >> .first()` (or similar untyped
row selectors) resolves to this phantom row and Playwright loops on
actionability ("element is not visible — retrying click action") until the
test timeout.

- Use `.data-row` (not bare `tr`) for admin grid row selectors.
- Never set `actionTimeout: 0` in a Playwright config — it turns a bad
  selector into a full-length hang instead of a fast 30s fail with the
  resolved-to line visible. 15-30s is a good ceiling.

Affects any Magento/Mage-OS project on 3.3.0 or later. Also recorded as a
fleet Graphiti fact — `search_nodes`/`search_memory_facts` for "bulk-edit
panel" or "data-grid-bulk-edit-panel" before debugging an admin-grid
Playwright hang on 3.3.0+.

## Why this exists

2026-08-08, LaptopLCDScreen (branch GITHUB_392): agent looped 3 rounds of
speculative fixes (session-drop guards, `networkidle` swaps, timeout
shortening) before opening `trace.zip`, which had the answer
(`locator resolved to <tr class="data-grid-bulk-edit-panel...">`) in plain
text. Only opened it after the user pushed back with "you fixed the
timeout, not the root cause". Full postmortem:
`ai/incidents/2026-08-08-playwright-symptom-not-root-cause.md` (LCD repo).
Chatroom thread: `05d6da8c-b669-4691-933f-0450ea12d35d`.
