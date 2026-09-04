#!/bin/bash
# PreToolUse Bash hook — blocks the cardinal-rule push / SSH-live violations.
#
# Input: Claude Code sends the tool JSON on stdin. Format matches what the
# existing post-commit-wiki-check.sh expects: `.tool_input.command` for Bash.
#
# Blocks (exit 2 = hard block, surfaces message to Claude):
#   - git push to live / uat branches (`git push ... live`, `git push ... uat`)
#   - git push --force (any branch)
#   - SSH to anything matching live host patterns
#   - ddev push (deploys)
#
# Allows:
#   - git push to feature/* and other non-deployment branches
#   - SSH for read-only investigation when target doesn't match live patterns
#
# Bypass (live — the ONLY escape hatch): user must export
# `CLAUDE_PUSH_ALLOWED=1` in the shell session BEFORE starting claude. Inline
# `CLAUDE_PUSH_ALLOWED=1 git push ...` from inside a claude session does NOT
# work — the hook inspects the command string, so the prefix is still matched
# by the push pattern.
#
# Bypass (uat only): a narrow, single-use marker file at
# `<git-dir>/.claude-uat-push-authorized`, containing a unix timestamp,
# authorizes exactly one `git push ... uat`. Consumed (deleted) on first read
# whether valid or not; expires after 10 minutes if unused. Written only by
# the uat-deploy-verify skill, only immediately before its own authorized
# push, after its own reproduce+confirm gate. Never authorizes a live push.
#
# Defensive: NO `set -e` (so a partial parse failure doesn't kill the script).
# Silent if jq missing or input unparseable — never blocks on infrastructure.

# Honor user bypass for this session
[ "${CLAUDE_PUSH_ALLOWED:-0}" = "1" ] && exit 0

# jq required for input parsing — if missing, silent no-op (don't block any work).
command -v jq >/dev/null 2>&1 || exit 0

# Read tool JSON from stdin
INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

# Extract the command — supports both nested (current Claude Code format) and
# flat (older / direct invocation) shapes.
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null)
[ -z "$CMD" ] && exit 0

block() {
  echo "BLOCKED by push-guard.sh: $1" >&2
  echo "" >&2
  echo "STOP. Do NOT retry this command. Do NOT attempt any workaround:" >&2
  echo "  - Do not prefix with CLAUDE_PUSH_ALLOWED=1 (the hook scans the command" >&2
  echo "    string, so the prefix is still caught by the push pattern)." >&2
  echo "  - Do not wrap in bash -c, eval, env, or a heredoc to disguise it." >&2
  echo "  - Do not invoke a skill, sub-agent, or background task to push for you." >&2
  echo "  - Do not read or modify this hook to find a way around it." >&2
  echo "" >&2
  echo "Instead: tell the user to run the push themselves and wait for them" >&2
  echo "to confirm. The env-var bypass must be exported BEFORE claude starts;" >&2
  echo "it cannot be set mid-session. A uat push can also go through the" >&2
  echo "uat-deploy-verify skill, which has its own sanctioned gate." >&2
  exit 2
}

# Pattern: git push to live — always blocked, no bypass from within a session
# (CLAUDE_PUSH_ALLOWED=1 exported before `claude` starts is the only escape hatch).
if echo "$CMD" | grep -qE 'git[[:space:]]+push.*[[:space:]]live([[:space:]]|$|:)'; then
  block "git push to live branch detected: '$CMD'"
fi

# Pattern: git push to uat — same block, EXCEPT a narrow single-use marker
# authorizes exactly one push. Only the uat-deploy-verify skill writes this
# marker (right before its own authorized push, after its own gate checks). It is
# consumed (deleted) on first read whether valid or not, and expires after
# 10 minutes, so it can never sit around to authorize an unrelated push.
if echo "$CMD" | grep -qE 'git[[:space:]]+push.*[[:space:]]uat([[:space:]]|$|:)'; then
  GIT_DIR=$(git rev-parse --git-dir 2>/dev/null)
  MARKER="${GIT_DIR:-.git}/.claude-uat-push-authorized"
  if [ -f "$MARKER" ]; then
    AUTH_TS=$(cat "$MARKER" 2>/dev/null | tr -d '[:space:]')
    rm -f "$MARKER"
    NOW=$(date +%s)
    if echo "$AUTH_TS" | grep -qE '^[0-9]+$' && [ $((NOW - AUTH_TS)) -le 600 ]; then
      exit 0
    fi
  fi
  block "git push to uat branch detected: '$CMD'"
fi

# Pattern: git push --force / --force-with-lease anywhere
if echo "$CMD" | grep -qE 'git[[:space:]]+push.*(-f([[:space:]]|$)|--force([[:space:]]|$|-with-lease))'; then
  block "git push --force detected: '$CMD'"
fi

# Pattern: ddev push (deploys to a remote env)
if echo "$CMD" | grep -qE '(^|[[:space:];&|])ddev[[:space:]]+push([[:space:]]|$)'; then
  block "ddev push detected: '$CMD'"
fi

# Pattern: SSH to obvious live hosts
if echo "$CMD" | grep -qE 'ssh[[:space:]]+[^[:space:]]*(live|prod|production)[\.@]'; then
  block "SSH to live/prod host detected: '$CMD'"
fi

exit 0
