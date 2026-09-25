#!/bin/bash
# Test suite for magento-config-dump-guard.sh — feed PreToolUse JSON, assert exit.
# Run: bash magento-config-dump-guard.test.sh   (exit 0 = all green)
#
# Layer 1 is container-scoped, so those cases export DDEV_PROJECT to simulate one.
# Layer 2 is unscoped and runs against a throwaway repo built below.

HOOK="$(cd "$(dirname "$0")" && pwd)/magento-config-dump-guard.sh"
PASS=0; FAIL=0

# cont <expected> <desc> <command> [cwd]  — container session
cont() {
  local expect="$1" desc="$2" cmd="$3" cwd="${4:-}"
  local json
  json=$(jq -n --arg c "$cmd" --arg cwd "$cwd" \
    '{tool_name:"Bash", tool_input:{command:$c}} | if $cwd != "" then .cwd = $cwd else . end')
  printf '%s' "$json" | DDEV_PROJECT=testproj bash "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL ($desc): expected $expect got $got — $cmd"; fi
}

# host <expected> <desc> <command> [cwd]  — host session (no DDEV_PROJECT)
host() {
  local expect="$1" desc="$2" cmd="$3" cwd="${4:-}"
  if [ -f /.dockerenv ]; then PASS=$((PASS+1)); return; fi  # can't simulate host inside a container
  local json
  json=$(jq -n --arg c "$cmd" --arg cwd "$cwd" \
    '{tool_name:"Bash", tool_input:{command:$c}} | if $cwd != "" then .cwd = $cwd else . end')
  printf '%s' "$json" | env -u DDEV_PROJECT bash "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL ($desc): expected $expect got $got — $cmd"; fi
}

# --- LAYER 1: the dump commands ---------------------------------------------
cont 2 "php bin/magento app:config:dump"  'php bin/magento app:config:dump'
cont 2 "bare app:config:dump"             'bin/magento app:config:dump'
cont 2 "dump with output suppressed"      'bin/magento app:config:dump >/dev/null 2>&1'
cont 2 "ddev exec wrapper"                'ddev exec bin/magento app:config:dump'
# the origin incident command, verbatim shape (thread 50b98acf)
cont 2 "origin incident command"          'php bin/magento app:config:dump 2>/dev/null >/dev/null; grep -m1 -A5 "'"'"'db'"'"'" app/etc/env.php'
cont 2 "app:config:import"                'bin/magento app:config:import'
cont 2 "config:set --lock-config"         'bin/magento config:set --lock-config web/secure/base_url https://x/'
cont 2 "config:set --lock-env"            'bin/magento config:set --lock-env some/path value'

# --- LAYER 1: legitimate neighbours must pass -------------------------------
cont 0 "plain config:set"                 'bin/magento config:set web/secure/base_url https://x/'
cont 0 "config:show"                      'bin/magento config:show payment/stripe/active'
cont 0 "cache:clean"                      'bin/magento cache:clean'
cont 0 "setup:upgrade"                    'bin/magento setup:upgrade'
cont 0 "grep mentions the words"           'grep -rn "app:config:dump" docs/'
cont 0 "reading env.php with php -r"      'php -r '"'"'$c = include "app/etc/env.php"; print_r(array_keys($c));'"'"''

# --- LAYER 1: reads of config.php pass, writes block ------------------------
cont 0 "cat config.php"                   'cat app/etc/config.php'
cont 0 "grep config.php"                  'grep -n modules app/etc/config.php'
cont 0 "head config.php"                  'head -20 app/etc/config.php'
cont 0 "git diff config.php"              'git diff app/etc/config.php'
cont 0 "git log config.php"               'git log --oneline -- app/etc/config.php'
cont 0 "wc -l config.php"                 'wc -l app/etc/config.php'
cont 2 "redirect into config.php"         'echo "<?php return [];" > app/etc/config.php'
cont 2 "append into config.php"           'cat /tmp/dump.php >> app/etc/config.php'
cont 2 "tee config.php"                   'php -r "..." | tee app/etc/config.php'
cont 2 "sed -i config.php"                'sed -i "s/foo/bar/" app/etc/config.php'
cont 2 "cp over config.php"               'cp /tmp/x.php app/etc/config.php'
cont 2 "mv over config.php"               'mv /tmp/x.php app/etc/config.php'
cont 2 "truncate config.php"              'truncate -s 0 app/etc/config.php'
cont 2 "git restore config.php"           'git restore app/etc/config.php'

# --- LAYER 1 is container-only; host is the maintainer session ---------------
host 0 "host: dump not blocked by layer 1" 'php bin/magento app:config:dump'
host 0 "host: redirect not blocked"        'echo x > app/etc/config.php'

# --- LAYER 2: commit-time dump detection ------------------------------------
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
git -c init.defaultBranch=main init -q "$TMP" 2>/dev/null
git -C "$TMP" config user.email t@t; git -C "$TMP" config user.name t
mkdir -p "$TMP/app/etc"

# a realistic small config.php: modules only, as a healthy repo has
{
  echo "<?php"
  echo "return ["
  echo "    'modules' => ["
  for i in $(seq 1 40); do echo "        'Vendor_Module$i' => 1,"; done
  echo "    ],"
  echo "];"
} > "$TMP/app/etc/config.php"
git -C "$TMP" add app/etc/config.php >/dev/null 2>&1
git -C "$TMP" commit -qm "baseline config.php" >/dev/null 2>&1

cont 0 "clean tree, nothing to flag"  'git commit -m x' "$TMP"
host 0 "clean tree, host too"         'git commit -m x' "$TMP"

