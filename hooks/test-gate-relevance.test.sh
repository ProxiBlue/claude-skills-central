#!/bin/bash
# Test suite for the test-gate.sh RELEVANCE layer — scratch git repo, forged
# evidence at the real state hash, gate fed PreToolUse JSON.
# Run: bash test-gate-relevance.test.sh   (exit 0 = all green)

HOOKS="$(cd "$(dirname "$0")" && pwd)"
GATE="$HOOKS/test-gate.sh"
. "$HOOKS/test-gate-lib.sh"

PASS=0; FAIL=0
unset CLAUDE_TEST_GATE_ALLOWED CLAUDE_TEST_GATE_MODE CLAUDE_TEST_GATE_RELEVANCE

mkrepo() { # fresh armed repo (phpunit.xml => unit family), cwd left inside
  D=$(mktemp -d)
  cd "$D" || exit 1
  git init -q
  git config user.email t@t; git config user.name t
  echo '<phpunit/>' > phpunit.xml
  git add -A && git commit -qm init
}

evidence() { # evidence <cmd> — forge a passing unit run at CURRENT state hash
  local ef hash
  ef=$(tg_evidence_file "$D"); hash=$(tg_state_hash "$D")
  jq -cn --arg h "$hash" --arg c "$1" \
    '{type:"test",family:"unit",ts:"t",state:$h,exit_code:0,cmd:$c}' >> "$ef"
}

rungate() { # rungate — exit code of gate for `git commit` in $D; stderr to $ERR
  ERR=$(mktemp)
  printf '{"cwd": %s, "tool_input":{"command":"git commit -m x"}}' \
    "$(printf '%s' "$D" | jq -Rs .)" | bash "$GATE" 2>"$ERR"
}

t() { # t <expected-exit> <desc> [<stderr-must-contain>]
  local expect="$1" desc="$2" want="${3:-}" got
  rungate; got=$?
  if [ "$got" != "$expect" ]; then
    FAIL=$((FAIL+1)); echo "FAIL ($desc): expected exit $expect got $got"
    sed 's/^/    | /' "$ERR" | head -8
  elif [ -n "$want" ] && ! grep -qF "$want" "$ERR"; then
    FAIL=$((FAIL+1)); echo "FAIL ($desc): stderr missing '$want'"
    sed 's/^/    | /' "$ERR" | head -8
  else
    PASS=$((PASS+1))
  fi
  rm -f "$ERR"
}

# 1. mapped test exists + broad suite run -> pass
mkrepo
mkdir -p src tests
echo '<?php class Foo {}' > src/Foo.php
echo '<?php class FooTest {}' > tests/FooTest.php
git add -A
evidence 'vendor/bin/phpunit -c phpunit.xml'
t 0 "mapped test + broad run"

# 2. no test anywhere -> block, existence message
mkrepo
mkdir -p src
echo '<?php class Foo {}' > src/Foo.php
git add -A
evidence 'vendor/bin/phpunit -c phpunit.xml'
t 2 "no test exists" "No test found that specifically covers"

# 3. test exists but only an UNRELATED targeted run -> block, not-run message
mkrepo
mkdir -p src tests
echo '<?php class Foo {}' > src/Foo.php
echo '<?php class FooTest {}' > tests/FooTest.php
echo '<?php class BarTest {}' > tests/BarTest.php
git add -A
evidence 'vendor/bin/phpunit tests/BarTest.php'
t 2 "unrelated targeted run" "did NOT execute them"

# 4. targeted run naming the candidate -> pass
mkrepo
mkdir -p src tests
echo '<?php class Foo {}' > src/Foo.php
echo '<?php class FooTest {}' > tests/FooTest.php
git add -A
evidence 'vendor/bin/phpunit tests/FooTest.php'
t 0 "targeted run names candidate"

# 5. --filter with source stem -> pass
mkrepo
mkdir -p src tests
echo '<?php class Foo {}' > src/Foo.php
echo '<?php class FooTest {}' > tests/FooTest.php
git add -A
evidence 'vendor/bin/phpunit --filter Foo tests/FooTest.php'
t 0 "--filter targeted run"

# 6. no test but no_test_ok pattern -> pass
mkrepo
mkdir -p src .claude
echo '<?php class Foo {}' > src/Foo.php
echo '{"relevance":{"no_test_ok":["^src/"]}}' > .claude/test-gate.json
git add -A
evidence 'vendor/bin/phpunit -c phpunit.xml'
t 0 "no_test_ok exemption"

# 7. no test, env off -> pass
mkrepo
mkdir -p src
echo '<?php class Foo {}' > src/Foo.php
git add -A
evidence 'vendor/bin/phpunit -c phpunit.xml'
CLAUDE_TEST_GATE_RELEVANCE=off t 0 "env off kill-switch"
unset CLAUDE_TEST_GATE_RELEVANCE

# 8. content-grep candidate (spec mentions class, unmapped name) + broad -> pass
mkrepo
mkdir -p src tests
echo '<?php class Widget {}' > src/Widget.php
echo '<?php /* covers Widget flows */ class CheckoutSuiteTest {}' > tests/CheckoutSuiteTest.php
git add -A
evidence 'vendor/bin/phpunit -c phpunit.xml'
t 0 "content-grep candidate + broad run"

# 9. relevance warn mode -> pass with warning
mkrepo
mkdir -p src
echo '<?php class Foo {}' > src/Foo.php
git add -A
evidence 'vendor/bin/phpunit -c phpunit.xml'
CLAUDE_TEST_GATE_RELEVANCE=warn t 0 "warn mode passes" "relevance WARN"
unset CLAUDE_TEST_GATE_RELEVANCE

# 10. family gate still first: no evidence at all -> original block message
mkrepo
mkdir -p src tests
echo '<?php class Foo {}' > src/Foo.php
echo '<?php class FooTest {}' > tests/FooTest.php
git add -A
t 2 "family gate precedes relevance" "without passing test evidence"

# 11. changed test file is its own candidate + broad run -> pass
mkrepo
mkdir -p tests
echo '<?php class FooTest {}' > tests/FooTest.php
git add -A
evidence 'vendor/bin/phpunit -c phpunit.xml'
t 0 "changed test file, broad run"

# 12. PURE test-only commit, NO evidence at all -> pass (tests need no tests)
mkrepo
mkdir -p tests app/code/V/M/Test/Unit
echo '<?php class FooTest {}' > tests/FooTest.php
echo '<?php class BarTest {}' > app/code/V/M/Test/Unit/BarTest.php
echo 'test spec' > tests/checkout.spec.ts
git add -A
t 0 "pure test commit skips gate"

# 13. mixed commit (code + test), no evidence -> still blocked
mkrepo
mkdir -p src tests
echo '<?php class Foo {}' > src/Foo.php
echo '<?php class FooTest {}' > tests/FooTest.php
git add -A
t 2 "mixed commit still gated" "without passing test evidence"

echo "relevance suite: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
