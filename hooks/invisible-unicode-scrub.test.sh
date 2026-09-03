#!/bin/bash
# Test suite for invisible-unicode-scrub.sh — feed PostToolUse JSON, assert
# the target file gets cleaned in place (never blocks — exit always 0).
# Run: bash invisible-unicode-scrub.test.sh

HOOK="$(cd "$(dirname "$0")" && pwd)/invisible-unicode-scrub.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

D=$(mktemp -d)

run() { # run <file_path>
  printf '{"tool_input":{"file_path":%s}}' "$(printf '%s' "$1" | jq -Rs .)" | bash "$HOOK" > /tmp/scrub-out.txt 2>&1
  RC=$?
}

# --- strips zero-width chars from a file Claude wrote --------------------------
printf 'hello\xe2\x80\x8bworld' > "$D/dirty.txt"   # U+200B zero-width space
run "$D/dirty.txt"
if [ "$RC" = 0 ] && ! grep -qP '\x{200B}' "$D/dirty.txt"; then ok; else bad "expected zero-width space stripped, rc=$RC"; fi

# --- silent on a clean file ------------------------------------------------------
printf 'plain ascii text\n' > "$D/clean.txt"
run "$D/clean.txt"
[ ! -s /tmp/scrub-out.txt ] && ok || bad "expected silent on clean file, got: $(cat /tmp/scrub-out.txt)"

# --- silent no-op: binary extension excluded --------------------------------------
printf 'not really png but ext matters' > "$D/img.png"
run "$D/img.png"
[ "$RC" = 0 ] && [ ! -s /tmp/scrub-out.txt ] && ok || bad "expected silent no-op on .png extension"

# --- silent no-op: missing file ----------------------------------------------------
run "$D/does-not-exist.txt"
[ "$RC" = 0 ] && [ ! -s /tmp/scrub-out.txt ] && ok || bad "expected silent no-op on missing file"

rm -rf "$D" /tmp/scrub-out.txt

echo "invisible-unicode-scrub tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
