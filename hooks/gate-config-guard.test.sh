#!/bin/bash
# Test suite for gate-config-guard.sh — feed PreToolUse JSON, assert exit code.
# Run: bash gate-config-guard.test.sh   (exit 0 = all green)

HOOK="$(cd "$(dirname "$0")" && pwd)/gate-config-guard.sh"
PASS=0; FAIL=0

edit() { # edit <expected-exit> <desc> <tool> <file_path> [new_string]
  local expect="$1" desc="$2" tool="$3" file="$4" new="${5:-x}"
  jq -n --arg t "$tool" --arg f "$file" --arg n "$new" \
    '{tool_name:$t, tool_input:{file_path:$f, new_string:$n, content:$n}}' \
    | bash "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL ($desc): expected exit $expect got $got — $tool $file"; fi
}

bashcmd() { # bashcmd <expected-exit> <desc> <command-string>
  local expect="$1" desc="$2" cmd="$3"
  jq -n --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}' \
    | bash "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL ($desc): expected exit $expect got $got — cmd: $cmd"; fi
}

# --- Edit/Write on protected paths — always blocked, no opt-out --------------
edit 2 "edit test-gate.json"        Edit  ".claude/test-gate.json"
edit 2 "write test-gate.json"       Write ".claude/test-gate.json"
edit 2 "edit nested test-gate.json" Edit  "sub/module/.claude/test-gate.json"
edit 2 "edit perf-gate.json"        Edit  ".claude/perf-gate.json"
edit 2 "edit rules-disable"         Edit  ".claude/rules-disable"
edit 2 "edit evidence log"          Edit  ".git/claude-test-gate/evidence.jsonl"
edit 2 "edit evidence log worktree" Edit  ".git/worktrees/x/claude-test-gate/evidence.jsonl"

# --- Edit/Write on unrelated paths — allowed ----------------------------------
edit 0 "edit unrelated php"         Edit  "src/Foo.php"
edit 0 "edit perf-baseline (not a switch)" Edit ".claude/perf-baseline.json"
edit 0 "edit similarly-named file"  Edit  ".claude/test-gate.json.bak"
edit 0 "edit doc mentioning name"   Edit  "docs/test-gate.md"

# --- Bash write vectors on protected paths — blocked --------------------------
bashcmd 2 "echo redirect"       'echo "{\"enabled\":false}" > .claude/test-gate.json'
bashcmd 2 "append redirect"     'echo disable >> .claude/rules-disable'
bashcmd 2 "tee"                 'echo x | tee .claude/perf-gate.json'
bashcmd 2 "sed -i"              "sed -i 's/enabled.*/enabled\":false}/' .claude/test-gate.json"
bashcmd 2 "cp into"             'cp /tmp/x.json .claude/test-gate.json'
bashcmd 2 "mv into"             'mv /tmp/x.json .claude/rules-disable'
bashcmd 2 "rm"                  'rm .claude/test-gate.json'
bashcmd 2 "rm -f"               'rm -f .claude/rules-disable'
bashcmd 2 "git checkout --"     'git checkout HEAD~5 -- .claude/rules-disable'
bashcmd 2 "git restore"         'git restore --source=main .claude/test-gate.json'
bashcmd 2 "python one-liner"    "python3 -c \"open('.claude/test-gate.json','w').write('{}')\""
bashcmd 2 "jq -i style edit"    'jq -i ".enabled=false" .claude/perf-gate.json'
bashcmd 2 "evidence rm"         'rm .git/claude-test-gate/evidence.jsonl'

# --- Bash reads on protected paths — allowed ----------------------------------
bashcmd 0 "cat"                 'cat .claude/test-gate.json'
bashcmd 0 "grep"                'grep enabled .claude/rules-disable'
bashcmd 0 "jq read-only"        'jq . .claude/perf-gate.json'
bashcmd 0 "git diff"            'git diff .claude/test-gate.json'
bashcmd 0 "git log"             'git log -- .claude/rules-disable'
bashcmd 0 "ls"                  'ls -la .claude/'

# --- Bash unrelated commands — allowed ----------------------------------------
bashcmd 0 "unrelated commit"    'git commit -m "fix: something"'
bashcmd 0 "unrelated redirect"  'echo hi > /tmp/scratch.txt'
bashcmd 0 "plain echo"          'echo hello'

echo "gate-config-guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
