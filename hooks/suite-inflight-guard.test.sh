#!/bin/bash
# Test suite for suite-inflight-guard.sh — feed PreToolUse JSON, assert exit
# code. Process probe is faked via SUITE_INFLIGHT_PS_CMD so tests never
# depend on a real suite running. Run: bash suite-inflight-guard.test.sh

HOOK="$(cd "$(dirname "$0")" && pwd)/suite-inflight-guard.sh"
PASS=0; FAIL=0

FAKE_RUNNING=$(mktemp)
cat > "$FAKE_RUNNING" <<'EOF'
echo "48213 npx playwright test tests/vtpay.spec.ts --workers=4"
echo "48300 node /app/node_modules/.bin/playwright test --project=chromium"
EOF
FAKE_PHPUNIT=$(mktemp)
cat > "$FAKE_PHPUNIT" <<'EOF'
echo "9001 vendor/bin/phpunit --testsuite unit"
EOF
FAKE_PARATEST=$(mktemp)
cat > "$FAKE_PARATEST" <<'EOF'
echo "9002 vendor/bin/paratest -p4"
EOF
FAKE_NONE=$(mktemp)
: > "$FAKE_NONE"
# A probe result that is ONLY the hook's own pgrep call and its own name —
# must be filtered out and treated as "nothing running".
FAKE_SELF_ONLY=$(mktemp)
cat > "$FAKE_SELF_ONLY" <<'EOF'
echo "100 pgrep -af playwright|phpunit|paratest"
echo "101 bash /home/lucas/claude-skills-central/hooks/suite-inflight-guard.sh"
EOF

cleanup() { rm -f "$FAKE_RUNNING" "$FAKE_PHPUNIT" "$FAKE_PARATEST" "$FAKE_NONE" "$FAKE_SELF_ONLY"; }
trap cleanup EXIT

# t <expected-exit> <desc> <command-string> <fake-ps-file>
t() {
  local expect="$1" desc="$2" cmd="$3" psfile="$4"
  local got
  printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)" \
    | SUITE_INFLIGHT_PS_CMD="cat $psfile" bash "$HOOK" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL ($desc): expected exit $expect got $got — cmd: $cmd"
  fi
}

# --- blocked: churn + suite in flight (exit 2) -------------------------------
t 2 "bin/magento cache:clean, playwright running"            'bin/magento cache:clean' "$FAKE_RUNNING"
t 2 "php bin/magento cache:flush, playwright running"        'php bin/magento cache:flush' "$FAKE_RUNNING"
t 2 "ddev exec bin/magento setup:upgrade, playwright running" 'ddev exec bin/magento setup:upgrade' "$FAKE_RUNNING"
t 2 "ddev magento setup:di:compile, playwright running"      'ddev magento setup:di:compile' "$FAKE_RUNNING"
t 2 "setup:static-content:deploy, playwright running"        'bin/magento setup:static-content:deploy -f' "$FAKE_RUNNING"
t 2 "config:set, playwright running"                         'bin/magento config:set payment/stripe/mode test' "$FAKE_RUNNING"
t 2 "indexer:reindex, playwright running"                    'bin/magento indexer:reindex' "$FAKE_RUNNING"
t 2 "n98-magerun2 cache:flush, phpunit running"               'n98-magerun2 cache:flush' "$FAKE_PHPUNIT"
t 2 "n98-magerun2 config:store:set, paratest running"         'n98-magerun2 config:store:set web/unsecure/base_url x' "$FAKE_PARATEST"
t 2 "rm -rf pub/static, playwright running"                  'rm -rf pub/static/* var/view_preprocessed/*' "$FAKE_RUNNING"
t 2 "rm -rf generated, phpunit running"                      'rm -rf generated/*' "$FAKE_PHPUNIT"
t 2 "rm -rf var/cache, paratest running"                     'rm -rf var/cache/*' "$FAKE_PARATEST"
t 2 "rm -rf var/page_cache, playwright running"              'cd /var/www/html && rm -rf var/page_cache/*' "$FAKE_RUNNING"
t 2 "find -delete on var/cache, playwright running"           'find var/cache -type f -delete' "$FAKE_RUNNING"
t 2 "chained churn after real command, playwright running"    'git status && bin/magento cache:clean' "$FAKE_RUNNING"

# --- allowed: read-only magento commands, suite running (exit 0) ------------
t 0 "cache:status, playwright running"      'bin/magento cache:status' "$FAKE_RUNNING"
t 0 "config:show, playwright running"       'bin/magento config:show' "$FAKE_RUNNING"
t 0 "indexer:status, playwright running"    'bin/magento indexer:status' "$FAKE_RUNNING"

# --- allowed: churn command but nothing running (exit 0) --------------------
t 0 "cache:clean, nothing running"          'bin/magento cache:clean' "$FAKE_NONE"
t 0 "rm -rf generated, nothing running"     'rm -rf generated/*' "$FAKE_NONE"
t 0 "cache:clean, only self-probe in list"  'bin/magento cache:clean' "$FAKE_SELF_ONLY"

# --- allowed: unrelated commands regardless of suite state -------------------
t 0 "unrelated rm, playwright running"      'rm -rf /tmp/scratch' "$FAKE_RUNNING"
t 0 "git status, playwright running"        'git status' "$FAKE_RUNNING"
t 0 "echo mentions cache:clean, running"    'echo "remember to run cache:clean later"' "$FAKE_RUNNING"
t 0 "ls, nothing running"                   'ls -la' "$FAKE_NONE"

# --- rules-disable opt-out ----------------------------------------------------
TMP=$(mktemp -d)
( cd "$TMP" && git init -q . && mkdir -p .claude && echo suite-inflight-guard > .claude/rules-disable )
printf '{"tool_input":{"command":"bin/magento cache:clean"},"cwd":"%s"}' "$TMP" \
  | SUITE_INFLIGHT_PS_CMD="cat $FAKE_RUNNING" bash "$HOOK" >/dev/null 2>&1
RC=$?
rm -rf "$TMP"
[ "$RC" = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (rules-disable opt-out): exit $RC"; }

# --- fails soft ---------------------------------------------------------------
echo '' | bash "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: empty input should no-op"; }

# --- MCP servers are not test runs (2026-10-01: always running everywhere) ---
FAKE_MCP=$(mktemp)
printf '%s\n' '28119 npm exec @playwright/mcp --no-sandbox --isolated' \
  '28148 node /mnt/ddev-global-cache/npm/_npx/x/node_modules/.bin/playwright-mcp --no-sandbox' > "$FAKE_MCP"
t 0 "only playwright-mcp running"       'bin/magento cache:clean' "$FAKE_MCP"
FAKE_REAL=$(mktemp)
printf '%s\n' '37905 node /var/www/html/tests/apps/node_modules/.bin/playwright test a.spec.ts' > "$FAKE_REAL"
t 2 "real playwright test alongside mcp" 'bin/magento cache:clean' "$FAKE_REAL"
rm -f "$FAKE_MCP" "$FAKE_REAL"
echo 'not json' | bash "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: garbage input should no-op"; }

echo "suite-inflight-guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
