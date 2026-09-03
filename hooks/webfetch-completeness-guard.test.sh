#!/bin/bash
# Test suite for webfetch-completeness-guard.sh — feed PreToolUse JSON,
# assert exit code. Run: bash webfetch-completeness-guard.test.sh

HOOK="$(cd "$(dirname "$0")" && pwd)/webfetch-completeness-guard.sh"
PASS=0; FAIL=0

t() { # t <expected-exit> <desc> <url>
  local expect="$1" desc="$2" url="$3"
  printf '{"tool_input":{"url":%s}}' "$(printf '%s' "$url" | jq -Rs .)" \
    | bash "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL ($desc): expected exit $expect got $got — url: $url"
  fi
}

# --- blocked (exit 2) — blanket policy ---------------------------------------
t 2 "plain https page"        'https://example.com/docs'
t 2 "github repo page"        'https://github.com/foo/bar'
t 2 "security advisory page"  'https://vendor.example.com/security/advisory-123'

# --- structural exception (exit 0) -------------------------------------------
t 0 "claude.ai artifact url"  'https://claude.ai/code/artifact/abc-123-def'
t 0 "preview.claude.ai url"   'https://preview.claude.ai/some/path'

# --- rules-disable opt-out ---------------------------------------------------
TMP=$(mktemp -d); (
  cd "$TMP" && git init -q . && mkdir -p .claude && echo webfetch-completeness-guard > .claude/rules-disable
  printf '{"tool_input":{"url":"https://example.com"}}' | bash "$HOOK" >/dev/null 2>&1
)
RC=$?
rm -rf "$TMP"
[ "$RC" = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (rules-disable opt-out): exit $RC"; }

# --- missing url = silent no-op ----------------------------------------------
printf '{"tool_input":{}}' | bash "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (missing url)"; }

echo "webfetch-completeness-guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
