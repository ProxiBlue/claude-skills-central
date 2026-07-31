# Magento 2 / Mage-OS Dev Guide

## Mandatory Rules (always loaded)

@.claude/rules/investigation.md
@.claude/rules/gh-ticket-comments.md
@.claude/rules/hcf-plan-orchestrate.md
@.claude/rules/model-tiering.md

## Agent Delegation (read first)

For one-off result-only tasks, delegate to a subagent. The subagent's exploration trace (file reads, greps, tool output) dies with its window — only the result enters main context. Keeps main context clean and long sessions cheaper.

**Delegate:** "find / where / which", "audit / review for X", "does the codebase do Y", "investigate why Y", "summarize what changed", any task that needs more than ~3 unrelated file reads to answer.

**Don't delegate:** editing files (you re-read anyway), planning a refactor you want to approve step-by-step, iterative back-and-forth, single-file or single-command tasks.

**Pick the specialist first.** Before defaulting to `Explore` or `general-purpose`, check `.claude/agents/CLAUDE.md` (or list files in `.claude/agents/`) for a Magento-specialist agent that matches the task — e.g. `hyva-specialist`, `code-reviewer`, `security-analyst`, `issue-debugger`, `performance-analyst`, `module-developer`, `cache-analyst`, `api-developer`. Use the specialist if one fits; fall back to generic only when none match.

## Agent Teams

Teams spawn multiple Claude instances for parallel work. Use for multi-file changes, not single-file fixes. 4-15x more tokens than single sessions.

Team types: `issue-resolution`, `feature-development`, `module-development`, `audit`.
Templates in `.claude/teams/`. Read template before spawning.

Team lead rules: Enter Delegate Mode (Shift+Tab). Create tasks first. Enforce file ownership (no overlap). Run final verification: `bin/magento setup:di:compile && bin/magento cache:flush`.

## Critical Rules

- Core modules in `vendor/magento/module-*` or `vendor/mage-os/module-*` — NEVER edit
- Custom modules in `app/code/Vendor/Module/`
- Plugins over rewrites. Observers for events. DI via di.xml
- Mage-OS = community Magento fork, 100% compatible

## Commands

```bash
bin/magento setup:upgrade
bin/magento setup:di:compile
bin/magento setup:static-content:deploy -f
bin/magento cache:flush
bin/magento indexer:reindex
```

## Quality

```bash
vendor/bin/phpcs --standard=Magento2 app/code/Vendor/
vendor/bin/phpstan analyse
vendor/bin/php-cs-fixer fix --config=.php-cs-fixer.dist.php
```

## Testing

```bash
vendor/bin/phpunit -c dev/tests/unit/phpunit.xml.dist
vendor/bin/phpunit -c dev/tests/unit/phpunit.xml.dist path/to/TestFile.php
vendor/bin/phpunit -c dev/tests/integration/phpunit.xml.dist
```

## Coding Standards

- PSR-12 + Magento2 standards. PHP 8.1+ features
- `declare(strict_types=1)` in all PHP files
- Constructor property promotion. Type hints on everything
- Trailing commas on arrays and method args
- Import classes with `use` — no FQCNs
- No copyright headers. Line break + strict_types at top
- Multi-line arrays always. Extra line breaks between conditions and before returns
- Methods with 0-1 params: curly on new line. Multiple params: params on new lines with trailing commas
- Extra line break after `parent::__construct` calls
- Integer returns in models: `return $this->getData(FIELD) ? (int) $this->getData(FIELD) : null;`
- Don't add return types on methods bound by interfaces (models, resources, collections)

## Module Structure

```
app/code/Vendor/Module/
├── registration.php + etc/module.xml
├── etc/di.xml, events.xml, routes.xml, db_schema.xml
├── etc/adminhtml/ + etc/frontend/
├── Api/ + Api/Data/          # Service contracts
├── Model/ + Model/ResourceModel/
├── Block/ Controller/ Helper/ Plugin/ Observer/ ViewModel/
├── Setup/Patch/Data/ + Schema/
├── view/frontend/layout/ + templates/ + web/
├── view/adminhtml/
└── Ui/Component/
```

