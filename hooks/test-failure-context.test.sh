#!/bin/bash
# Test suite for test-failure-context.sh — feed PostToolUse JSON, assert
# stdout content (never blocks — exit always 0).
# Run: bash test-failure-context.test.sh

HOOK="$(cd "$(dirname "$0")" && pwd)/test-failure-context.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

D=$(mktemp -d); git -C "$D" init -q .
TMPOUT=$(mktemp)
cd "$D" || exit 1

run() { # run <command> <stdout> — plain foreground pipe, no subshell/command-sub
  # wrapper, so the hook's $PPID stays this script's own $$ every call,
  # matching the real single-session debounce behavior instead of a fresh
  # subshell PID each time.
  printf '{"tool_input":{"command":%s},"tool_response":{"stdout":%s},"cwd":%s}' \
    "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)" "$(printf '%s' "$D" | jq -Rs .)" \
    | bash "$HOOK" > "$TMPOUT" 2>/dev/null
  OUT=$(cat "$TMPOUT")
}

# --- fires: phpunit command + failure markers in output -----------------------
run 'vendor/bin/phpunit' 'FAILURES!
Tests: 5, Assertions: 8, Failures: 1.'
[ -n "$OUT" ] && ok || bad "expected injection on phpunit FAILURES! output"

rm -f "/tmp/claude-invest-inject-$$"

# --- fires: jest with failed count -----------------------------------------
run 'npm run test' '2 failed, 3 passed'
[ -n "$OUT" ] && ok || bad "expected injection on jest failure output"

rm -f "/tmp/claude-invest-inject-$$"

# --- silent: passing test run --------------------------------------------------
run 'vendor/bin/phpunit' 'OK (10 tests, 10 assertions)'
[ -z "$OUT" ] && ok || bad "expected silent on passing run, got: $OUT"

rm -f "/tmp/claude-invest-inject-$$"

# --- silent: non-test command --------------------------------------------------
run 'ls -la' 'file1 file2'
[ -z "$OUT" ] && ok || bad "expected silent on non-test command, got: $OUT"

rm -f "/tmp/claude-invest-inject-$$"

# --- debounce: second failure within 10min does not re-inject -----------------
run 'vendor/bin/phpunit' 'FAILURES!
Failures: 1.'
FIRST="$OUT"
run 'vendor/bin/phpunit' 'FAILURES!
Failures: 1.'
SECOND="$OUT"
[ -n "$FIRST" ] && [ -z "$SECOND" ] && ok || bad "expected debounce to suppress 2nd injection (first=[${FIRST:0:20}] second=[${SECOND:0:20}])"

rm -f "/tmp/claude-invest-inject-$$"
rm -f "$TMPOUT"
cd /
rm -rf "$D"

echo "test-failure-context tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
