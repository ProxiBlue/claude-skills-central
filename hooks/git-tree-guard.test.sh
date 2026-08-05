#!/bin/bash
# Test suite for git-tree-guard.sh — feed PreToolUse JSON, assert exit code.
# Run: bash git-tree-guard.test.sh   (exit 0 = all green)

HOOK="$(cd "$(dirname "$0")" && pwd)/git-tree-guard.sh"
PASS=0; FAIL=0

t() { # t <expected-exit> <desc> <command-string>
  local expect="$1" desc="$2" cmd="$3"
  printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)" \
    | CLAUDE_TREE_GUARD_ALLOWED=0 bash "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL ($desc): expected exit $expect got $got — cmd: $cmd"
  fi
}

# --- blocked (exit 2) --------------------------------------------------------
t 2 "bare stash"            'git stash'
t 2 "stash push"            'git stash push -m wip'
t 2 "stash save"            'git stash save wip'
t 2 "stash drop"            'git stash drop'
t 2 "stash pop"             'git stash pop'
t 2 "stash clear"           'git stash clear'
t 2 "stash -u"              'git stash -u'
t 2 "stash chained"         'git add -A && git stash'
t 2 "reset hard"            'git reset --hard'
t 2 "reset hard ref"        'git reset --hard HEAD~1'
t 2 "clean fd"              'git clean -fd'
t 2 "clean f"               'git clean -f'
t 2 "checkout -- path"      'git checkout -- src/File.php'
t 2 "checkout HEAD -- path" 'git checkout HEAD -- src/File.php'
t 2 "checkout dot"          'git checkout .'
t 2 "checkout -f"           'git checkout -f main'
t 2 "restore path"          'git restore src/File.php'
t 2 "restore staged+worktree" 'git restore --staged --worktree f.php'
t 2 "switch -f"             'git switch -f main'
t 2 "switch discard"        'git switch --discard-changes main'

# --- allowed (exit 0) --------------------------------------------------------
t 0 "stash list"            'git stash list'
t 0 "stash show"            'git stash show -p'
t 0 "stash apply"           'git stash apply stash@{0}'
t 0 "status"                'git status --short'
t 0 "reset soft"            'git reset --soft HEAD~1'
t 0 "reset mixed path"      'git reset HEAD file.php'
t 0 "clean dry"             'git clean -n'
t 0 "clean dry long"        'git clean --dry-run -d'
t 0 "checkout branch"       'git checkout main'
t 0 "checkout -b"           'git checkout -b feature/x'
t 0 "checkout branch -f-ish name" 'git checkout feature-f'
t 0 "restore staged only"   'git restore --staged file.php'
t 0 "switch branch"         'git switch main'
t 0 "non-git"               'echo hello'
t 0 "legit word"            'echo legit stash of things'
t 0 "commit"                'git commit -m "fix: stripe vault"'

# --- bypass env --------------------------------------------------------------
printf '{"tool_input":{"command":"git stash drop"}}' \
  | CLAUDE_TREE_GUARD_ALLOWED=1 bash "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (bypass env)"; }

# --- rules-disable opt-out ---------------------------------------------------
TMP=$(mktemp -d); (
  cd "$TMP" && git init -q . && mkdir -p .claude && echo git-tree-guard > .claude/rules-disable
  printf '{"tool_input":{"command":"git stash drop"}}' | bash "$HOOK" >/dev/null 2>&1
)
RC=$?
rm -rf "$TMP"
[ "$RC" = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (rules-disable opt-out): exit $RC"; }

echo "git-tree-guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
