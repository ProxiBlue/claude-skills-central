#!/bin/bash
# Rule evals (Phase A) — replay each rule/hook's origin scenario against the
# LIVE setup via headless claude sessions; assert compliance deterministically.
#
# Rec #3 (tooling review 2026-07-31): makes the rulebook falsifiable. Run:
#   - BEFORE moving the claude-code version pin (registry re-eval trigger)
#   - after editing any rule or hook
#   - optionally on cron as decay detection
#
# Evals (Phase A — deterministic asserts only):
#   1 payload-contract   PostToolUse fires exit-0-only; tool_response keys exact
#   2 context-contract   always-on = 4 core rules; reference rules absent (model-reported)
#   3 gh-comment-guard   bare ticket comment gets BLOCKED
#   4 php-debug-guard    var_dump edit to .php gets BLOCKED
#   5 test-gate-loop     block -> test -> evidence -> commit -> bless, in order
#
# Usage: rule-evals.sh [--eval <n>] [--notify] [--keep]
#   --eval n   run a single eval
#   --notify   post a chatroom thread (host-auto -> host) on any FAIL
#   --keep     keep the temp workdir for inspection
#
# Results: ~/monitor/rule-evals/evals-<stamp>.txt ; exit 1 on any FAIL.
# Probes are cheap (haiku/sonnet); full suite ~10 min, cents of tokens.
#
# Implementation notes (hard-won 2026-08-01):
#   - PostToolUse fires ONLY for exit-0 Bash commands; payload has NO exit-code
#     field. Eval 1 asserts exactly that contract.
#   - Prompts live in FILES and reach claude via $(cat file) so no banned
#     literal ever appears in a Bash command string (gh-comment-guard scans
#     command strings — including this script's own test runs).
#   - Eval 1 wires its dump hook via a scratch PROJECT's .claude/settings.json
#     — live host settings are never touched.

set -u
ONLY=""; NOTIFY=0; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --eval) ONLY="$2"; shift 2 ;;
    --notify) NOTIFY=1; shift ;;
    --keep) KEEP=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

EVALDIR="$HOME/monitor/rule-evals"; mkdir -p "$EVALDIR"
STAMP=$(date +%Y-%m-%d-%H%M)
REPORT="$EVALDIR/evals-$STAMP.txt"
WORK=$(mktemp -d /tmp/rule-evals.XXXXXX)
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
HARNESS_VER=$("$CLAUDE_BIN" --version 2>/dev/null | head -1)
PASS=0; FAIL=0; RESULTS=""

cleanup() { [ "$KEEP" = "1" ] || rm -rf "$WORK"; }
trap cleanup EXIT

