#!/bin/bash
# Test suite for playwright-trace-guard.sh — feed PreToolUse JSON in a
# scratch repo with/without a fresh trace.zip, assert exit code.
# Run: bash playwright-trace-guard.test.sh

HOOK="$(cd "$(dirname "$0")" && pwd)/playwright-trace-guard.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL ($1): expected exit $2 got $3"; }

D=$(mktemp -d)
cd "$D" || exit 1
git init -q .
mkdir -p test-results/some-test

t() { # t <expected-exit> <desc> <file_path>
  local expect="$1" desc="$2" fp="$3"
  printf '{"tool_input":{"file_path":%s}}' "$(printf '%s' "$fp" | jq -Rs .)" \
    | bash "$HOOK" >/dev/null 2>&1
  local got=$?
  [ "$got" = "$expect" ] && ok || bad "$desc" "$expect" "$got"
}

# --- no trace.zip present -> always allowed ----------------------------------
t 0 "spec file, no trace"    "$D/tests/login.spec.ts"
t 0 "page file, no trace"    "$D/tests/login.page.ts"
t 0 "config file, no trace"  "$D/playwright.config.ts"
t 0 "unrelated file"         "$D/src/App.tsx"

# --- fresh trace.zip present, no marker -> blocked ---------------------------
touch "$D/test-results/some-test/trace.zip"
t 2 "spec file, fresh trace, unseen"   "$D/tests/login.spec.ts"
t 0 "unrelated file still allowed"     "$D/src/App.tsx"
t 0 "node_modules path excluded"       "$D/node_modules/pkg/x.spec.ts"

# --- rules-disable opt-out ----------------------------------------------------
mkdir -p .claude && echo playwright-trace-guard > .claude/rules-disable
t 0 "opt-out via rules-disable" "$D/tests/login.spec.ts"
rm .claude/rules-disable

# --- marker newer than trace -> allowed (trace was "seen") -------------------
# Hook uses /tmp/claude-pw-trace-seen-$PPID where $PPID, inside `... | bash
# "$HOOK"`, is this test script's own PID (two-stage pipe, no intermediate
# process). Touch that marker AFTER the trace so it's newer.
sleep 1.1
touch "/tmp/claude-pw-trace-seen-$$"
t 0 "marker newer than trace -> allowed" "$D/tests/login.spec.ts"
rm -f "/tmp/claude-pw-trace-seen-$$"

# --- stale trace (>3h) -> allowed ---------------------------------------------
touch -d '4 hours ago' "$D/test-results/some-test/trace.zip"
t 0 "stale trace (>3h) allowed" "$D/tests/login.spec.ts"

# --- 2026-09-07 fix: session_id-keyed marker survives different $PPID --------
# The reported bug (pb-chatroom thread fa4f2504, pvcpipesupplies): guard.sh
# (PreToolUse) and mark.sh (PostToolUse) run as genuinely different parent
# processes in the real harness, so a $PPID-keyed marker never matched
# between them — the documented "won't fire again this session" unlock
# structurally never worked. Reproduce the actual failure mode by running
# each hook through its own backgrounded subshell (each gets a $PPID
# distinct from this script's and from each other's), sharing only
# session_id — proves the fix survives the real process boundary, not just
# a same-PID coincidence within one test script.
MARK_HOOK="$(dirname "$HOOK")/playwright-trace-mark.sh"
SESS="pw-sess-test-$$"
rm -f "/tmp/claude-pw-trace-seen-$SESS"
touch "$D/test-results/some-test/trace.zip"
( printf '{"tool_input":{"command":"unzip -o trace.zip -d /tmp/pw"},"session_id":"%s"}' "$SESS" \
    | bash "$MARK_HOOK" >/dev/null 2>&1 ) &
wait $!
if [ -f "/tmp/claude-pw-trace-seen-$SESS" ]; then
  ok
else
  bad "session_id marker created by mark.sh" "file exists" "missing"
fi
( printf '{"tool_input":{"file_path":"%s/tests/login.spec.ts"},"session_id":"%s"}' "$D" "$SESS" \
    | bash "$HOOK" >/dev/null 2>&1 )
got=$?
[ "$got" = 0 ] && ok || bad "session_id marker unlocks guard across the PreToolUse/PostToolUse boundary" 0 "$got"
rm -f "/tmp/claude-pw-trace-seen-$SESS"

# --- nested-repo TOPLEVEL resolution -----------------------------------------
# Same thread: a nested repo (its own .git inside the outer project) must
# resolve TOPLEVEL from the FILE's directory, and honor rules-disable from
# EITHER the nested repo root or the outer project root.
NESTED="$D/tests/m2-hyva-playwright"
mkdir -p "$NESTED/specs"
( cd "$NESTED" && git init -q . )
touch "$NESTED/specs/trace.zip"
t 2 "nested repo, fresh trace, blocked" "$NESTED/specs/login.spec.ts"
mkdir -p "$NESTED/.claude" && echo playwright-trace-guard > "$NESTED/.claude/rules-disable"
t 0 "nested repo's OWN rules-disable honored" "$NESTED/specs/login.spec.ts"
rm -rf "$NESTED/.claude"
mkdir -p "$D/.claude" && echo playwright-trace-guard > "$D/.claude/rules-disable"
t 0 "OUTER project root's rules-disable also honored from inside nested repo" "$NESTED/specs/login.spec.ts"
rm -rf "$D/.claude"

cd /
rm -rf "$D"

echo "playwright-trace-guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
