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


# --- pps #519 regressions: runner kind, --filter regex, dirs, globs, helpers --

# 14. --filter REGEX that matches the test's namespace/class -> pass
mkrepo
mkdir -p app/code/Up/Mod/Model app/code/Up/Mod/Test/Unit/Model
echo '<?php class Foo {}' > app/code/Up/Mod/Model/Foo.php
echo '<?php class FooTest {}' > app/code/Up/Mod/Test/Unit/Model/FooTest.php
git add -A
evidence 'vendor/bin/phpunit -c phpunit.xml --filter "Up|ProxiBlue"'
t 0 "--filter regex covers matching path"

# 15. --filter regex that matches nothing relevant -> block
mkrepo
mkdir -p app/code/Up/Mod/Model app/code/Up/Mod/Test/Unit/Model
echo '<?php class Foo {}' > app/code/Up/Mod/Model/Foo.php
echo '<?php class FooTest {}' > app/code/Up/Mod/Test/Unit/Model/FooTest.php
git add -A
evidence 'vendor/bin/phpunit -c phpunit.xml --filter "Other"'
t 2 "--filter regex miss still blocks" "did NOT execute"

# 16. directory argument covers tests under it
mkrepo
mkdir -p app/code/Up/Mod/Model app/code/Up/Mod/Test/Unit/Model
echo '<?php class Foo {}' > app/code/Up/Mod/Model/Foo.php
echo '<?php class FooTest {}' > app/code/Up/Mod/Test/Unit/Model/FooTest.php
git add -A
evidence 'vendor/bin/phpunit -c phpunit.xml app/code/Up'
t 0 "directory arg covers tests under it"

# 17. non-runner tokens in the chain (git add FooTest.php) don't make it targeted
mkrepo
mkdir -p src tests
echo '<?php class Foo {}' > src/Foo.php
echo '<?php class FooTest {}' > tests/FooTest.php
echo '<?php class Bar {}' > src/Bar.php
echo '<?php class BarTest {}' > tests/BarTest.php
git add -A
evidence 'git add tests/FooTest.php && vendor/bin/phpunit -c phpunit.xml'
t 0 "git add token in chain ignored"

# 18. broad phpunit run must NOT cover a .spec.ts candidate
mkrepo
mkdir -p src tests
echo 'export const widget = 1;' > src/widget.ts
echo 'import { widget } from "../src/widget";' > tests/widget.spec.ts
git add -A
evidence 'vendor/bin/phpunit -c phpunit.xml'
t 2 "phpunit never covers .spec.ts" "did NOT execute"

# 19. node --test glob covers .test.js
mkrepo
mkdir -p src tests
echo 'module.exports = 1;' > src/widget.js
echo 'require("../src/widget");' > tests/widget.test.js
git add -A
evidence 'node --test tests/*.test.js'
t 0 "node --test glob covers .test.js"

# 20. page object helper: covered by the spec that imports it
mkrepo
mkdir -p tests/pages tests/specs
echo 'export class CheckoutPage {}' > tests/pages/checkout.page.ts
echo 'import { CheckoutPage } from "../pages/checkout.page";' > tests/specs/checkout.spec.ts
echo '<?php class Foo {}' > Foo.php
echo '<?php class FooTest {}' > tests/FooTest.php
git add -A
evidence 'vendor/bin/phpunit -c phpunit.xml'
evidence 'npx playwright test tests/specs/checkout.spec.ts'
t 0 "helper covered by importing spec"

# 21. same helper, only phpunit ran -> block (spec never executed)
mkrepo
mkdir -p tests/pages tests/specs
echo 'export class CheckoutPage {}' > tests/pages/checkout.page.ts
echo 'import { CheckoutPage } from "../pages/checkout.page";' > tests/specs/checkout.spec.ts
echo '<?php class Foo {}' > Foo.php
echo '<?php class FooTest {}' > tests/FooTest.php
git add -A
evidence 'vendor/bin/phpunit -c phpunit.xml'
t 2 "helper needs its spec run" "checkout.page.ts"

# 22. cd-relative spec path resolves against the cd dir
mkrepo
mkdir -p sub/tests sub/src
echo 'export const a = 1;' > sub/src/cart.ts
echo 'import { a } from "../src/cart";' > sub/tests/cart.spec.ts
git add -A
evidence 'cd sub && npx playwright test tests/cart.spec.ts'
t 0 "cd-relative spec path"

# --- Python (2026-10-08) ------------------------------------------------------
mkpyrepo() { # armed by pyproject [tool.pytest...] only — no phpunit
  D=$(mktemp -d); cd "$D" || exit 1
  git init -q; git config user.email t@t; git config user.name t
  printf '[project]\nname="x"\n[tool.pytest.ini_options]\ntestpaths=["tests"]\n' > pyproject.toml
  git add -A && git commit -qm init
}