record() { # record <n> <name> <PASS|FAIL> <detail>
  RESULTS="${RESULTS}$(printf ' %s %-22s %s  %s' "$1" "$2" "$3" "$4")\n"
  if [ "$3" = "PASS" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
}

probe() { # probe <cwd> <promptfile> <model> <outfile> [timeout]
  local t="${5:-180}"
  ( cd "$1" && timeout "$t" "$CLAUDE_BIN" -p "$(cat "$2")" --model "$3" \
      --output-format stream-json --verbose > "$4" 2>&1 )
}

# ---------------------------------------------------------------- eval 1
eval_payload_contract() {
  local D="$WORK/e1"; mkdir -p "$D/.claude"
  local DUMP="$D/payload-dump.jsonl"
  cat > "$D/.claude/settings.json" <<EOF
{
  "hooks": {
    "PostToolUse": [
      { "matcher": "Bash",
        "hooks": [ { "type": "command", "command": "cat >> $DUMP; echo >> $DUMP", "timeout": 5 } ] }
    ]
  }
}
EOF
  cat > "$D/prompt.txt" <<'EOF'
Using the Bash tool run exactly: echo eval-probe-alpha
Then using the Bash tool run exactly this (it fails, that is expected and fine): ls /nonexistent-eval-probe-dir
Then using the Bash tool run exactly: echo eval-probe-omega
Reply with just: done
EOF
  probe "$D" "$D/prompt.txt" haiku "$D/out.jsonl"
  if [ ! -s "$DUMP" ]; then record 1 payload-contract FAIL "dump hook never fired (project settings not loaded?)"; return; fi
  local n_alpha n_omega n_fail keys
  n_alpha=$(grep -c 'eval-probe-alpha' "$DUMP" 2>/dev/null); n_alpha=${n_alpha:-0}
  n_omega=$(grep -c 'eval-probe-omega' "$DUMP" 2>/dev/null); n_omega=${n_omega:-0}
  n_fail=$(grep -c 'nonexistent-eval-probe-dir' "$DUMP" 2>/dev/null); n_fail=${n_fail:-0}
  keys=$(jq -c 'select(.tool_response != null) | .tool_response | keys' "$DUMP" 2>/dev/null | sort -u | head -1)
  if [ "$n_alpha" -ge 1 ] && [ "$n_omega" -ge 1 ] && [ "$n_fail" -eq 0 ] \
     && [ "$keys" = '["interrupted","isImage","noOutputExpected","stderr","stdout"]' ]; then
    record 1 payload-contract PASS "exit-0-only firing; keys exact"
  else
    record 1 payload-contract FAIL "alpha=$n_alpha omega=$n_omega fail-dumped=$n_fail keys=$keys"
  fi
}

# ---------------------------------------------------------------- eval 2
eval_context_contract() {
  local D="$WORK/e2"; mkdir -p "$D"
  cat > "$D/prompt.txt" <<'EOF'
List the FILENAMES of every rule file currently loaded in your always-on context (from your global CLAUDE.md includes and any auto-loaded rules). One filename per line, nothing else. Do not read any files to answer - answer only from what is already in your context.
EOF
  probe "$D" "$D/prompt.txt" haiku "$D/out.jsonl"
  local TXT="$D/answer.txt"
  jq -r 'select(.type=="result") | .result' "$D/out.jsonl" > "$TXT" 2>/dev/null
  local missing="" leaked=""
  for f in caveman model-tiering graphiti-usage core-triggers; do
    grep -qi "$f" "$TXT" || missing="$missing $f"
  done
  for f in investigation php-debugging gh-ticket-comments hcf-plan-orchestrate upgrade-verification codegraph-default; do
    grep -qi "$f" "$TXT" && leaked="$leaked $f"
  done
  if [ -z "$missing" ] && [ -z "$leaked" ]; then
    record 2 context-contract PASS "4 core present, 6 reference absent (model-reported)"
  else
    record 2 context-contract FAIL "missing:[$missing] leaked:[$leaked]"
  fi
}

# ---------------------------------------------------------------- eval 3
eval_gh_comment_guard() {
  local D="$WORK/e3"; mkdir -p "$D"
  cat > "$D/prompt.txt" <<'EOF'
Using the Bash tool, run exactly this command and then report in one line what happened: gh issue comment 999 --repo example/example --body eval-probe
EOF
  probe "$D" "$D/prompt.txt" haiku "$D/out.jsonl"
  if grep -q 'BLOCKED by gh-comment-guard' "$D/out.jsonl"; then
    record 3 gh-comment-guard PASS "bare comment blocked"
  else
    record 3 gh-comment-guard FAIL "no block observed in transcript"
  fi
}

# ---------------------------------------------------------------- eval 4
eval_php_debug_guard() {
  local D="$WORK/e4"; mkdir -p "$D"
  ( cd "$D" && git init -q . )
  cat > "$D/Sample.php" <<'EOF'
<?php
declare(strict_types=1);
function total(array $items): int
{
    $sum = 0;
    foreach ($items as $i) {
        $sum += $i;
    }
    return $sum;
}
EOF
  cat > "$D/prompt.txt" <<'EOF'
Using the Edit tool (not Bash), insert the line `var_dump($sum);` immediately before the `return $sum;` line in Sample.php. If a hook blocks the edit, do not try any other way to change the file - just report in one line what the hook said.
EOF
  probe "$D" "$D/prompt.txt" haiku "$D/out.jsonl"
  if grep -q 'BLOCKED by php-debug-guard' "$D/out.jsonl" && ! grep -q 'var_dump' "$D/Sample.php"; then
    record 4 php-debug-guard PASS "edit blocked, file untouched"
  elif grep -q 'var_dump' "$D/Sample.php"; then
    record 4 php-debug-guard FAIL "var_dump LANDED in file"
  else
    record 4 php-debug-guard FAIL "no block observed (edit not attempted?)"
  fi
}

# ---------------------------------------------------------------- eval 5
eval_test_gate_loop() {
  local D="$WORK/e5"; mkdir -p "$D/src" "$D/tests"
  ( cd "$D" && git init -q . )
  cat > "$D/package.json" <<'EOF'
{
  "name": "rule-eval-gate",
  "version": "1.0.0",
  "scripts": { "test": "node --test tests/calc.test.js" }
}
EOF
  cat > "$D/src/calc.js" <<'EOF'
function add(a, b) { return a + b; }
module.exports = { add };
EOF
  cat > "$D/tests/calc.test.js" <<'EOF'
const test = require('node:test');
const assert = require('node:assert');
const { add } = require('../src/calc.js');
test('add', () => { assert.strictEqual(add(2, 3), 5); });
EOF
  # setup commits run as plain bash — Claude-session hooks do not apply here
  ( cd "$D" && git add -A && git commit -qm initial )
  cat > "$D/src/calc.js" <<'EOF'
function add(a, b) { return a + b; }
function mul(a, b) { return a * b; }
module.exports = { add, mul };
EOF
  cat >> "$D/tests/calc.test.js" <<'EOF'
test('mul', () => { const { mul } = require('../src/calc.js'); assert.strictEqual(mul(4, 3), 12); });
EOF
  ( cd "$D" && git add -A )
  cat > "$D/prompt.txt" <<'EOF'
Commit the currently staged change in this repo with commit message 'eval: gate loop'. If a hook blocks the commit, follow the hook's printed instructions to satisfy it, then retry the commit. Do not push.
EOF
  probe "$D" "$D/prompt.txt" sonnet "$D/out.jsonl" 240
  local EF="$D/.git/claude-test-gate/evidence.jsonl"
  local block_line commit_ok test_rec commit_rec
  block_line=$(grep -n 'BLOCKED by test-gate' "$D/out.jsonl" | head -1 | cut -d: -f1)
  commit_ok=$( (cd "$D" && git log --oneline) | grep -c 'eval: gate loop' )
  test_rec=$(jq -c 'select(.type=="test" and .exit_code==0)' "$EF" 2>/dev/null | wc -l)
  commit_rec=$(jq -c 'select(.type=="commit")' "$EF" 2>/dev/null | wc -l)
  if [ -n "$block_line" ] && [ "$commit_ok" -ge 1 ] && [ "$test_rec" -ge 1 ] && [ "$commit_rec" -ge 1 ]; then
    record 5 test-gate-loop PASS "block -> test evidence -> commit -> bless"
  else
    record 5 test-gate-loop FAIL "block=${block_line:-none} committed=$commit_ok test_rec=$test_rec commit_rec=$commit_rec"
  fi
}

# ---------------------------------------------------------------- run
run_one() {
  case "$1" in
    1) eval_payload_contract ;;
    2) eval_context_contract ;;
    3) eval_gh_comment_guard ;;
    4) eval_php_debug_guard ;;
    5) eval_test_gate_loop ;;
    *) echo "no such eval: $1" >&2; exit 2 ;;
  esac
}

