#!/bin/bash
# PostToolUse Edit|Write hook — reminds immediately when a hook script
# (hooks/*.sh or hooks/*.py, excluding *.test.sh itself) is written/edited
# without a sibling <name>.test.sh existing.
#
# Why: 2026-09-02 audit found rule-evals.sh's "before moving pin" gate only
# covered 3 of ~18 wired hooks — a version bump could silently break
# push-guard/git-tree-guard/merge-guard/etc. and the gate would still report
# clean. Fixed by making rule-evals.sh auto-discover and run every
# hooks/*.test.sh (see its header). That fix only has teeth if a NEW hook
# can't quietly land without a matching test file — hence this reminder,
# firing at the moment of authorship (same "just-in-time, not diluted 100k
# tokens later" reasoning as test-failure-context.sh) rather than relying on
# a prose rule or a periodic audit to catch the gap again.
#
# Non-blocking (informational, like post-commit-wiki-check.sh / tsc-edit-
# check.sh) — a test file legitimately might land in the very next edit
# within the same turn, and this isn't a destructive/irreversible action
# worth hard-blocking over.
#
# Per-project opt-out: line `hook-needs-eval-check` in
# <repo>/.claude/rules-disable.
#
# Defensive: NO set -e. Silent no-op if jq missing or input unparseable.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

F=$(echo "$INPUT" | jq -r '.tool_input.file_path // .file_path // ""' 2>/dev/null)
[ -z "$F" ] && exit 0

# Only fire for hook scripts themselves, under a hooks/ directory, not test
# files and not this checker's own kind of file.
case "$F" in
  */hooks/*.test.sh) exit 0 ;;
  */hooks/*.sh|*/hooks/*.py) ;;
  *) exit 0 ;;
esac

BASENAME=$(basename "$F")
STEM="${BASENAME%.*}"
DIR=$(dirname "$F")

# Per-project opt-out
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$TOPLEVEL" ] && [ -f "$TOPLEVEL/.claude/rules-disable" ]; then
  grep -qx 'hook-needs-eval-check' "$TOPLEVEL/.claude/rules-disable" 2>/dev/null && exit 0
fi

# Billing-family hooks share one combined test file
# (billing-context-guard.test.sh) rather than one per script — check that
# instead of a same-stem file for those three.
case "$STEM" in
  billing-precompact-guard|billing-clear-end|billing-clear-start)
    [ -f "$DIR/billing-context-guard.test.sh" ] && exit 0
    echo "[hook-needs-eval-check] $F has no test coverage — expected $DIR/billing-context-guard.test.sh (the billing-context-guard family's combined test file) to cover it. Add the missing case there now, not later." >&2
    exit 0
    ;;
esac

[ -f "$DIR/${STEM}.test.sh" ] && exit 0

echo "[hook-needs-eval-check] $F was just written with no ${STEM}.test.sh alongside it." >&2
echo "" >&2
echo "Every hook wired into settings.json's hooks{} block must ship a" >&2
echo "co-located unit test in the SAME change — feed it synthetic PreToolUse/" >&2
echo "PostToolUse JSON on stdin, assert exit code / output / side effect. See" >&2
echo "hooks/push-guard.test.sh or hooks/git-tree-guard.test.sh for the pattern." >&2
echo "Without it, rule-evals.sh's auto-discovery sweep (hooks/*.test.sh) can't" >&2
echo "catch this hook silently breaking on a future version bump." >&2
echo "" >&2
echo "Genuinely don't need one (e.g. a throwaway experiment, not wired into" >&2
echo "any settings.json)? Tell the user, or add 'hook-needs-eval-check' to" >&2
echo ".claude/rules-disable." >&2

exit 0