# 23. py source, mapped tests/test_bar.py, broad pytest run -> pass
mkpyrepo
mkdir -p src/pkg/foo tests/unit
echo 'def bar(): return 1' > src/pkg/foo/bar.py
echo 'from pkg.foo.bar import bar' > tests/unit/test_bar.py
git add -A
evidence 'uv run pytest -q'
t 0 "py mapped test + broad pytest"

# 24. py source with no evidence -> blocked (gate armed by pyproject)
mkpyrepo
mkdir -p src/pkg tests
echo 'def bar(): return 1' > src/pkg/bar.py
echo 'from pkg.bar import bar' > tests/test_bar.py
git add -A
t 2 "py commit without evidence blocked" "pytest (target"

# 25. py source, no test anywhere -> relevance block
mkpyrepo
mkdir -p src/pkg
echo 'def qux(): return 1' > src/pkg/qux.py
git add -A
evidence 'pytest'
t 2 "py no test exists" "No test found that specifically covers"

# 26. targeted pytest on unrelated file -> block; then -k naming it -> pass
mkpyrepo
mkdir -p src/pkg tests
echo 'def bar(): return 1' > src/pkg/bar.py
echo 'import pkg.bar' > tests/test_bar.py
echo 'x = 1' > tests/test_other.py
git add -A
evidence 'pytest tests/test_other.py'
t 2 "py unrelated targeted run" "did NOT execute"
evidence 'python -m pytest -k bar'
t 0 "py -k expr covers test_bar"

# 27. node::id targeted run naming the candidate -> pass
mkpyrepo
mkdir -p src/pkg tests
echo 'def bar(): return 1' > src/pkg/bar.py
echo 'import pkg.bar' > tests/test_bar.py
git add -A
evidence '.venv/bin/pytest tests/test_bar.py::test_it'
t 0 "py node-id targeted run"

# 28. phpunit run never covers a python test
mkpyrepo
mkdir -p src/pkg tests
echo 'def bar(): return 1' > src/pkg/bar.py
echo 'import pkg.bar' > tests/test_bar.py
git add -A
evidence 'vendor/bin/phpunit'
t 2 "phpunit never covers test_*.py" "did NOT execute"

# 29. PHP regression: .py file in a phpunit-only repo stays ungated
mkrepo
mkdir -p tools
echo 'print(1)' > tools/helper.py
git add -A
t 0 "php repo: stray .py not gated"

# 30. pure python test commit, conftest included -> no evidence needed
mkpyrepo
mkdir -p tests
echo 'import pytest' > tests/conftest.py
echo 'def test_a(): pass' > tests/test_a.py
git add -A
t 0 "py pure test commit skips gate"

# 31. pytest.ini alone arms the gate
D=$(mktemp -d); cd "$D" || exit 1
git init -q; git config user.email t@t; git config user.name t
printf '[pytest]\n' > pytest.ini; git add -A; git commit -qm init
echo 'x=1' > mod.py; git add -A
t 2 "pytest.ini arms gate" "without passing test evidence"

# 32-34. coverage layer: Cobertura (py) + clover (php regression)
covrepo_py() { # $1 = hits for line 1
  mkpyrepo; mkdir -p src/pkg tests .claude
  echo 'def bar(): return 1' > src/pkg/bar.py
  echo 'import pkg.bar' > tests/test_bar.py
  echo '{"coverage":{"cobertura":"coverage.xml","min_pct":60}}' > .claude/test-gate.json
  echo '.claude/' > .gitignore; echo 'coverage.xml' >> .gitignore
  printf '<?xml version="1.0" ?>\n<coverage><sources><source>%s/src</source></sources><packages><package name="pkg"><classes><class filename="pkg/bar.py"><lines><line number="1" hits="%s"/></lines></class></classes></package></packages></coverage>\n' "$D" "$1" > coverage.xml
  touch -d '+1 min' coverage.xml
  git add -A; evidence 'pytest'
}
covrepo_py 3; t 0 "cobertura covered py lines pass"
covrepo_py 0; t 2 "cobertura uncovered py lines block" "changed-line coverage"
mkrepo; mkdir -p src tests .claude
echo '<?php class Foo {}' > src/Foo.php; echo '<?php class FooTest {}' > tests/FooTest.php
echo '{"coverage":{"clover":"clover.xml","min_pct":60}}' > .claude/test-gate.json
printf '.claude/\nclover.xml\n' > .gitignore
printf '<coverage><project><file name="%s/src/Foo.php"><line num="1" type="stmt" count="0"/></file></project></coverage>\n' "$D" > clover.xml
touch -d '+1 min' clover.xml
git add -A; evidence 'vendor/bin/phpunit'
t 2 "clover php regression still blocks uncovered" "changed-line coverage"

echo "relevance suite: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
