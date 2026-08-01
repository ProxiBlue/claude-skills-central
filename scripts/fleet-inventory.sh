#!/bin/bash
# Phase-0 consolidation inventory — READ-ONLY sweep of all ddev projects.
# Emits one line-block per project + relies on caller for summarising.

PROJECTS=$(ddev list -j 2>/dev/null | jq -r '.raw[] | "\(.name)\t\(.approot)\t\(.status)"' 2>/dev/null)
if [ -z "$PROJECTS" ]; then
  echo "ddev list failed — falling back to known dirs" >&2
  exit 1
fi

echo "$PROJECTS" | while IFS=$'\t' read -r NAME ROOT STATUS; do
  [ -d "$ROOT" ] || { echo "=== $NAME | MISSING DIR $ROOT"; continue; }
  cd "$ROOT" 2>/dev/null || continue

  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "no-git")
  DIRTY=$(git status --porcelain 2>/dev/null | wc -l)

  # claude-code pin mechanics
  PIN="none"
  grep -rq 'DISABLE_AUTOUPDATER' .ddev/ 2>/dev/null && PIN="autoupdater-off"
  PINVER=$(grep -rhoE '2\.1\.[0-9]+' .ddev/web-build/Dockerfile* .ddev/config.yaml .ddev/hooks 2>/dev/null | sort -u | tr '\n' ',' )

  # HCF / pb-hcf wire state
  PIPELINE="no"; [ -f .claude/pipeline.md ] && PIPELINE="YES-LEGACY"
  WIRES="no"; [ -f .claude/wires.json ] && WIRES="yes"
  AGENTS=$(ls .claude/agents/*.md 2>/dev/null | wc -l)
  ENROLLED=$(grep -l 'phase:' .claude/agents/*.md 2>/dev/null | wc -l)

  # dangling pipeline refs in project CLAUDE.md files
  DANGLING=$(grep -l 'pipeline\.md' CLAUDE.md .claude/CLAUDE.md 2>/dev/null | tr '\n' ',' )

  # mounts + stubs
  AIMOUNT="no"; ls .ddev/docker-compose*mounts*.yaml >/dev/null 2>&1 && AIMOUNT="yes"
  MCPSTUB="-"
  if [ -f .mcp.json ]; then
    SZ=$(stat -c%s .mcp.json 2>/dev/null); [ "$SZ" = "0" ] && MCPSTUB="ZERO-BYTE-STUB" || MCPSTUB="ok($SZ b)"
  fi

  # fleet rules: AGENT_TEAMS + ddev-generated marker in claude command
  CMD=.ddev/commands/web/claude
  TEAMS="-"; MARKER="-"
  if [ -f "$CMD" ]; then
    grep -q 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1' "$CMD" && TEAMS="yes" || TEAMS="MISSING"
    grep -q '#ddev-generated' "$CMD" && MARKER="HAS-MARKER(bad)" || MARKER="ok"
  fi

  # per-project gate/rules config
  TG="-"; [ -f .claude/test-gate.json ] && TG=$(jq -c . .claude/test-gate.json 2>/dev/null | head -c 60)
  RD="-"; [ -f .claude/rules-disable ] && RD=$(tr '\n' ',' < .claude/rules-disable)

  # settings freshness (running containers only): does mounted settings match central?
  FRESH="-"
  if [ "$STATUS" = "running" ]; then
    CSUM=$(md5sum ~/claude-skills-central/settings.json | cut -d' ' -f1)
    MSUM=$(ddev exec -s web md5sum /var/www/html/.claude/settings.json </dev/null 2>/dev/null | cut -d' ' -f1)
    if [ -n "$MSUM" ]; then [ "$CSUM" = "$MSUM" ] && FRESH="in-sync" || FRESH="STALE-MOUNT"; fi
  fi

  echo "=== $NAME | $STATUS | $ROOT"
  echo "    branch=$BRANCH dirty=$DIRTY | pin=$PIN ver=[${PINVER%,}]"
  echo "    pipeline.md=$PIPELINE wires=$WIRES agents=$AGENTS enrolled=$ENROLLED dangling=[${DANGLING%,}]"
  echo "    ai-mounts=$AIMOUNT mcp-stub=$MCPSTUB teams=$TEAMS marker=$MARKER"
  echo "    test-gate.json=$TG rules-disable=$RD settings=$FRESH"
done
