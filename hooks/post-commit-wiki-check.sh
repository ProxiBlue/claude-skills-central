#!/bin/bash
# PostToolUse hook: remind to update wiki docs after pushing tracked branches.
# Triggers after `git push` to a configured branch when the project has a
# wiki/wiki-docs directory. Looks at recent commits for ticket numbers.
#
# Override the watched branches with: CLAUDE_WIKI_BRANCHES="live uat ..."

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only intercept git push commands
echo "$COMMAND" | grep -qE '(^|[[:space:]])git[[:space:]]+push([[:space:]]|$)' || exit 0

CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$CWD" ] && CWD=$(pwd)
[ -d "$CWD" ] || exit 0

PROJECT_ROOT=$(cd "$CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Determine pushed branch: explicit `git push <remote> <branch>` form, else current HEAD
BRANCH=$(echo "$COMMAND" | grep -oE 'git[[:space:]]+push[[:space:]]+[^[:space:]]+[[:space:]]+[A-Za-z0-9._/-]+' \
    | awk '{print $NF}' | head -1)
[ -z "$BRANCH" ] && BRANCH=$(cd "$PROJECT_ROOT" && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
[ -z "$BRANCH" ] && exit 0

WIKI_BRANCHES="${CLAUDE_WIKI_BRANCHES:-live uat main master production}"
echo " $WIKI_BRANCHES " | grep -q " $BRANCH " || exit 0

WIKI_DIR=""
for candidate in wiki wiki-docs docs/wiki .wiki; do
    if [ -d "$PROJECT_ROOT/$candidate" ]; then
        WIKI_DIR="$PROJECT_ROOT/$candidate"
        break
    fi
done
[ -z "$WIKI_DIR" ] && exit 0

RECENT_TICKETS=$(cd "$PROJECT_ROOT" && git log --oneline -5 "$BRANCH" 2>/dev/null \
    | grep -oE '(#[0-9]+|[A-Z]+-[0-9]+|GH-[0-9]+)' | sort -u | tr '\n' ' ')

[ -z "$RECENT_TICKETS" ] && exit 0

WIKI_PAGES=$(cd "$WIKI_DIR" 2>/dev/null && ls *.md 2>/dev/null | head -8 | tr '\n' ' ')

cat <<EOF
WIKI CHECK: Pushed to $BRANCH. Recent tickets: $RECENT_TICKETS
Verify wiki docs are up to date for these tickets.
Wiki dir: $WIKI_DIR
${WIKI_PAGES:+Wiki pages: $WIKI_PAGES}
EOF

exit 0
