# Stack profiles

A **profile** is the set of per-stack Claude Code config a fleet DDEV project mounts.
Everything else (hooks, scripts, rules, teams, plugin seed) is shared and mounted from
the repo root unchanged.

| File | magento | python | drupal | How produced |
|---|---|---|---|---|
| `settings.json` → `/var/www/html/.claude/settings.json` | symlink to master `settings.json` | generated | generated | `scripts/build-profiles.sh` |
| `mcp.json` → `.ddev/claude-code/.claude/mcp.json` | symlink to `mcps/.mcp.json` | generated | generated | `scripts/build-profiles.sh` |
| `CLAUDE.md` → `.ddev/claude-code/.claude/CLAUDE.md` | symlink to `Claude.md` | hand-written | hand-written | edit directly |
| `agents` → `/var/www/html/.claude/agents` | `~/claude-code-magento-agents` | `~/claude-code-python-agents` | `~/claude-code-drupal-agents` | separate git repos |
| `rules-disable` → copied to `<project>/.claude/rules-disable` | empty | Magento guard names | Magento + python guard names | `scripts/onboard-project.sh` |

Magento projects still mount the root files directly; the `magento/` symlinks exist so
onboarding and drift tooling can treat every stack the same way. Do not move the
root files: 11 running containers bind-mount them by path.

## Rules

- Edit `settings.json` or `mcps/.mcp.json` (the masters) → run `scripts/build-profiles.sh`.
  `scripts/build-profiles.sh --check` exits 1 when a generated file is stale.
- Never hand-edit `profiles/{python,drupal}/settings.json` or `mcp.json`; the next build overwrites it.
  Drupal-only permission additions go in `profiles/drupal/allow-extra.json`; drop lists are the `DR_DROP_*` variables.
  Python-only permission additions go in `profiles/python/allow-extra.json`; drop lists are the `PY_DROP_*` variables in `build-profiles.sh`.
- New stack (node, go…): add `profiles/<stack>/`, a `gen_<stack>_*` pair in
  `build-profiles.sh`, an agents repo, and a `--stack` branch in `onboard-project.sh`.

## Onboarding

`scripts/onboard-project.sh --stack=python <project-dir>` writes the project's
`.ddev/docker-compose.ai.mounts.yaml`, `.ddev/config.claude-code.yaml`,
`.claude/rules-disable`, and appends `<ddev-name> <stack>` to `host/tooling-scope.txt`.
Template DDEV config for new Python projects: `~/workspace/proxiblue/ddev_project_template_python/`.
`--stack=drupal` (existing projects only) places `profiles/drupal/ddev/{docker-compose.ai.mounts.yaml,config.claude-code.yaml}`;
its post-start chowns the root-created mount parents and runs `hooks/seed-plugin-config.sh` (pb-graphiti `graphiti_url`).
First drupal project: ittools/ihop (2026-10-21).
