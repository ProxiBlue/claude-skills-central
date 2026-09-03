#!/bin/bash
# Test suite for post-commit-wiki-check.sh — feed PostToolUse JSON, assert
# stdout content (this hook never blocks — exit is always 0).
# Run: bash post-commit-wiki-check.test.sh

HOOK="$(cd "$(dirname "$0")" && pwd)/post-commit-wiki-check.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

D=$(mktemp -d)
git -C "$D" init -q .
git -C "$D" config user.email t@t; git -C "$D" config user.name t
mkdir -p "$D/wiki"
echo "# Notes" > "$D/wiki/notes.md"
git -C "$D" checkout -q -b live
echo x > "$D/f.txt"
git -C "$D" add -A
git -C "$D" commit -qm "fix: #123 handle edge case"

run() { # run <cwd> <command>  -> writes stdout to $OUT
  OUT=$(printf '{"tool_input":{"command":%s},"cwd":%s}' \
    "$(printf '%s' "$2" | jq -Rs .)" "$(printf '%s' "$1" | jq -Rs .)" \
    | bash "$HOOK" 2>/dev/null)
}

# --- fires: push to a watched branch, wiki dir + ticket present --------------
run "$D" "git push origin live"
if echo "$OUT" | grep -q "WIKI CHECK" && echo "$OUT" | grep -q "#123"; then ok; else bad "expected WIKI CHECK with #123, got: $OUT"; fi

# --- silent: push to an unwatched branch --------------------------------------
git -C "$D" checkout -q -b feature/x
run "$D" "git push origin feature/x"
[ -z "$OUT" ] && ok || bad "expected silent on feature branch push, got: $OUT"

# --- silent: non-push command -------------------------------------------------
run "$D" "git status"
[ -z "$OUT" ] && ok || bad "expected silent on non-push command, got: $OUT"

# --- silent: no wiki dir ------------------------------------------------------
D2=$(mktemp -d)
git -C "$D2" init -q . ; git -C "$D2" config user.email t@t; git -C "$D2" config user.name t
git -C "$D2" checkout -q -b live
git -C "$D2" commit -q --allow-empty -m "fix: #99 thing"
run "$D2" "git push origin live"
[ -z "$OUT" ] && ok || bad "expected silent with no wiki dir, got: $OUT"
rm -rf "$D2"

# --- custom watched branches via env ------------------------------------------
git -C "$D" checkout -q -b custom-deploy
git -C "$D" commit -q --allow-empty -m "fix: #55 custom"
OUT=$(printf '{"tool_input":{"command":"git push origin custom-deploy"},"cwd":%s}' "$(printf '%s' "$D" | jq -Rs .)" \
  | CLAUDE_WIKI_BRANCHES="custom-deploy" bash "$HOOK" 2>/dev/null)
if echo "$OUT" | grep -q "WIKI CHECK"; then ok; else bad "expected WIKI CHECK via CLAUDE_WIKI_BRANCHES override, got: $OUT"; fi

rm -rf "$D"

echo "post-commit-wiki-check tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
