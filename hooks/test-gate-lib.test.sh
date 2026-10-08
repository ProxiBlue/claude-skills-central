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


fam "unit" "node --test glob is a unit run" 'node --test app/code/X/Test/Js/*.test.js'
fam "" "node script is not a test run" 'node scripts/build.js'
fam "" "heredoc body is not a command" $'python3 - <<\'EOF\'\nnode --test x\nvendor/bin/phpunit\nEOF'
fam "unit" "runner after heredoc still counts" $'cat <<EOF > f\nhi\nEOF\nvendor/bin/phpunit'

fam "" "quoted pipe is not a runner (pgrep probe)" "pgrep -af 'playwright|phpunit|paratest' | grep -v pgrep"
fam "unit" "filter regex with pipe stays one segment" 'vendor/bin/phpunit --filter "Up|ProxiBlue"'
fam "e2e" "quoted grep title with ; and |" "npx playwright test a.spec.ts -g 'x; y | z'"

# --- Python runners (2026-10-08) ---------------------------------------------
fam "unit" "bare pytest"                       "pytest -q tests/"
fam "unit" "venv pytest path"                  ".venv/bin/pytest tests/test_bar.py"
fam "unit" "python -m pytest"                  "python -m pytest -x"
fam "unit" "python3.12 -m pytest"              "python3.12 -m pytest"
fam "unit" "uv run pytest"                     "uv run pytest -q"
fam "unit" "uv run --frozen pytest"            "uv run --frozen pytest"
fam "unit" "poetry run pytest"                 "poetry run pytest"
fam "unit" "uv run python -m pytest"           "uv run python -m pytest tests"
fam ""     "uv sync is not a test run"         "uv sync"
fam ""     "python script is not a test run"   "python scripts/build.py"
fam ""     "grep for pytest is not a run"      "grep -rn pytest pyproject.toml"

kind() { # kind <expected> <desc> <fn> <arg>
  local got; got=$("$3" "$4")
  if [ "$got" = "$1" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL ($2): expected [$1] got [$got]"; fi
}
kind py    "test_*.py kind"        tg_test_kind "tests/unit/test_bar.py"
kind py    "*_test.py kind"        tg_test_kind "pkg/bar_test.py"
kind other "conftest is support"   tg_test_kind "tests/conftest.py"
kind php   "FooTest.php kind"      tg_test_kind "Test/Unit/FooTest.php"
kind py    "pytest segment kind"   tg_segment_kind "uv run pytest tests"
kind php   "phpunit segment kind"  tg_segment_kind "vendor/bin/phpunit -c x"
tp() { if tg_is_test_path "$2"; then g=0; else g=1; fi; if [ "$g" = "$1" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL (is_test_path $2): expected $1"; fi; }
tp 0 "test_bar.py"; tp 0 "pkg/bar_test.py"; tp 0 "conftest.py"; tp 1 "src/pkg/bar.py"; tp 0 "tests/FooTest.php"; tp 1 "src/Foo.php"

echo "test-gate-lib tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
