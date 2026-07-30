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
# Bypass: user must export `CLAUDE_PUSH_ALLOWED=1` in the shell session BEFORE
# starting claude. Inline `CLAUDE_PUSH_ALLOWED=1 git push ...` from inside a
# claude session does NOT work — the hook inspects the command string, so the
# prefix is still matched by the push pattern.
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
  echo "to confirm. The bypass env var must be exported BEFORE claude starts;" >&2
  echo "it cannot be set mid-session." >&2
  exit 2
}

# Pattern: git push to live or uat
if echo "$CMD" | grep -qE 'git[[:space:]]+push.*[[:space:]](live|uat)([[:space:]]|$|:)'; then
  block "git push to live/uat branch detected: '$CMD'"
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
