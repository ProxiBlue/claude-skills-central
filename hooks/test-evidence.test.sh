#!/bin/bash
# Test suite for test-evidence.sh (PostToolUse Bash recorder) — feeds
# PostToolUse JSON against a scratch git repo and asserts what lands in
# <git-dir>/claude-test-gate/evidence.jsonl. Run: bash test-evidence.test.sh
# (exit 0 = all green). Covers the 2026-09-26 pipe-masking hole: a runner
# piped into tail/grep/tee must NOT record evidence unless pipefail is set.

HOOK="$(cd "$(dirname "$0")" && pwd)/test-evidence.sh"
PASS=0; FAIL=0

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }

REPO=$(mktemp -d)
trap 'rm -rf "$REPO"' EXIT
( cd "$REPO" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init ) || { echo "FAIL: cannot init scratch repo"; exit 1; }
EF="$REPO/.git/claude-test-gate/evidence.jsonl"

run_hook() { # run_hook <command-string> -> stdout of hook
  jq -n --arg c "$1" --arg cwd "$REPO" \
    '{tool_name:"Bash", tool_input:{command:$c}, tool_response:{stdout:"",stderr:""}, cwd:$cwd}' \
    | bash "$HOOK" 2>/dev/null
}

t() { # t <expected-record-count> <expect-pipefail-note 0|1> <desc> <command>
  local expect="$1" note="$2" desc="$3" cmd="$4" out got n=0
  rm -f "$EF"
  out=$(run_hook "$cmd")
  [ -f "$EF" ] && n=$(grep -c '"type":"test"' "$EF")
  got=0; printf '%s' "$out" | grep -q 'pipefail' && got=1
  if [ "$n" = "$expect" ] && [ "$got" = "$note" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL ($desc): expected $expect record(s)/note=$note got $n/note=$got — cmd: $cmd"; fi
}

# --- clean runner invocations — recorded ---------------------------------------
t 1 0 "plain phpunit"            'vendor/bin/phpunit --testsuite unit'
t 1 0 "phpunit with redirect"    'vendor/bin/phpunit --testsuite unit > /tmp/out.log 2>&1'
t 1 0 "playwright plain"         'npx playwright test tests/a.spec.ts --project=chromium'
t 1 0 "|| is not a pipe"         'vendor/bin/phpunit --filter X || true'
t 2 0 "chain yields both families" 'vendor/bin/phpunit --testsuite unit && npx playwright test a.spec.ts'
t 1 0 "pipefail prefix + pipe"   'set -o pipefail; vendor/bin/phpunit --testsuite unit | tail -40'
# `bash -c "…"` wrapping is not a recognised runner wrapper in tg_test_families
# (pre-existing behaviour, not a regression): nothing recorded, nothing said.
t 0 0 "bash -c wrapper unrecognised" 'bash -o pipefail -c "vendor/bin/phpunit | tail -20"'
t 1 0 "pipe BEFORE the runner"   'cat /dev/null | vendor/bin/phpunit --testsuite unit'

# --- pipe-masked runner — refused, agent told about pipefail -------------------
t 0 1 "phpunit | tail"           'vendor/bin/phpunit --testsuite unit | tail -40'
t 0 1 "phpunit 2>&1 | tail"      'vendor/bin/phpunit --testsuite unit 2>&1 | tail -60'
t 0 1 "phpunit | grep"           'vendor/bin/phpunit --testsuite unit 2>&1 | grep -E "Tests:|OK"'
t 0 1 "playwright | tee"         'npx playwright test a.spec.ts 2>&1 | tee /tmp/pw.log'
t 0 1 "cd && phpunit | head"     "cd $REPO && vendor/bin/phpunit --testsuite unit | head -50"
t 0 1 "yarn test | tail"         'yarn test:unit 2>&1 | tail -20'

# --- non-runner commands — nothing recorded, no note ---------------------------
t 0 0 "grep mentions phpunit"    'git status | grep phpunit'
t 0 0 "echo phpunit | cat"       'echo "run phpunit later" | cat'
t 0 0 "plain git"                'git log --oneline -3'

t 0 0 "pgrep probe with quoted runner names" "pgrep -af 'playwright|phpunit' | cut -c1-80"
t 0 1 "quoted filter pipe, real pipe masks" 'vendor/bin/phpunit --filter "A|B" | tail -3'

# --- harness auto-background / interrupt — refused (pps #519 false pass) -------
tbg() { # tbg <desc> <tool_response-json>
  local desc="$1" resp="$2" n=0 out
  rm -f "$EF"
  out=$(jq -n --arg c 'npx playwright test a.spec.ts' --arg cwd "$REPO" --argjson r "$resp" \
    '{tool_name:"Bash", tool_input:{command:$c}, tool_response:$r, cwd:$cwd}' | bash "$HOOK" 2>/dev/null)
  [ -f "$EF" ] && n=$(grep -c '"type":"test"' "$EF")
  if [ "$n" = "0" ] && printf '%s' "$out" | grep -q 'background'; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL ($desc): expected 0 records + background note, got $n — $out"; fi
}
tbg "auto-backgrounded run" '{"stdout":"","stderr":"","interrupted":false,"backgroundTaskId":"b1x","timedOutAfterMs":600000}'
tbg "interrupted run"       '{"stdout":"","stderr":"","interrupted":true}'

echo "test-evidence.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
