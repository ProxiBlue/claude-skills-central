#!/bin/bash
# Test suite for test-bg-guard.sh — feed PreToolUse JSON, assert exit code.
# Run: bash test-bg-guard.test.sh   (exit 0 = all green)

HOOK="$(cd "$(dirname "$0")" && pwd)/test-bg-guard.sh"
PASS=0; FAIL=0

# run <expected-exit> <desc> <command> [timeout] [bg] [cwd]
run() {
  local expect="$1" desc="$2" cmd="$3" to="${4:-}" bg="${5:-}" cwd="${6:-}"
  local json
  json=$(jq -n --arg c "$cmd" --arg to "$to" --arg bg "$bg" --arg cwd "$cwd" '
    {tool_name:"Bash", tool_input:{command:$c}}
    | if $to  != "" then .tool_input.timeout = ($to|tonumber) else . end
    | if $bg  != "" then .tool_input.run_in_background = ($bg=="true") else . end
    | if $cwd != "" then .cwd = $cwd else . end')
  printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL ($desc): expected $expect got $got — $cmd [timeout=$to bg=$bg]"; fi
}

# --- the core trap: e2e with no / too small a timeout ------------------------
run 2 "playwright, no timeout"        'npx playwright test tests/vtpay.spec.ts'
run 2 "playwright, default 120s"      'npx playwright test tests/vtpay.spec.ts' 120000
run 2 "playwright, 299999 just under" 'npx playwright test tests/vtpay.spec.ts' 299999
run 0 "playwright, 300000 exactly"    'npx playwright test tests/vtpay.spec.ts' 300000
run 0 "playwright, 400000 ample"      'npx playwright test tests/vtpay.spec.ts' 400000

# the reported repro, verbatim shape (thread c91f5a24)
run 2 "repro: cd + APP_NAME + workers" 'cd tests/apps/pps && APP_NAME=pps npx playwright test tests/vtpay.spec.ts --workers=1'
run 0 "repro with explicit timeout"    'cd tests/apps/pps && APP_NAME=pps npx playwright test tests/vtpay.spec.ts --workers=1' 400000

# --- explicit backgrounding is blocked regardless of timeout ----------------
run 2 "run_in_background, ample timeout" 'npx playwright test x.spec.ts' 900000 true
run 0 "run_in_background false"          'npx playwright test x.spec.ts' 400000 false

# --- other e2e runners ------------------------------------------------------
run 2 "npm run e2e"        'npm run e2e'
run 2 "yarn e2e"           'yarn e2e'
run 2 "codecept run"       'codecept run'
run 2 "behat"              'behat'
run 0 "npm run e2e, timed" 'npm run e2e' 600000

# --- unit family untouched (finishes inside the default) --------------------
run 0 "phpunit no timeout"   'vendor/bin/phpunit'
run 0 "jest no timeout"      'npx jest'
run 0 "vitest no timeout"    'npx vitest run'
run 0 "npm test no timeout"  'npm test'
run 0 "magento dev:tests:run" 'php bin/magento dev:tests:run unit'

# --- not a test command at all ---------------------------------------------
run 0 "grep mentions playwright" 'grep -r playwright .'
run 0 "echo mentions playwright" 'echo "run playwright test"'
run 0 "ls"                       'ls -la'
run 0 "git commit"               'git commit -m x'
run 0 "cat playwright.config.ts" 'cat playwright.config.ts'

# --- per-project config + opt-out (needs a real repo for ROOT) -------------
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
git -c init.defaultBranch=main init -q "$TMP" 2>/dev/null
mkdir -p "$TMP/.claude"

run 2 "repo, no config"      'npx playwright test a.spec.ts' ''      '' "$TMP"

printf '{"e2e_min_timeout_ms": 60000}\n' > "$TMP/.claude/test-gate.json"
run 0 "custom floor 60s, 60000"  'npx playwright test a.spec.ts' 60000 '' "$TMP"
run 2 "custom floor 60s, 59999"  'npx playwright test a.spec.ts' 59999 '' "$TMP"

printf '{"enabled": false}\n' > "$TMP/.claude/test-gate.json"
run 0 "gate disabled -> skip"    'npx playwright test a.spec.ts' ''    '' "$TMP"

printf '{"e2e_min_timeout_ms": 300000}\n' > "$TMP/.claude/test-gate.json"
printf 'test-bg-guard\n' > "$TMP/.claude/rules-disable"
run 0 "rules-disable opt-out"    'npx playwright test a.spec.ts' ''    '' "$TMP"
printf 'some-other-guard\n' > "$TMP/.claude/rules-disable"
run 2 "unrelated opt-out line"   'npx playwright test a.spec.ts' ''    '' "$TMP"

# --- fails soft -------------------------------------------------------------
echo '' | bash "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: empty input should no-op"; }
echo 'not json' | bash "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: garbage input should no-op"; }

echo "test-bg-guard: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
