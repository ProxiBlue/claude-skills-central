---
paths:
  - "**/composer.json"
  - "**/composer.lock"
---

# Upgrade / Update / New-Module Verification — MANDATORY

Applies to any Magento / Mage-OS **upgrade**, version **update**, dependency bump, or **new module create**. Origin: lcdscreen #385 (Mage-OS 2.3.0→3.2.0, 2026-07-15) — an AI ran a hyva-frontend-weighted golden-path subset plus a single admin smoke and declared the upgrade "verified"; it had NOT run admin checkout or the custom-module regression specs. A human (Lucas) caught 12 admin-test failures and prevented a regression reaching UAT. This rule exists so that gap never recurs.

## The rule — before ANY "verified" / "all passing" / "golden path passed" claim

You MUST explicitly **enumerate the actual spec files** (ls the test dirs) and **run**, then cite pass/fail for each of:

1. **Admin checkout / order-create** flows — e.g. `admin/checkout.spec.ts` (COD, Check/Money, PO per config). NOT just an admin login or product-grid smoke.
2. **Every custom-module regression spec** — especially recently-added feature tickets. Search the suite by ticket number (e.g. `GITHUB_383`) and by custom vendor namespace (ProxiBlue/ItTools/etc.).
3. **Frontend golden path** — home, PLP, PDP, cart, checkout.

Never claim coverage for a spec you did not execute. A hyva-frontend subset + one admin smoke is **not** full verification and must never be presented as such. List exactly which specs ran and their results.

## When admin E2E specs fail after a major upgrade — triage before "fixing"

Distinguish **test-harness** failures from real **custom-code** regressions. Common test-harness causes after a Magento base bump:
- Relative admin URL / hardcoded `/admin/` frontName instead of the env `admin_path` (real frontName is randomized, e.g. `UadminU2nme`).
- Admin UI-component grid / DOM **selector drift** in the new base (e.g. `table.data-grid tbody tr` no longer matching).
- Admin order-create **email/account fields hidden** in the changed form.

Verify the actual product behaviour first — `setup:di:compile` clean AND drive the feature — before concluding a custom module is broken. Do not "fix" a module for what is a test-selector issue, and do not "fix" a test to mask a real regression.

## Plan-mode surfacing

For upgrade/update/new-module tasks, this must surface in `plan-create` / `plan-orchestrate`. A companion Graphiti fleet fact carries the same content with keywords (upgrade, update, new module, golden path, admin checkout, regression) for incident recall.
