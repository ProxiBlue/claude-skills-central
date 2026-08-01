# Rule triggers — on-demand loading (always-on core)

Full rules live in `claude-skills-central/rules/` (host: `~/claude-skills-central/rules/`, container: `/var/www/html/.claude/rules/`). Read the full rule BEFORE acting when its trigger hits. Hooks enforce the mechanical parts regardless.

| Trigger | Action |
|---|---|
| Test fails, system errors, user reports bug | Read `investigation.md` FIRST. Blast radius (`git diff --stat HEAD`) before any hypothesis. Claim without artefact cite = banned. (Test failures also auto-inject compact protocol via hook.) |
| PHP runtime question (wrong value, wrong branch, null return) | Read `php-debugging.md`. xdebug-mcp tools, never var_dump — hook blocks debug-call edits. |
| Magento/Mage-OS upgrade, version bump, new module | Read `upgrade-verification.md` BEFORE any "verified" claim. Admin checkout + custom-module specs + golden path, all enumerated + run. |
| Plan orchestration (Magento) | Read `hcf-plan-orchestrate.md` first. `/pb-hcf:wire` before `/hcf:plan-orchestrate`; legacy pipeline.md = stop. |
| Posting ticket comment | Hook forces `gh-comment-hidden.sh`. ≤5 lines, caveman, status prefix. Reference: `gh-ticket-comments.md`. |

Per-project rule opt-out: `<repo>/.claude/rules-disable`, one hook name per line (`gh-comment-guard`, `php-debug-guard`, `test-failure-context`). Prose rules vary per project via that project's root CLAUDE.md include list.
