#!/bin/bash
# Test suite for plugin-hooks-lint.sh.
# Run: bash plugin-hooks-lint.test.sh   (exit 0 = all green)

SCRIPT="$(cd "$(dirname "$0")" && pwd)/plugin-hooks-lint.sh"
PASS=0; FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

t() { # t <expected-exit> <desc> <dir>
  local expect="$1" desc="$2" dir="$3"
  bash "$SCRIPT" "$dir" >"$TMP/out.txt" 2>&1
  local got=$?
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL ($desc): expected exit $expect got $got"; cat "$TMP/out.txt"; fi
}

# --- fixture: shell-form referencing user_config, no args (the real bug) ----
BAD="$TMP/bad-plugin/hooks"; mkdir -p "$BAD"
cat > "$BAD/hooks.json" <<'EOF'
{
  "hooks": {
    "SessionEnd": [
      { "hooks": [ { "type": "command",
        "command": "GRAPHITI_URL=\"${user_config.graphiti_url}\" python3 \"${CLAUDE_PLUGIN_ROOT}/scripts/x.py\" session-end",
        "timeout": 200 } ] }
    ]
  }
}
EOF
t 1 "shell-form user_config, no args" "$TMP/bad-plugin"

# --- fixture: exec-form with args — allowed even though it names user_config
GOOD="$TMP/good-plugin/hooks"; mkdir -p "$GOOD"
cat > "$GOOD/hooks.json" <<'EOF'
{
  "hooks": {
    "SessionEnd": [
      { "hooks": [ { "type": "command",
        "command": "python3",
        "args": ["${CLAUDE_PLUGIN_ROOT}/scripts/x.py", "session-end", "--url", "${user_config.graphiti_url}"],
        "timeout": 200 } ] }
    ]
  }
}
EOF
t 0 "exec-form with args" "$TMP/good-plugin"

# --- fixture: shell-form but only CLAUDE_PLUGIN_ROOT (no user_config) — allowed
PLAIN="$TMP/plain-plugin/hooks"; mkdir -p "$PLAIN"
cat > "$PLAIN/hooks.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command",
        "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/nudge.sh\"",
        "timeout": 5 } ] }
    ]
  }
}
EOF
t 0 "shell-form, plugin-root only" "$TMP/plain-plugin"

# --- fixture: two plugins in one scan dir, one bad one good --------------
MULTI="$TMP/multi"; mkdir -p "$MULTI/a/hooks" "$MULTI/b/hooks"
cp "$BAD/hooks.json" "$MULTI/a/hooks/hooks.json"
cp "$GOOD/hooks.json" "$MULTI/b/hooks/hooks.json"
t 1 "mixed dir, one violation" "$MULTI"

# --- no hooks.json at all — clean ------------------------------------------
EMPTY="$TMP/empty"; mkdir -p "$EMPTY"
t 0 "no manifests present" "$EMPTY"

# --- the real fleet fixture: pb-graphiti's actual seeded manifest must now
# be clean (regression guard for the 2026-09-08 incident this script exists
# to catch)
REAL="$HOME/claude-plugins-central/seed/marketplaces"
if [ -d "$REAL" ]; then
  t 0 "real fleet seed marketplaces clean" "$REAL"
fi

echo "plugin-hooks-lint tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
