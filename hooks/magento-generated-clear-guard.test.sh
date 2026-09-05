#!/bin/bash
# Test suite for magento-generated-clear-guard.sh — feed PreToolUse JSON,
# assert exit code. Run: bash magento-generated-clear-guard.test.sh

HOOK="$(cd "$(dirname "$0")" && pwd)/magento-generated-clear-guard.sh"
PASS=0; FAIL=0

t() { # t <expected-exit> <desc> <command-string>
  local expect="$1" desc="$2" cmd="$3"
  printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)" \
    | bash "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL ($desc): expected exit $expect got $got — cmd: $cmd"
  fi
}

# --- blocked (exit 2) --------------------------------------------------------
t 2 "both subdirs, relative"   'rm -rf generated/code/* generated/metadata/* var/cache/*'
t 2 "both subdirs, absolute"   'cd /var/www/html && rm -rf generated/code/* generated/metadata/* var/cache/* 2>&1 | tail -3'
t 2 "code only"                'rm -rf generated/code/*'
t 2 "metadata only"            'rm -rf /var/www/html/generated/metadata/*'
t 2 "no trailing star"         'rm -rf generated/code'

# --- allowed (exit 0) ---------------------------------------------------------
t 0 "already fixed form"       'rm -rf generated/* var/cache/*'
t 0 "already fixed absolute"   'rm -rf /var/www/html/generated/* var/cache/*'
t 0 "unrelated rm"             'rm -rf var/cache/*'
t 0 "non-magento command"      'echo hello'
t 0 "cache:flush only"         'bin/magento cache:flush'

# --- rules-disable opt-out ----------------------------------------------------
TMP=$(mktemp -d); (
  cd "$TMP" && git init -q . && mkdir -p .claude && echo magento-generated-clear-guard > .claude/rules-disable
  printf '{"tool_input":{"command":"rm -rf generated/code/*"}}' | bash "$HOOK" >/dev/null 2>&1
)
RC=$?
rm -rf "$TMP"
[ "$RC" = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (rules-disable opt-out): exit $RC"; }

echo "magento-generated-clear-guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
