#!/bin/bash
# Test suite for test-run-shape-guard.sh. Run: bash test-run-shape-guard.test.sh
# (exit 0 = all green).

HOOK="$(cd "$(dirname "$0")" && pwd)/test-run-shape-guard.sh"
PASS=0; FAIL=0
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }

REPO=$(mktemp -d)
trap 'rm -rf "$REPO"' EXIT
( cd "$REPO" && git init -q ) || { echo "FAIL: cannot init scratch repo"; exit 1; }
printf '#!/bin/bash\ncd tests && npx playwright test --project=chromium\n' > "$REPO/run-suite.sh"
printf '#!/bin/bash\necho hello\n' > "$REPO/hello.sh"

t() { # t <expected-exit> <desc> <command>
  local expect="$1" desc="$2" cmd="$3" got
  jq -n --arg c "$cmd" --arg cwd "$REPO" '{tool_name:"Bash", tool_input:{command:$c}, cwd:$cwd}' \
    | bash "$HOOK" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL ($desc): expected $expect got $got — $cmd"; fi
}

# blocked
t 2 "phpunit | tail"                'vendor/bin/phpunit -c dev/tests/unit/phpunit.xml | tail -5'
t 2 "playwright 2>&1 | grep"        'npx playwright test a.spec.ts 2>&1 | grep passed'
t 2 "bash wrapper with runner"      'bash run-suite.sh'
t 2 "./wrapper with runner"         './run-suite.sh'
t 2 "timeout + wrapper"             'timeout 580 bash run-suite.sh'
t 2 "env + wrapper"                 'APP_NAME=pps bash run-suite.sh'

# allowed
t 0 "pipefail + pipe"               'set -o pipefail && vendor/bin/phpunit | tail -5'
t 0 "plain runner"                  'vendor/bin/phpunit -c dev/tests/unit/phpunit.xml app/code/Up'
t 0 "pipe before runner"            'cat /dev/null | vendor/bin/phpunit'
t 0 "non-runner wrapper"            'bash hello.sh'
t 0 "bash -c not a file"            'bash -c "echo hi"'
t 0 "grep mentioning phpunit"       'git log | grep phpunit'
t 0 "missing script"                'bash nope.sh'

# opt-outs
mkdir -p "$REPO/.claude"
echo '{"enabled": false}' > "$REPO/.claude/test-gate.json"
t 0 "gate disabled"                 'vendor/bin/phpunit | tail -5'
rm "$REPO/.claude/test-gate.json"
echo 'test-run-shape-guard' > "$REPO/.claude/rules-disable"
t 0 "rules-disable opt-out"         'bash run-suite.sh'

echo "test-run-shape-guard.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
