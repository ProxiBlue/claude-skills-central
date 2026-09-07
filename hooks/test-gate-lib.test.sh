#!/bin/bash
# Test suite for test-gate-lib.sh's tg_test_families / tg_is_test_command —
# the test-runner-detection logic shared by test-gate.sh and test-evidence.sh.
# Run: bash test-gate-lib.test.sh

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test-gate-lib.sh
. "$HOOKS_DIR/test-gate-lib.sh"

PASS=0; FAIL=0

fam() { # fam <expected-space-separated-families-or-empty> <desc> <command>
  local expect="$1" desc="$2" cmd="$3"
  local got
  got=$(tg_test_families "$cmd" | tr '\n' ' ' | sed 's/ $//')
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL ($desc): expected [$expect] got [$got] — cmd: $cmd"
  fi
}

# --- bare binaries (unchanged baseline behavior) ------------------------------
fam "unit" "bare phpunit"              "vendor/bin/phpunit -c phpunit.xml"
fam "unit" "bare paratest"             "vendor/bin/paratest"
fam "e2e"  "playwright test"           "npx playwright test"
fam ""     "non-test command"          "echo hello"

# --- 2026-09-07 fix: .phar-distributed runners --------------------------------
# ntotankM1 ships tests via a committed phar (dev/phpunit.phar) — reported
# via pb-chatroom thread 28d90a37: real invocation from that project's
# testing.md permanently failed detection and blocked every commit despite
# a genuinely green suite.
fam "unit" "phpunit.phar via php wrapper (reported command)" \
  "php dev/phpunit.phar -c dev/phpunit.xml.dist --testsuite Unit"
fam "unit" "bare phpunit.phar, no wrapper"    "dev/phpunit.phar -c phpunit.xml"
fam "unit" "paratest.phar via php wrapper"    "php vendor/bin/paratest.phar"
fam "unit" "pest.phar via php wrapper"        "php pest.phar"
fam "unit" "infection.phar via php wrapper"   "php infection.phar"
# A .phar that happens to share a directory with test runners but isn't one
# must NOT be swept in by a careless glob-style fix.
fam ""     "non-test phar is not swept in"    "php box.phar compile"

# --- chained commands still yield distinct families per segment --------------
fam "e2e unit" "phpunit.phar && playwright test (sort -u orders alphabetically)" \
  "php dev/phpunit.phar --testsuite Unit && npx playwright test"

echo "test-gate-lib tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
