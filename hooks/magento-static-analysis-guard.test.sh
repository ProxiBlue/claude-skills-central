#!/bin/bash
# Test suite for magento-static-analysis-guard.sh — feed PreToolUse JSON
# against a scratch repo with fake phpcs/phpstan binaries, assert exit code.
# Run: bash magento-static-analysis-guard.test.sh

HOOK="$(cd "$(dirname "$0")" && pwd)/magento-static-analysis-guard.sh"
PASS=0; FAIL=0

# fake_phpcs <repo> <json-body>
# Writes a fake vendor/bin/phpcs that ignores its args and just prints the
# given --report=json body (the hook only cares about parsed JSON, not which
# files/flags were actually passed).
fake_phpcs() {
  printf '#!/bin/bash\ncat <<'"'"'JSON'"'"'\n%s\nJSON\n' "$2" > "$1/vendor/bin/phpcs"
  chmod +x "$1/vendor/bin/phpcs"
}

fake_phpstan() {
  printf '#!/bin/bash\nexit %s\n' "$2" > "$1/vendor/bin/phpstan"
  chmod +x "$1/vendor/bin/phpstan"
  echo 'parameters: {}' > "$1/phpstan.neon"
}

EMPTY_JSON='{"files":{}}'

# base_repo — one committed file (3 lines) under app/code, HEAD clean.
# Returns the repo path; caller then stages whatever change it wants.
base_repo() {
  local tmp; tmp=$(mktemp -d)
  ( cd "$tmp" && git init -q .
    git config user.email t@t.com && git config user.name t
    mkdir -p app/code/Vendor/Module vendor/bin
    printf 'line1\nline2\nline3\n' > app/code/Vendor/Module/Foo.php
    git add -A && git commit -q -m init
  ) >/dev/null 2>&1
  echo "$tmp"
}

t() { # t <expected-exit> <desc> <repo-dir>
  local expect="$1" desc="$2" repo="$3"
  printf '{"tool_input":{"command":"git commit -m x"},"cwd":%s}' "$(printf '%s' "$repo" | jq -Rs .)" \
    | (cd "$repo" && bash "$HOOK") >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL ($desc): expected exit $expect got $got"
  fi
}

# --- clean run: both tools quiet ----------------------------------------------
R=$(base_repo)
( cd "$R" && printf 'line1\nline2\nline3\nline4\n' > app/code/Vendor/Module/Foo.php && git add -A ) >/dev/null 2>&1
fake_phpcs "$R" "$EMPTY_JSON"; fake_phpstan "$R" 0
t 0 "clean phpcs+phpstan" "$R"; rm -rf "$R"

# --- phpcs ERROR on the newly-added line (line 4) — blocks --------------------
R=$(base_repo)
( cd "$R" && printf 'line1\nline2\nline3\nline4\n' > app/code/Vendor/Module/Foo.php && git add -A ) >/dev/null 2>&1
fake_phpcs "$R" '{"files":{"app/code/Vendor/Module/Foo.php":{"errors":1,"warnings":0,"messages":[{"message":"bad thing","source":"Magento2.Foo.Bar","severity":5,"type":"ERROR","line":4,"column":1}]}}}'
fake_phpstan "$R" 0
t 2 "phpcs error on changed line" "$R"; rm -rf "$R"

# --- phpcs ERROR on a pre-existing, untouched line — grandfathered ------------
R=$(base_repo)
( cd "$R" && printf 'line1\nline2\nline3\nline4\n' > app/code/Vendor/Module/Foo.php && git add -A ) >/dev/null 2>&1
fake_phpcs "$R" '{"files":{"app/code/Vendor/Module/Foo.php":{"errors":1,"warnings":0,"messages":[{"message":"old debt","source":"Magento2.Foo.Bar","severity":5,"type":"ERROR","line":1,"column":1}]}}}'
fake_phpstan "$R" 0
t 0 "phpcs error on pre-existing line is grandfathered" "$R"; rm -rf "$R"

