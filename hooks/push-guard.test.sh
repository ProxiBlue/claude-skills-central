#!/bin/bash
# Test suite for push-guard.sh — feed PreToolUse JSON, assert exit code.
# Run: bash push-guard.test.sh   (exit 0 = all green)

HOOK="$(cd "$(dirname "$0")" && pwd)/push-guard.sh"
PASS=0; FAIL=0

t() { # t <expected-exit> <desc> <command-string>
  local expect="$1" desc="$2" cmd="$3"
  printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)" \
    | CLAUDE_PUSH_ALLOWED=0 bash "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL ($desc): expected exit $expect got $got — cmd: $cmd"
  fi
}

# --- blocked (exit 2) --------------------------------------------------------
t 2 "push live"              'git push origin live'
t 2 "push uat"                'git push origin uat'
t 2 "push live no remote arg" 'git push live'
t 2 "push --force"            'git push --force origin feature/x'
t 2 "push -f short"           'git push -f origin feature/x'
t 2 "push force-with-lease"   'git push --force-with-lease origin feature/x'
t 2 "ddev push"                'ddev push'
t 2 "ddev push chained"        'cd /var/www/html && ddev push'
t 2 "ssh live host"            'ssh user@live.example.com'
t 2 "ssh prod host dot"        'ssh deploy@prod.acme.io'
t 2 "ssh production host"      'ssh admin@production.example.com'

# --- allowed (exit 0) --------------------------------------------------------
t 0 "push feature branch"      'git push origin feature/x'
t 0 "push main"                 'git push origin main'
t 0 "push no branch (current)"  'git push'
t 0 "ssh non-live host"         'ssh user@dev.example.com'
t 0 "ssh read-only investigation" 'ssh user@staging.example.com cat /var/log/app.log'
t 0 "non-git command"           'echo hello'
t 0 "mentions uat in text"      'echo "deploy to uat later"'

# --- bypass env ---------------------------------------------------------------
printf '{"tool_input":{"command":"git push origin live"}}' \
  | CLAUDE_PUSH_ALLOWED=1 bash "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (bypass env)"; }

# --- inline bypass prefix must NOT work (documented non-bypass) --------------
printf '{"tool_input":{"command":"CLAUDE_PUSH_ALLOWED=1 git push origin live"}}' \
  | bash "$HOOK" >/dev/null 2>&1
[ $? = 2 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (inline prefix must still block)"; }

# --- uat marker bypass (uat-deploy-verify's single-use authorization) -------
TMPREPO=$(mktemp -d)
git -C "$TMPREPO" init -q

# Valid, fresh marker → uat push allowed, marker consumed (deleted)
date +%s > "$TMPREPO/.git/.claude-uat-push-authorized"
( cd "$TMPREPO" && printf '{"tool_input":{"command":"git push origin uat"}}' | bash "$HOOK" >/dev/null 2>&1 )
got=$?
if [ "$got" = 0 ] && [ ! -f "$TMPREPO/.git/.claude-uat-push-authorized" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); echo "FAIL (uat marker: valid marker should allow + self-delete, got exit $got)"
fi

# Marker already consumed → second uat push in a row is blocked again
( cd "$TMPREPO" && printf '{"tool_input":{"command":"git push origin uat"}}' | bash "$HOOK" >/dev/null 2>&1 )
[ $? = 2 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (uat marker: single-use — second push should block)"; }

# Stale marker (> 10 min old) → blocked, and still consumed (deleted) on read
STALE_TS=$(( $(date +%s) - 700 ))
echo "$STALE_TS" > "$TMPREPO/.git/.claude-uat-push-authorized"
( cd "$TMPREPO" && printf '{"tool_input":{"command":"git push origin uat"}}' | bash "$HOOK" >/dev/null 2>&1 )
got=$?
if [ "$got" = 2 ] && [ ! -f "$TMPREPO/.git/.claude-uat-push-authorized" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); echo "FAIL (uat marker: stale marker should block + still self-delete, got exit $got)"
fi

# A uat marker must NEVER authorize a live push
date +%s > "$TMPREPO/.git/.claude-uat-push-authorized"
( cd "$TMPREPO" && printf '{"tool_input":{"command":"git push origin live"}}' | bash "$HOOK" >/dev/null 2>&1 )
[ $? = 2 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (uat marker must not authorize a live push)"; }
rm -rf "$TMPREPO"

echo "push-guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
