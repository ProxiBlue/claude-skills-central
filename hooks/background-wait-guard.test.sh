#!/bin/bash
# Test suite for background-wait-guard.sh — feed PreToolUse JSON, assert exit
# code. Run: bash background-wait-guard.test.sh   (exit 0 = all green)

HOOK="$(cd "$(dirname "$0")" && pwd)/background-wait-guard.sh"
PASS=0; FAIL=0

t() { # t <expected-exit> <desc> <command-string>
  local expect="$1" desc="$2" cmd="$3"
  jq -n --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}' \
    | bash "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL ($desc): expected exit $expect got $got — cmd: $cmd"; fi
}

# --- process-liveness polling loops — blocked --------------------------------
# The exact shape from the 2026-09-18 tdd-004/tdd-005 incident.
t 2 "pgrep wait loop"        'while pgrep -f playwright >/dev/null; do sleep 10; done'
t 2 "pgrep negated"          'while ! pgrep -f "playwright test" >/dev/null 2>&1; do sleep 5; done'
t 2 "until pgrep"            'until ! pgrep -f phpunit; do sleep 15; done'
t 2 "kill -0 pid loop"       'while kill -0 "$PID" 2>/dev/null; do sleep 5; done'
t 2 "pidof loop"             'while pidof node; do sleep 3; done'
t 2 "ps aux grep loop"       'while ps aux | grep -q [p]laywright; do sleep 10; done'
t 2 "proc dir loop"          'while [ -d /proc/$PID ]; do sleep 2; done'

# --- marker-file polling loops — blocked --------------------------------------
t 2 "marker file until"      'until [ -f /tmp/run.done ]; do sleep 5; done'
t 2 "marker file while not"  'while [ ! -f /tmp/pw.done ]; do sleep 5; done'
t 2 "test -f form"           'until test -f /tmp/done.marker; do sleep 5; done'
t 2 "bracket-bracket form"   'while [[ ! -e /tmp/run.done ]]; do sleep 4; done'

# --- detached test runs — blocked ---------------------------------------------
t 2 "playwright trailing &"  'npx playwright test tests/vt.spec.ts > /tmp/out.log 2>&1 &'
t 2 "nohup playwright"       'nohup npx playwright test > /tmp/out.log 2>&1 &'
t 2 "phpunit trailing &"     'vendor/bin/phpunit --testsuite unit &'
t 2 "npm test detached"      'npm test &'
t 2 "vitest detached"        'npx vitest run &'
t 2 "nohup phpunit no amp"   'nohup vendor/bin/phpunit --testsuite unit'
t 2 "ddev playwright bg"     'ddev exec npx playwright test --project=chromium &'

# --- legitimate foreground runs — allowed -------------------------------------
t 0 "foreground playwright"  'npx playwright test tests/vt-billing.spec.ts'
t 0 "foreground phpunit"     'vendor/bin/phpunit --filter testBillingAddressSelect'
t 0 "foreground with redirect" 'npx playwright test > /tmp/out.log 2>&1'
t 0 "pipeline not background" 'npx playwright test | tail -40'
t 0 "background non-test"     'php -S localhost:8080 &'

# --- loops that do real work — allowed (need all three signals to block) ------
t 0 "curl readiness retry"   'until curl -sf http://localhost:8080/health; do sleep 2; done'
t 0 "loop without sleep"     'while pgrep -f playwright; do echo still running; done'
t 0 "sleep without loop"     'sleep 30; npx playwright test'
t 0 "loop+sleep, no probe"   'while read -r line; do sleep 1; echo "$line"; done < input.txt'
t 0 "bare pgrep, no loop"    'pgrep -f playwright'
t 0 "bare ps"                'ps aux | grep node'

# --- unrelated commands — allowed ---------------------------------------------
t 0 "plain echo"             'echo hello'
t 0 "git commit"             'git commit -m "fix: thing"'
t 0 "composer install"       'composer install --no-dev'

# --- daemon bypass -------------------------------------------------------------
jq -n '{tool_name:"Bash", tool_input:{command:"nohup npx playwright test &"}}' \
  | CLAUDE_BG_WAIT_ALLOWED=1 bash "$HOOK" >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (CLAUDE_BG_WAIT_ALLOWED bypass): exit $RC"; }

# --- rules-disable opt-out ------------------------------------------------------
TMP=$(mktemp -d); (
  cd "$TMP" && git init -q . && mkdir -p .claude \
    && echo background-wait-guard > .claude/rules-disable
  jq -n '{tool_name:"Bash", tool_input:{command:"while pgrep -f playwright; do sleep 5; done"}}' \
    | bash "$HOOK" >/dev/null 2>&1
)
RC=$?
rm -rf "$TMP"
[ "$RC" = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (rules-disable opt-out): exit $RC"; }

echo "background-wait-guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
