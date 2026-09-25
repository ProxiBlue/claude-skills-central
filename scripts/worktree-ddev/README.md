# worktree-ddev — EMERGENCY TICKETS ONLY (status changed 2026-09-25)

These scripts work. They are **not** the default workflow any more.

## Status

- **2026-09-11** — git worktree + one ddev instance per ticket was decided as the
  DEFAULT fleet workflow, replacing branch-switch-in-place. Tooling built and
  tested here. The pps/fleet rollout was deliberately never started.
- **2026-09-25 — REVERTED.** Default is back to the pre-worktree model: one
  checkout per project, switch branches in place. Worktrees are reserved for
  **emergency tickets** — a hotfix that must not disturb work already in flight
  on the main checkout. The rollout that never happened is now cancelled, not
  pending.

**Why reverted:** the flow has real friction and the fix is a timesink nobody
needs right now. Concretely, found while shipping the Bugsink change on pps:

- `ddev` derives its project from cwd and refuses to run from a worktree of an
  already-running project, so `ddev exec` only works from the main checkout.
- `test-evidence.sh` keys test evidence to the state hash of the root derived
  from the command's cwd, and only records when it recognises the runner.
  `tg__segment_is_test`'s `ddev)` branch does `shift 2` and then hits `--dir`,
  returning 1 — so `ddev exec --dir <worktree> <runner>` is never recorded. The
  `php|npx|node|sudo|...` branch directly above it does skip `-*` flags; the
  `ddev` branch does not. `docker exec` is not a recognised wrapper at all.
  Net effect: **work done in a worktree cannot satisfy test-gate.sh**, so the
  commit is blocked no matter how green the suites actually are.
- Project test infra assumes one checkout at `/var/www/html`: the e2e harness
  `tests/m2-hyva-playwright/` and `config.private.json` are untracked (and
  `tests/apps/tsconfig.json` extends into that untracked dir), and two
  `SingleOptionAutoSelect` test classes hardcode `/var/www/html/app/code/...`.
  The `uptactics-unit` suite NAME is also absent from the tracked
  `phpunit.xml.dist` (it lives only in the untracked `phpunit.xml`), but the
  tests themselves ARE collected by `.dist`'s `Magento_Unit_Tests_App_Code`
  suite -- a fresh checkout can run them, it just cannot use that suite name.

## If you do use one for an emergency

`worktree-ddev-up.sh <repo-path> <ticket-id> [existing-branch]` creates the
worktree plus a `<project>-<ticket>` ddev project and seeds its DB from a
snapshot. `worktree-ddev-down.sh <project-name> [--delete-branch] [--force]`
tears it down and refuses on a dirty tree unless forced. State lives under
`~/.claude/worktree-ddev/state/`, keyed by full project name. Host-only — the
scripts refuse to run from inside a container.

Expect to commit from the main checkout, not the worktree, until the
test-evidence recogniser learns `--dir`.