After changes: `bin/magento setup:upgrade && bin/magento cache:flush`

## Playwright (DDEV)

**DNS bug:** `<project>.ddev.site` can resolve to 127.0.0.1 instead of ddev-router IP. This is DNS, NOT Playwright architecture problem. Fix with `ddev fix-dns` or manual /etc/hosts update. Verify: `getent hosts <project>.ddev.site` should return 172.x.x.x.

Check app context (Hyva vs PPS vs Luma) BEFORE debugging selectors.

## Git Workflow

- Before switching branches: check for uncommitted changes, stop and ask if any exist. Feature/bug work branches from live.
- After swapping to a working branch, always merge the current live branch back into teh feature branch to ensure we work on latest code as per live.
- We NEVER push feature branches to remote/origin. We merge locally, and push uat / live instead.
- Always check if theer is an existing feature branch for teh work, and if not stat from live (as source of truth and create a new featuire branch
- We are a single developer on teh project, so we don;t use githubs PR system. we do it all locally
- a push to uat will immediatly initiate a CI pipeline deploy
- a push to live will run on a schedule CI deploy pipeline on a deploy schedule.
- feature branches are named 'feature/github_TICKET_NUMBER_scope_keywords' (keep it short)

## CI / Deploy pipeline

- We use a 3rd party system called buddy.works
- we do not use github actions or PR's


## Deployment & Git Safety (cardinal rules)

- **NEVER push, deploy, or merge without explicit user authorization in the current turn.** "Continue", "yes", "go" said earlier in the session does NOT authorize the NEXT push. Re-confirm per push.
- **NEVER edit live/production directly** via SSH or any other path. SSH to live is read-only for investigation.
- **NEVER push to `live` or `uat` branches autonomously.** These are deployment branches; pushes must go through `/deploy-check` skill.
- **NEVER `git push --force`** anywhere without explicit user typed confirmation.
- Manual verification (tests + diff review) MUST complete before any push.
- The `/deploy-check` skill (from `proxiblue-skills` plugin) is the sanctioned push path — runs tests, tsc, shows diff stat, requires explicit confirmation, then pushes.

## Environment Context (host vs DDEV container)

Before any task involving config files, MCP setup, mount permissions, or host paths — declare and verify your execution context:

- Run `hostname && pwd && ls /var/www/html 2>/dev/null && echo "HOME=$HOME"` and state whether you're operating from the host shell OR inside a DDEV web container.
- Files mounted RO inside the container include `/var/www/html/.claude/{settings.json, CLAUDE.md, mcp.json}` and the plugins-seed dir. Edits from inside the container will silently fail or error. Tell the user to edit from the host shell instead.
- Host project paths (`~/workspace/...`) are NOT visible from inside the DDEV container. Ask the user or use the host shell.
- When config edits are needed and the file is in a read-only mount, stop and explicitly ask the user to run the edit from the host shell.

## Tool Selection (codegraph + grep)

- Use the pb-codegraph MCP first for codebase exploration (`find_symbol`, `impact`, `query`) — fall back to grep/Read if results are incomplete OR `list_repos` doesn't list the expected repo.
- **Repo naming**: project repos register as `m2_<sitename>` (e.g. `m2_pvcpipesupplies`); check `mcp__pb-codegraph__list_repos` for actual names before passing `repo:`.
- After `pb-codegraph index` the graph updates in place (no restart needed); a staleness banner on `impact` means re-run `pb-codegraph augment`.
- Cross-mount edge traversal does NOT work — `impact(MageosClass)` won't return callers from custom code, and vice versa. Federated search via `repo: @mageos-project` merges symbol hits but not graph edges.

## Database

Use database MCP server for all DB queries (AI restriction). `/bin/cp` for file copies in DDEV containers.

## New tasks while existing task are being executed with todo lists

- Do not immediately pivot to the new task, unless marked urgent
- Add teh new task to your todo list, and display active todo list showing tak in list.
- At the end of teh current ask, start working on the todo list, don't stop and ask.
- First on, first off


