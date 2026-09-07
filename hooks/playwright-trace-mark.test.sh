#!/bin/bash
# Test suite for playwright-trace-mark.sh — feed PostToolUse JSON, assert the
# marker file gets created/not created. Plain foreground pipe throughout (no
# subshell/command-sub wrapper) so the hook's $PPID stays this script's own
# $$ — required for the marker filename to be predictable.
# Run: bash playwright-trace-mark.test.sh

HOOK="$(cd "$(dirname "$0")" && pwd)/playwright-trace-mark.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

MARKER="/tmp/claude-pw-trace-seen-$$"

run() { # run <command>
  rm -f "$MARKER"
  printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)" | bash "$HOOK" >/dev/null 2>&1
}

# --- fires: unzip trace.zip ---------------------------------------------------
run 'unzip -o test-results/x/trace.zip -d /tmp/pw-trace'
[ -f "$MARKER" ] && ok || bad "expected marker after unzip trace.zip"

# --- fires: cat/strings/grep against trace.zip --------------------------------
run 'grep -r "locator resolved" /tmp/pw-trace'
[ ! -f "$MARKER" ] && ok || bad "grep with no trace.zip mention should not fire"
# (grep alone without trace.zip in the command string correctly does NOT fire —
# the hook requires the literal string trace.zip or 'playwright show-trace')

run 'cat trace.zip | grep locator'
[ -f "$MARKER" ] && ok || bad "expected marker after cat+grep trace.zip"

run 'playwright show-trace test-results/x/trace.zip'
[ -f "$MARKER" ] && ok || bad "expected marker after playwright show-trace"

# --- silent: producing a trace, not inspecting one -----------------------------
run 'npx playwright test --trace on'
[ ! -f "$MARKER" ] && ok || bad "expected no marker on a plain test run (produces, not inspects)"

# --- silent: mentions trace.zip but no inspection verb -------------------------
run 'echo "trace.zip was written to test-results/x/"'
[ ! -f "$MARKER" ] && ok || bad "expected no marker — path mention with no inspection verb"

# --- silent: unrelated command --------------------------------------------------
run 'ls -la'
[ ! -f "$MARKER" ] && ok || bad "expected no marker on unrelated command"

rm -f "$MARKER"

# --- 2026-09-07 fix: session_id takes priority over $PPID ---------------------
SESS="pw-mark-sess-test-$$"
SESS_MARKER="/tmp/claude-pw-trace-seen-$SESS"
rm -f "$SESS_MARKER"
printf '{"tool_input":{"command":"unzip -o trace.zip -d /tmp/pw"},"session_id":"%s"}' "$SESS" | bash "$HOOK" >/dev/null 2>&1
[ -f "$SESS_MARKER" ] && ok || bad "expected session_id-keyed marker, not \$PPID-keyed"
rm -f "$SESS_MARKER"

echo "playwright-trace-mark tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
