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

cd /
rm -rf "$D"

echo "playwright-trace-guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