# --- phpcs WARNING on the changed line — never blocks -------------------------
R=$(base_repo)
( cd "$R" && printf 'line1\nline2\nline3\nline4\n' > app/code/Vendor/Module/Foo.php && git add -A ) >/dev/null 2>&1
fake_phpcs "$R" '{"files":{"app/code/Vendor/Module/Foo.php":{"errors":0,"warnings":1,"messages":[{"message":"style nit","source":"Magento2.Foo.Bar","severity":3,"type":"WARNING","line":4,"column":1}]}}}'
fake_phpstan "$R" 0
t 0 "phpcs warning on changed line does not block" "$R"; rm -rf "$R"

# --- phpstan non-zero — blocks --------------------------------------------------
R=$(base_repo)
( cd "$R" && printf 'line1\nline2\nline3\nline4\n' > app/code/Vendor/Module/Foo.php && git add -A ) >/dev/null 2>&1
fake_phpcs "$R" "$EMPTY_JSON"; fake_phpstan "$R" 1
t 2 "phpstan violation" "$R"; rm -rf "$R"

# --- tools not installed — silent no-op ---------------------------------------
R=$(base_repo)
( cd "$R" && printf 'line1\nline2\nline3\nline4\n' > app/code/Vendor/Module/Foo.php && git add -A ) >/dev/null 2>&1
t 0 "no phpcs/phpstan installed" "$R"; rm -rf "$R"

R=$(base_repo)
( cd "$R" && printf 'line1\nline2\nline3\nline4\n' > app/code/Vendor/Module/Foo.php && git add -A ) >/dev/null 2>&1
fake_phpcs "$R" "$EMPTY_JSON"
t 0 "phpstan missing" "$R"; rm -rf "$R"

R=$(base_repo)
( cd "$R" && printf 'line1\nline2\nline3\nline4\n' > app/code/Vendor/Module/Foo.php && git add -A ) >/dev/null 2>&1
fake_phpstan "$R" 0
t 0 "phpcs missing" "$R"; rm -rf "$R"

# --- not a commit --------------------------------------------------------------
R=$(base_repo)
fake_phpcs "$R" '{"files":{"app/code/Vendor/Module/Foo.php":{"errors":1,"warnings":0,"messages":[{"message":"x","source":"y","severity":5,"type":"ERROR","line":1,"column":1}]}}}'
fake_phpstan "$R" 1
printf '{"tool_input":{"command":"git status"},"cwd":%s}' "$(printf '%s' "$R" | jq -Rs .)" \
  | (cd "$R" && bash "$HOOK") >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (not a commit)"; }
rm -rf "$R"

# --- no staged app/code|app/design files ---------------------------------------
R=$(mktemp -d); (
  cd "$R" && git init -q . && git config user.email t@t.com && git config user.name t
  mkdir -p vendor/bin lib
  echo '<?php' > lib/Other.php
  git add lib/Other.php
) >/dev/null 2>&1
fake_phpcs "$R" '{"files":{"lib/Other.php":{"errors":1,"warnings":0,"messages":[{"message":"x","source":"y","severity":5,"type":"ERROR","line":1,"column":1}]}}}'
fake_phpstan "$R" 1
t 0 "no staged app/code or app/design files" "$R"
rm -rf "$R"

# --- rules-disable opt-out ------------------------------------------------------
R=$(base_repo)
( cd "$R" && printf 'line1\nline2\nline3\nline4\n' > app/code/Vendor/Module/Foo.php && git add -A ) >/dev/null 2>&1
fake_phpcs "$R" '{"files":{"app/code/Vendor/Module/Foo.php":{"errors":1,"warnings":0,"messages":[{"message":"x","source":"y","severity":5,"type":"ERROR","line":4,"column":1}]}}}'
fake_phpstan "$R" 1
mkdir -p "$R/.claude"; echo magento-static-analysis-guard > "$R/.claude/rules-disable"
t 0 "rules-disable opt-out" "$R"
rm -rf "$R"

echo "magento-static-analysis-guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