# benign: two module lines added, exactly the real-world false-positive shape
sed -i "s|        'Vendor_Module1' => 1,|        'Vendor_Module1' => 1,\n        'JustBetter_Core' => 1,\n        'JustBetter_Sentry' => 1,|" "$TMP/app/etc/config.php"
cont 0 "benign: +2 module lines"      'git commit -m x' "$TMP"
git -C "$TMP" checkout-index -a -f --prefix="$TMP/" 2>/dev/null
git -C "$TMP" show HEAD:app/etc/config.php > "$TMP/app/etc/config.php"

# (a) a 'scopes' section appears
sed -i "s|    'modules' => \[|    'scopes' => [\n        'websites' => [],\n    ],\n    'modules' => [|" "$TMP/app/etc/config.php"
cont 2 "(a) adds scopes section"      'git commit -m x' "$TMP"
host 2 "(a) host blocks too"          'git commit -m x' "$TMP"
git -C "$TMP" show HEAD:app/etc/config.php > "$TMP/app/etc/config.php"

# (a) a 'themes' section appears
sed -i "s|    'modules' => \[|    'themes' => [\n        'frontend/Vendor/theme' => [],\n    ],\n    'modules' => [|" "$TMP/app/etc/config.php"
cont 2 "(a) adds themes section"      'git commit -m x' "$TMP"
git -C "$TMP" show HEAD:app/etc/config.php > "$TMP/app/etc/config.php"

# (b) a credential-shaped key appears — the Stripe pk case from the incident
sed -i "s|    'modules' => \[|    'system' => [\n        'default' => [\n            'payment' => [\n                'stripe_payments_basic' => [\n                    'stripe_test_pk' => 'pk_test_REDACTED',\n                ],\n            ],\n        ],\n    ],\n    'modules' => [|" "$TMP/app/etc/config.php"
cont 2 "(b) adds *_pk key"            'git commit -m x' "$TMP"
git -C "$TMP" show HEAD:app/etc/config.php > "$TMP/app/etc/config.php"

sed -i "s|    'modules' => \[|    'system' => [ 'default' => [ 'carriers' => [ 'shipperhq' => [ 'api_key' => 'x' ] ] ] ],\n    'modules' => [|" "$TMP/app/etc/config.php"
cont 2 "(b) adds api_key"             'git commit -m x' "$TMP"
git -C "$TMP" show HEAD:app/etc/config.php > "$TMP/app/etc/config.php"

sed -i "s|    'modules' => \[|    'system' => [ 'default' => [ 'x' => [ 'password' => 'x' ] ] ],\n    'modules' => [|" "$TMP/app/etc/config.php"
cont 2 "(b) adds password"            'git commit -m x' "$TMP"
git -C "$TMP" show HEAD:app/etc/config.php > "$TMP/app/etc/config.php"

sed -i "s|    'modules' => \[|    'system' => [ 'default' => [ 'shq' => [ 'environment_scope' => 'DEVELOPMENT' ] ] ],\n    'modules' => [|" "$TMP/app/etc/config.php"
cont 2 "(b) adds environment_scope"   'git commit -m x' "$TMP"
git -C "$TMP" show HEAD:app/etc/config.php > "$TMP/app/etc/config.php"

# (c) sheer growth, with no section or credential marker at all
{
  git -C "$TMP" show HEAD:app/etc/config.php | head -n -2
  for i in $(seq 1 300); do echo "        'Filler_Module$i' => 1,"; done
  echo "    ],"
  echo "];"
} > "$TMP/app/etc/config.php"
cont 2 "(c) grows 300 lines"          'git commit -m x' "$TMP"
git -C "$TMP" show HEAD:app/etc/config.php > "$TMP/app/etc/config.php"

# growth just under the threshold stays quiet
{
  git -C "$TMP" show HEAD:app/etc/config.php | head -n -2
  for i in $(seq 1 150); do echo "        'Filler_Module$i' => 1,"; done
  echo "    ],"
  echo "];"
} > "$TMP/app/etc/config.php"
cont 0 "(c) +150 lines under limit"   'git commit -m x' "$TMP"
git -C "$TMP" show HEAD:app/etc/config.php > "$TMP/app/etc/config.php"

# --- LAYER 2 only speaks on commit -----------------------------------------
sed -i "s|    'modules' => \[|    'scopes' => [],\n    'modules' => [|" "$TMP/app/etc/config.php"
cont 0 "dump present but not a commit" 'ls -la' "$TMP"
cont 0 "dump present, git status"       'git status' "$TMP"
cont 2 "dump present, git commit -a"    'git commit -am x' "$TMP"

# --- opt-out ----------------------------------------------------------------
mkdir -p "$TMP/.claude"
printf 'magento-config-dump-guard\n' > "$TMP/.claude/rules-disable"
cont 0 "opt-out disarms layer 2"        'git commit -m x' "$TMP"
cont 0 "opt-out disarms layer 1"        'bin/magento app:config:dump' "$TMP"
printf 'some-other-guard\n' > "$TMP/.claude/rules-disable"
cont 2 "unrelated opt-out line"         'git commit -m x' "$TMP"

# --- env escape hatch (user-only, pre-session) ------------------------------
jq -n '{tool_name:"Bash", tool_input:{command:"bin/magento app:config:dump"}}' \
  | DDEV_PROJECT=t CLAUDE_MAGENTO_CONFIG_DUMP_ALLOWED=1 bash "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: env escape should allow"; }

# --- fails soft -------------------------------------------------------------
echo '' | DDEV_PROJECT=t bash "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: empty input should no-op"; }
echo 'not json' | DDEV_PROJECT=t bash "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: garbage input should no-op"; }
jq -n '{tool_name:"Edit", tool_input:{file_path:"app/etc/config.php"}}' | DDEV_PROJECT=t bash "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: non-Bash tool should no-op"; }

echo "magento-config-dump-guard: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
