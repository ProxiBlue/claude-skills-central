#!/bin/bash
# Test suite for xml-wellformed-check.sh — feed PostToolUse JSON, assert exit
# code. Exercises all three parser fallbacks (xmllint / php / python3) by
# restricting PATH, plus the "no parser available" and opt-out paths.
# Run: bash xml-wellformed-check.test.sh

HOOK="$(cd "$(dirname "$0")" && pwd)/xml-wellformed-check.sh"
# Absolute path: a `PATH=<restricted> bash ...` invocation resolves "bash"
# itself against the NEW PATH (the assignment applies to the command's own
# lookup too), so restricted-PATH test cases below would 127 looking for
# bash unless we invoke it by absolute path instead.
BASH_BIN="$(command -v bash)"
PASS=0; FAIL=0

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

GOOD="$WORK/good.xml"
BAD="$WORK/bad.xml"
cat > "$GOOD" <<'EOF'
<?xml version="1.0"?>
<config><foo>bar</foo></config>
EOF
cat > "$BAD" <<'EOF'
<?xml version="1.0"?>
<config>
  <!-- disable foo -- see TICKET-123 -->
  <foo>bar</foo>
</config>
EOF

# t <expected-exit> <desc> <file> [path-override]
t() {
  local expect="$1" desc="$2" file="$3" path_override="${4:-}"
  local got
  if [ -n "$path_override" ]; then
    printf '{"tool_input":{"file_path":%s}}' "$(printf '%s' "$file" | jq -Rs .)" \
      | PATH="$path_override" "$BASH_BIN" "$HOOK" >/dev/null 2>&1
  else
    printf '{"tool_input":{"file_path":%s}}' "$(printf '%s' "$file" | jq -Rs .)" \
      | "$BASH_BIN" "$HOOK" >/dev/null 2>&1
  fi
  got=$?
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL ($desc): expected exit $expect got $got — file: $file"
  fi
}

# --- default PATH (xmllint present on this host) -----------------------------
t 0 "well-formed xml, default path"   "$GOOD"
t 2 "malformed xml (-- in comment)"   "$BAD"

# --- non-xml files / missing files always pass -------------------------------
NONXML="$WORK/notes.txt"; echo "hello" > "$NONXML"
t 0 "non-xml file untouched"          "$NONXML"
t 0 "missing file"                    "$WORK/does-not-exist.xml"

# --- fallback chain: restrict PATH to force each parser branch --------------
build_restricted_path() { # build_restricted_path <dir> <bin1> [bin2 ...]
  # Always includes the coreutils the hook script itself needs (cat, grep,
  # sed, rm, dirname, ...) plus git/jq; <bin1 ...> controls which XML
  # PARSER(S) are reachable, which is the thing each test case varies.
  local dir="$1"; shift
  mkdir -p "$dir"
  local core="cat grep sed rm dirname basename mkdir ln cut head printf test [ env"
  for b in $core jq git "$@"; do
    local real; real=$(command -v "$b" 2>/dev/null)
    [ -n "$real" ] && ln -sf "$real" "$dir/$b"
  done
  echo "$dir"
}

# xmllint missing -> falls to php DOMDocument
if command -v php >/dev/null 2>&1; then
  PHP_ONLY=$(build_restricted_path "$WORK/path-php" php)
  t 2 "fallback to php: malformed"  "$BAD"  "$PHP_ONLY"
  t 0 "fallback to php: well-formed" "$GOOD" "$PHP_ONLY"
fi

# xmllint + php missing -> falls to python3 minidom
if command -v python3 >/dev/null 2>&1; then
  PY_ONLY=$(build_restricted_path "$WORK/path-py" python3)
  t 2 "fallback to python3: malformed"  "$BAD"  "$PY_ONLY"
  t 0 "fallback to python3: well-formed" "$GOOD" "$PY_ONLY"
fi

# no parser at all -> silent no-op (exit 0), even on malformed xml
NONE=$(build_restricted_path "$WORK/path-none")
t 0 "no parser available -> silent pass on malformed" "$BAD" "$NONE"

# --- MultiEdit-shaped input (flat file_path key still honored) --------------
printf '{"file_path":%s}' "$(printf '%s' "$BAD" | jq -Rs .)" | "$BASH_BIN" "$HOOK" >/dev/null 2>&1
RC=$?
[ "$RC" = 2 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (flat file_path key): exit $RC"; }

# --- rules-disable opt-out ----------------------------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO/.claude"
( cd "$REPO" && git init -q . )
echo xml-wellformed-check > "$REPO/.claude/rules-disable"
cp "$BAD" "$REPO/bad.xml"
printf '{"tool_input":{"file_path":%s}}' "$(printf '%s' "$REPO/bad.xml" | jq -Rs .)" \
  | "$BASH_BIN" "$HOOK" >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (rules-disable opt-out): exit $RC"; }

# --- fails soft ---------------------------------------------------------------
echo '' | "$BASH_BIN" "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: empty input should no-op"; }
echo 'not json' | "$BASH_BIN" "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: garbage input should no-op"; }

echo "xml-wellformed-check tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
