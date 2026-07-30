#!/bin/bash
# PreToolUse Bash hook — enforces the cardinal branch rule:
#
#   uat is only ever merged TO, never merged FROM.
#   Never merge uat into anything — ESPECIALLY not into live.
#
# uat is a UAT/staging (or, on some projects, the live-equivalent) branch. Its
# content flows IN (feature -> uat for testing / deploy) and never flows OUT.
# Merging, rebasing, or pulling uat INTO another branch drags unreviewed /
# staging state forward — into main, into a feature, or worst of all into live.
#
# Blocks (exit 2 = hard block, surfaces message to Claude):
#   - git merge  ... uat        (or origin/uat, */uat)     -> uat as merge source
#   - git rebase ... uat        (or */uat)                 -> rebasing onto uat
#   - git pull <remote> uat     (into a non-uat branch)    -> pull = fetch+merge
#
# Allows:
#   - Merging INTO uat: `git checkout uat && git merge feature` (uat is target,
#     source is "feature" — uat is never named as the source arg).
#   - Updating uat from its own remote while ON uat: `git pull origin uat` when
#     the current branch resolves to uat (best-effort branch check).
#
# Bypass: export `CLAUDE_MERGE_ALLOWED=1` in the shell session BEFORE starting
# claude. Inline prefix from inside a session does NOT work — the hook scans the
# command string, so the prefix is still present when the pattern is matched.
#
# Defensive: NO `set -e`. Silent no-op if jq missing or input unparseable —
# never blocks on infrastructure failure.

# Honor user bypass for this session
[ "${CLAUDE_MERGE_ALLOWED:-0}" = "1" ] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null)
[ -z "$CMD" ] && exit 0

block() {
  echo "BLOCKED by merge-guard.sh: $1" >&2
  echo "" >&2
  echo "CARDINAL RULE: uat is merged TO, never FROM. Never merge uat into" >&2
  echo "anything — especially not into live." >&2
  echo "" >&2
  echo "STOP. Do NOT retry. Do NOT work around:" >&2
  echo "  - Do not prefix CLAUDE_MERGE_ALLOWED=1 (the hook scans the command" >&2
  echo "    string, so the prefix is still caught by the pattern)." >&2
  echo "  - Do not wrap in bash -c, eval, env, or a heredoc to disguise it." >&2
  echo "  - Do not invoke a skill, sub-agent, or background task to do it." >&2
  echo "  - Do not read or modify this hook to find a way around it." >&2
  echo "" >&2
  echo "If you meant to merge INTO uat, put uat as the checked-out branch and" >&2
  echo "name the OTHER branch as the source. If this really is the legit" >&2
  echo "'update uat from its own remote' case, tell the user to run it" >&2
  echo "themselves. The bypass env var must be exported BEFORE claude starts." >&2
  exit 2
}

# Best-effort current branch (hook runs in Claude's cwd; may be wrong if the
# command cd's elsewhere — fail safe: unknown/!=uat still blocks).
CURBR=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

# uat named as a merge SOURCE: `git merge [flags] [remote/]uat[ :^~]`
if echo "$CMD" | grep -qE 'git[[:space:]]+merge([[:space:]]|.)*[[:space:]/]uat([[:space:]]|$|:|\^|~)'; then
  block "git merge FROM uat detected: '$CMD'"
fi

# Rebasing current branch onto uat: `git rebase [flags] [remote/]uat`
if echo "$CMD" | grep -qE 'git[[:space:]]+rebase([[:space:]]|.)*[[:space:]/]uat([[:space:]]|$|:|\^|~)'; then
  block "git rebase ONTO uat detected (pulls uat content forward): '$CMD'"
fi

# Pull merges the named branch into the current one. `git pull <remote> uat`
# into a non-uat branch = merging uat FROM. Allow only when on uat itself.
if echo "$CMD" | grep -qE 'git[[:space:]]+pull([[:space:]]|.)*[[:space:]]uat([[:space:]]|$|:)'; then
  if [ "$CURBR" != "uat" ]; then
    block "git pull FROM uat into '${CURBR:-unknown}' detected: '$CMD'"
  fi
fi

exit 0
