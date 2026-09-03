#!/bin/bash
# Test suite for pre-commit-audit.sh — feed PreToolUse JSON in a scratch repo
# with staged files, assert exit code. phpcs/phpstan-dependent cases SKIP
# (not fail) when those tools aren't on PATH/vendor'd — this hook is meant to
# run inside a project container with them installed.
# Run: bash pre-commit-audit.test.sh

HOOK="$(cd "$(dirname "$0")" && pwd)/pre-commit-audit.sh"
PASS=0; FAIL=0; SKIP=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1"; }

D=$(mktemp -d)
git -C "$D" init -q .
git -C "$D" config user.email t@t; git -C "$D" config user.name t
cd "$D" || exit 1

run() { # run <command>
  printf '{"tool_input":{"command":%s},"cwd":%s}' \
    "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$D" | jq -Rs .)" \
    | bash "$HOOK" >/tmp/pca-out.txt 2>&1
  RC=$?
}

# --- silent: no staged PHP/XML -------------------------------------------------
echo "hello" > readme.txt
git add -A
run 'git commit -m "docs: readme"'
[ "$RC" = 0 ] && ok || bad "expected exit 0 with no staged PHP/XML, got $RC: $(cat /tmp/pca-out.txt)"

# --- silent: non-commit command -------------------------------------------------
echo '<?php echo 1;' > file.php
git add -A
run 'git status'
[ "$RC" = 0 ] && ok || bad "expected exit 0 on non-commit command"

# --- blocked: invalid staged XML (xmllint always available if on PATH) --------
if command -v xmllint >/dev/null 2>&1; then
  printf '<?xml version="1.0"?><root><unclosed></root>' > bad.xml
  git add bad.xml
  run 'git commit -m "fix: config"'
  [ "$RC" = 2 ] && ok || bad "expected block on invalid XML, got $RC: $(cat /tmp/pca-out.txt)"
  git reset -q bad.xml; rm -f bad.xml
else
  skip "xmllint not on PATH — invalid-XML block case"
fi

# --- allowed: valid staged XML ---------------------------------------------------
if command -v xmllint >/dev/null 2>&1; then
  printf '<?xml version="1.0"?><root><ok/></root>' > good.xml
  git add good.xml
  run 'git commit -m "fix: config"'
  [ "$RC" = 0 ] && ok || bad "expected pass on valid XML, got $RC: $(cat /tmp/pca-out.txt)"
  git reset -q good.xml; rm -f good.xml
else
  skip "xmllint not on PATH — valid-XML pass case"
fi

# --- blocked: narration-comment noise in staged PHP (no external tool needed) ---
mkdir -p app/code/Vendor/Module
cat > app/code/Vendor/Module/Thing.php <<'EOF'
<?php
declare(strict_types=1);
function total(array $items): int
{
    // Loop through items and sum them
    $sum = 0;
    foreach ($items as $i) {
        $sum += $i;
    }
    return $sum;
}
EOF
git add app/code/Vendor/Module/Thing.php
run 'git commit -m "feat: add total helper"'
if [ "$RC" = 2 ] && grep -q "comment noise" /tmp/pca-out.txt; then ok; else bad "expected block on narration comment, got $RC: $(cat /tmp/pca-out.txt)"; fi
git reset -q app/code/Vendor/Module/Thing.php

# --- allowed: PHP with no narration comments, no phpcs/phpstan present ----------
if [ ! -f vendor/bin/phpcs ]; then
  cat > app/code/Vendor/Module/Clean.php <<'EOF'
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
  git add app/code/Vendor/Module/Clean.php
  run 'git commit -m "feat: add clean helper"'
  [ "$RC" = 0 ] && ok || bad "expected pass on clean PHP with no phpcs configured, got $RC: $(cat /tmp/pca-out.txt)"
else
  skip "vendor/bin/phpcs present in this cwd — clean-PHP-no-tooling case not applicable"
fi

cd /
rm -rf "$D" /tmp/pca-out.txt

echo "pre-commit-audit tests: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = 0 ]
