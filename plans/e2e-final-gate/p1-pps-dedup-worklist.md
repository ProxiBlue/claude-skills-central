# P1 pps dedup worklist (from 2026-08-28 pair analysis)

Verdicts for the 12 duplicate spec pairs (pps copy vs hyva base copy, both run by test:all).
Full mechanics: skipBaseTests is title-keyed and NOT base-only — pps specs calling
shouldSkipTest with a matching describe+title self-suppress.

## Found defects (fix during P1)

1. **3 tests run TWICE** every test:all: `Change password`, `Simple product data
   consistent PDP to cart`, healthcheck `PLP/PDP/Checkout returns 200` (3 URLs × 2).
2. **`Update email address` runs NOWHERE** — pps account.spec.ts calls shouldSkipTest
   and config suppresses that exact describe+title → pps copy self-skips, base copy
   suppressed. Silent coverage hole.
3. **`PPS Filters` test body fully commented out** — reports green, tests nothing
   (category.spec.ts). Delete.
4. pps healthcheck assertions are STRICTLY WEAKER than base (h1-visible vs
   role-heading-with-name; Hyva renders PLP title as span → pps h1 check wrong).
   Keep base copies, delete pps PLP/PDP/Checkout healthchecks.

## Actions

### config.json skipBaseTests additions
- `Breadcrumb navigation test suite` += `Category breadcrumb navigates to parent`
- `Cart data consistency test suite` += `Simple product data consistent PDP to cart`
- `Account management test suite` += `Change password`

### pps-side deletions
- DELETE `tests/apps/pps/tests/navigation.spec.ts` + remove `Navigation test suite`
  from skipBaseTests (base copy identical, runs instead)
- DELETE `PPS Filters` no-op test in category.spec.ts
- DELETE pps healthcheck `PLP/PDP/Checkout returns 200` (keep `Homepage returns 200` —
  it's the genuine pps variant; base copies of the other 3 resume via nothing-to-skip)
- DELETE test.skip'd wishlist-not-logged-in in pps configurable_product.spec.ts + remove
  `Can not add a product to a wishlist...` from skipBaseTests → base coverage resumes
- account.spec.ts: remove shouldSkipTest self-skip so `Update email address` (pps copy)
  actually runs; keep base title suppressed
- DELETE `Change password` from pps account.spec.ts (alternative to config entry — pick ONE)

### Base files that MUST keep running (unique coverage — never exclude)
account (trim + newsletter), cart (remove-item + totals), category (sorts/limiter/pager),
configurable_product (6 unique), home (navigate + homepage add-to-cart).

### Base files inert after the above (candidates for testIgnore once skipBaseTests dies)
cart_qty, configurable_prices, search, navigation, breadcrumb_nav, cart_consistency,
healthcheck — but prefer keeping them running-as-empty until P1 retires skipBaseTests
wholesale for explicit testIgnore.

## Coverage holes needing NEW pps tests (pre-existing, → P2 backlog)
- Layered-nav filters (base suppressed AND pps no-op'd)
- Search: no-results + multiple-results
- PLP sort by name a-z/z-a, list↔grid toggle
- Cross-file near-dup: base cart.spec "change quantity" ≈ pps cart_qty — unify in P1b
