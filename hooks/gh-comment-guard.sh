#!/bin/bash
# PreToolUse Bash hook — enforces the AI ticket-comment rule mechanically:
#
#   Every AI-posted GitHub/GitLab ticket comment goes through
#   gh-comment-hidden.sh (posts + minimizes as off-topic), never bare
#   `gh issue/pr comment`. Content: max 5 lines, caveman, status prefix.
#
# Replaces the always-loaded rules/gh-ticket-comments.md prose (kept as
# on-demand reference). Origin: ITToolsAU/LaptopLCDScreen #352.
#
# Blocks (exit 2):
#   - gh issue comment / gh pr comment (bare)
#   - gh api ...comments... (comment-posting via API)
#   - glab issue note / glab mr note
# Allows:
#   - anything routed through gh-comment-hidden.sh
#   - read-only comment listing (gh api GET, gh issue view)
#
# Per-project opt-out: add the line `gh-comment-guard` to
# <repo>/.claude/rules-disable (one hook name per line).
#
# Defensive: NO set -e. Silent no-op if jq missing or input unparseable.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null)
[ -z "$CMD" ] && exit 0

# Per-project opt-out
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$TOPLEVEL" ] && [ -f "$TOPLEVEL/.claude/rules-disable" ]; then
  grep -qx 'gh-comment-guard' "$TOPLEVEL/.claude/rules-disable" 2>/dev/null && exit 0
fi

# Sanctioned path
echo "$CMD" | grep -q 'gh-comment-hidden\.sh' && exit 0

block() {
  echo "BLOCKED by gh-comment-guard.sh: $1" >&2
  echo "" >&2
  echo "RULE: AI ticket comments post via the helper script ONLY (it posts" >&2
  echo "then minimizes the comment as off-topic in one call):" >&2
  echo "  host:      ~/claude-skills-central/scripts/gh-comment-hidden.sh <repo> <n> \"<body>\"" >&2
  echo "  container: /var/www/html/.claude/scripts/gh-comment-hidden.sh <repo> <n> \"<body>\"" >&2
  echo "" >&2
  echo "CONTENT RULES (caveman): max 5 lines. Outcomes only, past tense." >&2
  echo "Start with ONE status prefix: Done. / Blocked. / Needs input. /" >&2
  echo "UAT done. / Deployed. / Reverted. / Reproduced. / Cannot reproduce." >&2
  echo "No headers, tables, reasoning, 'I' statements, emojis. Diagnosis" >&2
  echo "belongs in the PR description or commit body, not the ticket." >&2
  echo "GitLab: same content rules; no minimize API — post terse and move on." >&2
  echo "" >&2
  echo "Full reference: rules/gh-ticket-comments.md (claude-skills-central)." >&2
  echo "Do not work around via gh api, heredocs, or sub-agents." >&2
  exit 2
}

if echo "$CMD" | grep -qE 'gh[[:space:]]+(issue|pr)[[:space:]]+comment'; then
  block "bare gh comment detected: '$CMD'"
fi

# Comment creation via API (POST/-f body to a comments endpoint)
if echo "$CMD" | grep -qE 'gh[[:space:]]+api' && echo "$CMD" | grep -q 'comments' \
   && echo "$CMD" | grep -qE '(-f|--field|--method[[:space:]]+POST|-X[[:space:]]+POST)'; then
  block "gh api comment-post detected: '$CMD'"
fi

if echo "$CMD" | grep -qE 'glab[[:space:]]+(issue|mr)[[:space:]]+note'; then
  block "bare glab note detected: '$CMD'"
fi

exit 0