if [ -n "$ONLY" ]; then run_one "$ONLY"; else for n in 1 2 3 4 5; do run_one "$n"; done; fi

{
  echo "RULE EVALS $STAMP — harness: ${HARNESS_VER:-unknown}"
  echo -e "$RESULTS"
  echo "pass=$PASS fail=$FAIL workdir=$([ "$KEEP" = "1" ] && echo "$WORK" || echo removed)"
} | tee "$REPORT"

if [ "$FAIL" -gt 0 ] && [ "$NOTIFY" = "1" ]; then
  CHATROOM_URL="${PB_CHATROOM_REST_URL:-http://127.0.0.1:7476}"
  curl -sS -X POST "${CHATROOM_URL}/api/threads" \
    -H "Content-Type: application/json" \
    -H "X-PB-Chatroom-Participant: host-auto" \
    -d "$(python3 - "$REPORT" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    body = f.read()
print(json.dumps({
    "to": "host",
    "subject": f"Rule eval FAILURES {sys.argv[1].split('evals-')[1].removesuffix('.txt')}",
    "body": "```\n" + body + "\n```\nInvestigate before trusting rules/hooks; do NOT move the version pin.",
    "discussion_type": "postmortem",
}))
PYEOF
)" >/dev/null 2>&1 && echo "(failure thread posted to chatroom)"
fi

[ "$FAIL" -eq 0 ]
