#!/bin/bash
# Test suite for tsc-edit-check.sh — feed PostToolUse JSON, assert behavior.
# Non-blocking hook (always exit 0); assertions are on stderr content.
# tsc-dependent cases SKIP (not fail) when tsc isn't on PATH — this hook is
# meant to run inside a project container with TypeScript installed, not
# necessarily on the bare host. The no-tsc/no-match/no-file paths are
# host-testable regardless and always run.
# Run: bash tsc-edit-check.test.sh

HOOK="$(cd "$(dirname "$0")" && pwd)/tsc-edit-check.sh"
PASS=0; FAIL=0; SKIP=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1"; }

run() { # run <file_path>
  printf '{"tool_input":{"file_path":%s}}' "$(printf '%s' "$1" | jq -Rs .)" \
    | bash "$HOOK" > /tmp/tsc-check-out.txt 2>&1
  RC=$?
}

# --- always exit 0 (informational only) ---------------------------------------
D=$(mktemp -d)
echo 'const x: number = 1;' > "$D/valid.ts"
run "$D/valid.ts"
[ "$RC" = 0 ] && ok || bad "expected exit 0 always (non-blocking), got $RC"

# --- silent no-op: non-TS file --------------------------------------------------
echo '<?php echo 1;' > "$D/file.php"
run "$D/file.php"
[ ! -s /tmp/tsc-check-out.txt ] && ok || bad "expected silent no-op on non-.ts file"

# --- silent no-op: missing file --------------------------------------------------
run "$D/does-not-exist.ts"
[ ! -s /tmp/tsc-check-out.txt ] && ok || bad "expected silent no-op on missing file"

# --- tsc-dependent behavior -------------------------------------------------------
if command -v tsc >/dev/null 2>&1; then
  echo 'const x: number = "not a number";' > "$D/bad.ts"
  run "$D/bad.ts"
  if [ -s /tmp/tsc-check-out.txt ] && grep -q "tsc-edit-check" /tmp/tsc-check-out.txt; then ok; else bad "expected tsc error surfaced for type mismatch"; fi

  echo 'const y: number = 5;' > "$D/good.ts"
  run "$D/good.ts"
  [ ! -s /tmp/tsc-check-out.txt ] && ok || bad "expected silent on type-clean file"
else
  skip "tsc not on PATH — type-mismatch/type-clean cases need a real TS toolchain"
  skip "tsc not on PATH — type-clean-file case"
fi

rm -rf "$D" /tmp/tsc-check-out.txt

echo "tsc-edit-check tests: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = 0 ]
