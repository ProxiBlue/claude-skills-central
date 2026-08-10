# Rule triggers — on-demand loading (always-on core)

Full rules live in `claude-skills-central/rules/reference/` (host: `~/claude-skills-central/rules/reference/`, container: `/var/www/html/.claude/rules/reference/`). Each carries `paths:` frontmatter — the harness auto-attaches it when you read a matching file (PHP files → php-debugging, logs/test-results → investigation, composer.json → upgrade-verification, plan files → hcf-plan-orchestrate). When a trigger below hits and the rule has NOT auto-attached (host sessions, non-matching flows), Read it manually BEFORE acting. Hooks enforce the mechanical parts regardless.

| Trigger | Action |
|---|---|
| Test fails, system errors, user reports bug | Read `investigation.md` FIRST. Blast radius (`git diff --stat HEAD`) before any hypothesis. Claim without artefact cite = banned. (Test failures also auto-inject compact protocol via hook.) |
| Playwright test timeout/failure, editing `.spec.ts`/`.page.ts`/`playwright.config.ts` after one | Read `playwright-debugging.md` FIRST. Open `trace.zip`, cite the actual failure line, before editing the test — `playwright-trace-guard.sh` blocks the edit otherwise. Mage-OS 3.3.0+ admin grids: known bulk-edit-panel phantom-row gotcha documented there. |
| PHP runtime question (wrong value, wrong branch, null return) | Read `php-debugging.md`. xdebug-mcp tools, never var_dump — hook blocks debug-call edits. |
| Magento/Mage-OS upgrade, version bump, new module | Read `upgrade-verification.md` BEFORE any "verified" claim. Admin checkout + custom-module specs + golden path, all enumerated + run. |
| Plan orchestration (Magento) | Read `hcf-plan-orchestrate.md` first. `/pb-hcf:wire` before `/hcf:plan-orchestrate`; legacy pipeline.md = stop. |
| Posting ticket comment | Hook forces `gh-comment-hidden.sh`. ≤5 lines, caveman, status prefix. Reference: `gh-ticket-comments.md`. |
| Any web page fetch — security scan, research, "what does this page say" | `webfetch-completeness-guard.sh` blocks WebFetch outright (blanket, not just security). Use `curl` raw (or raw browser-tool text extraction for JS/auth pages) and read the FULL output — never a summarized preview. Reference: `completeness-critical-fetch.md`. |

Per-project rule opt-out: `<repo>/.claude/rules-disable`, one hook name per line (`gh-comment-guard`, `php-debug-guard`, `test-failure-context`, `git-tree-guard`, `webfetch-completeness-guard`). Prose rules vary per project via that project's root CLAUDE.md include list.
