#!/bin/bash
# Test suite for merge-guard.sh — feed PreToolUse JSON, assert exit code.
# Branch-name-sensitive cases run inside a scratch repo so $CURBR resolves.
# Run: bash merge-guard.test.sh   (exit 0 = all green)

HOOK="$(cd "$(dirname "$0")" && pwd)/merge-guard.sh"
PASS=0; FAIL=0

t() { # t <expected-exit> <desc> <command-string>  (runs from $PWD, no branch dependency)
  local expect="$1" desc="$2" cmd="$3"
  printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)" \
    | CLAUDE_MERGE_ALLOWED=0 bash "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL ($desc): expected exit $expect got $got — cmd: $cmd"
  fi
}

tb() { # tb <expected-exit> <desc> <branch-to-be-on> <command-string>
  local expect="$1" desc="$2" branch="$3" cmd="$4"
  local D; D=$(mktemp -d)
  ( cd "$D" && git init -q . && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init \
    && git checkout -q -b "$branch" 2>/dev/null
    printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)" \
      | CLAUDE_MERGE_ALLOWED=0 bash "$HOOK" >/dev/null 2>&1 )
  local got=$?
  rm -rf "$D"
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL ($desc): expected exit $expect got $got — cmd: $cmd (on $branch)"
  fi
}

# --- blocked (exit 2) --------------------------------------------------------
t 2 "merge FROM uat"           'git merge uat'
t 2 "merge FROM origin/uat"    'git merge origin/uat'
t 2 "rebase ONTO uat"          'git rebase uat'
t 2 "rebase onto origin/uat"   'git rebase origin/uat'
tb 2 "pull uat while on live"  "live"    'git pull origin uat'
tb 2 "pull uat while on main"  "main"    'git pull origin uat'

# --- allowed (exit 0) --------------------------------------------------------
t 0 "merge INTO uat (uat not named as source)" 'git merge feature/x'
t 0 "merge feature branch"      'git merge feature/uat-fix'
t 0 "rebase onto main"          'git rebase main'
tb 0 "pull uat while ON uat"    "uat"     'git pull origin uat'
t 0 "non-git command"           'echo hello'
t 0 "commit"                    'git commit -m "fix: thing"'
t 0 "mentions uat as text only" 'echo "testing on uat later"'

# --- bypass env ---------------------------------------------------------------
printf '{"tool_input":{"command":"git merge uat"}}' \
  | CLAUDE_MERGE_ALLOWED=1 bash "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (bypass env)"; }

echo "merge-guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
