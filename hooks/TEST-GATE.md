# Test Gate — machine-checked "test before commit/push"

Closes the enforcement asymmetry from the 2026-07-31 tooling review: merge/push
guards were deterministic hooks, but "test before push" was prose the agent was
trusted to follow. Origin incident: lcdscreen #385 — an upgrade was declared
"verified" off a partial frontend-weighted test subset; a human caught 12
failing admin tests before UAT.

NOT auto-loaded into context. The gate teaches the agent at block time via its
stderr message; no always-on rule needed (deliberate — the review also flagged
always-loaded context growth).

## Parts

| File | Hook | Job |
|---|---|---|
| `hooks/test-gate-lib.sh` | (sourced) | state hash, evidence path, test-runner detection |
| `hooks/test-evidence.sh` | PostToolUse Bash | records test runs (`exit_code` + state hash) and commit blessings |
| `hooks/test-gate.sh` | PreToolUse Bash | blocks `git commit` / `git push` without passing evidence |
| `scripts/changed-line-coverage.sh` | (called by gate) | opt-in hollow-test catcher via clover diff coverage |

## How it decides

1. **Evidence**: every Bash command Claude runs passes through `test-evidence.sh`.
   If the command actually invokes a test runner (phpunit/pest/codecept/behat/
   infection/playwright test/jest/vitest/pytest/npm test/composer test/
   `bin/magento dev:tests:run`, incl. `php`/`npx`/`ddev exec` wrappers), a JSONL
   record lands in `<git-dir>/claude-test-gate/evidence.jsonl`:
   `{"type":"test","state":<hash>,"exit_code":N,...}`.
   The **state hash** covers HEAD + full working-tree diff + untracked file
   content — so `git add` keeps evidence valid, while ANY edit after the test
   run invalidates it. Mentions of a runner in `grep`/`echo` do NOT count
   (first-token detection, not substring match).
2. **Gate**: on `git commit`, staged (+ `-a` swept) files are filtered to code
   (`.php .phtml .js .mjs .cjs .ts .tsx .jsx .graphql(s)` by default). If any
   remain, there must be a `type:test, exit_code:0` record at the CURRENT state
   hash, else exit 2. Docs/config-only commits pass untouched.
3. **Push**: outgoing range (`@{u}..HEAD` with fallbacks) is checked the same
   way; a HEAD blessed by a previously gated commit passes without a re-run
   (`test-evidence.sh` records `{"type":"commit","head":<sha>}` after each
   successful commit).
4. **Arming**: gate is active only where test infrastructure exists
   (`phpunit.xml*`, `vendor/bin/phpunit`, `dev/tests/`, playwright config,
   real `package.json` test script) or `.claude/test-gate.json` says
   `"enabled": true`. Skills/docs/shell repos are untouched.

## Per-project config — `.claude/test-gate.json` (optional)

```json
{
  "enabled": true,
  "test_hint": "ddev exec vendor/bin/phpunit -c dev/tests/unit/phpunit.xml",
  "code_patterns": ["\\.(php|phtml|js|ts)$"],
  "exempt_patterns": ["^docs/", "^Test/fixtures/"],
  "coverage": {
    "clover": "var/coverage/clover.xml",
    "min_pct": 60,
    "on_missing": "block"
  }
}
```

- `enabled` — explicit on/off, beats auto-detect. `false` = project opted out.
- `test_hint` — shown in the block message; point it at the RIGHT suite
  invocation for the project (targeted per-testsuite runs per the HCF
  test-collision note).
- `coverage` — opt-in changed-line coverage gate (commit-time, PHP only).
  Generate clover in the test run, e.g.
  `XDEBUG_MODE=coverage vendor/bin/phpunit -c dev/tests/unit/phpunit.xml --coverage-clover var/coverage/clover.xml`.
  A green suite that never executes the changed lines fails here — the classic
  hollow AI-written test.

## Mutation testing (stronger hollow-test catcher, PHP)

Changed-line coverage proves lines EXECUTED; Infection proves the assertions
would NOTICE a change. Per-project recipe (not centrally enforced yet):

```bash
composer require --dev infection/infection
vendor/bin/infection --git-diff-lines --git-diff-base=origin/main \
  --min-msi=60 --threads=4
```

Wire it as the project's `test_hint`, or add it to a `.claude/agents/` post-
implementation HCF agent. When a project proves the loop works, promote to a
`"mutation"` config key in the gate (future work).

## Kill switches / modes

- `export CLAUDE_TEST_GATE_ALLOWED=1` **before** starting claude — full bypass
  (same convention as `CLAUDE_MERGE_ALLOWED` / `CLAUDE_PUSH_ALLOWED`; inline
  prefixing mid-session does not work for the agent because the gate would
  still fire on the command scan — but note this one gates the HOOK env, so it
  genuinely must be pre-exported).
- `export CLAUDE_TEST_GATE_MODE=warn` — soft-launch: prints what would block,
  allows anyway.
- `{"enabled": false}` in `.claude/test-gate.json` — per-project opt-out.
- Unwire the hook lines in settings.json — last resort.

## Known limits (honest list)

- **Harness exit-code model (v2.1.198, verified by live payload probe
  2026-08-01)**: PostToolUse Bash fires only for exit-0 commands and the
  payload has no exit-code field. The recorder therefore treats
  hook-fired-for-test-command as a pass (correct on this version). If a
  future harness starts firing PostToolUse for failing commands WITHOUT
  adding an exit-code field, every failing run would record as a pass —
  re-verify this on every harness version bump (payload probe recipe:
  temp dump hook + headless session; see graphiti host-group fact
  "Harness version pinning rationale").
- Exit code is per whole Bash command: `phpunit; echo done` would mask a
  failure. Claude normally runs runners bare; not defended v1.
- `git -C <path>` commit/push resolves root from session cwd, not `-C` — a
  gated repo touched via `-C` from elsewhere may be mis-scoped.
- Evidence is suite-agnostic: ANY passing run (e.g. one targeted spec) opens
  the gate for the whole change set. The coverage layer exists precisely to
  tighten this per project. Upgrade-verification rule still owns "which specs".
- The agent could hand-forge evidence JSONL; the block message forbids it and
  transcripts show it, but it is not cryptographically prevented.
- Commits by the human outside Claude produce no blessing; a later Claude push
  is asked for a test run at current state once. By design.

## Rollout state (2026-08-01)

- Wired: host `~/.claude/settings.json` (+ push-guard host wiring fixed at the
  same time — was a 2026-07-29 audit finding) and central container
  `settings.json` (fleet, active on next session start).
- Tested: synthetic scratch-repo suite (recorder, gate block/pass, staleness
  invalidation, push blessing, coverage math). NOT yet exercised on a real
  Magento project — first live commit through it should be watched.
