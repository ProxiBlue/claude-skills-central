#!/bin/bash
# Test suite for invisible-unicode-read-check.sh — feed PostToolUse JSON,
# assert warn-only behavior (never modifies the file, exit always 0).
# Run: bash invisible-unicode-read-check.test.sh

HOOK="$(cd "$(dirname "$0")" && pwd)/invisible-unicode-read-check.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

D=$(mktemp -d)

run() { # run <file_path>
  printf '{"tool_input":{"file_path":%s}}' "$(printf '%s' "$1" | jq -Rs .)" | bash "$HOOK" > /tmp/uread-out.txt 2>&1
  RC=$?
}

# --- warns on hidden text, file left UNMODIFIED --------------------------------
printf 'hello\xe2\x80\x8bworld' > "$D/dirty.txt"   # U+200B zero-width space
BEFORE=$(md5sum "$D/dirty.txt" | cut -d' ' -f1)
run "$D/dirty.txt"
AFTER=$(md5sum "$D/dirty.txt" | cut -d' ' -f1)
if [ "$RC" = 0 ] && grep -q "WARNING" /tmp/uread-out.txt && [ "$BEFORE" = "$AFTER" ]; then
  ok
else
  bad "expected WARNING + file untouched, rc=$RC before=$BEFORE after=$AFTER out=$(cat /tmp/uread-out.txt)"
fi

# --- silent on a clean file -------------------------------------------------------
printf 'plain ascii text\n' > "$D/clean.txt"
run "$D/clean.txt"
[ ! -s /tmp/uread-out.txt ] && ok || bad "expected silent on clean file, got: $(cat /tmp/uread-out.txt)"

# --- silent no-op: binary extension excluded ---------------------------------------
printf 'not really pdf' > "$D/doc.pdf"
run "$D/doc.pdf"
[ "$RC" = 0 ] && [ ! -s /tmp/uread-out.txt ] && ok || bad "expected silent no-op on .pdf extension"

rm -rf "$D" /tmp/uread-out.txt

echo "invisible-unicode-read-check tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
