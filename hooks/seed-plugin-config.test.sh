#!/bin/bash
# Tests for seed-plugin-config.sh (auto-discovered by scripts/rule-evals.sh).
set -u
H="$(cd "$(dirname "$0")" && pwd)/seed-plugin-config.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
url() { jq -r '.pluginConfigs["pb-graphiti@pb-graphiti"].options.graphiti_url // empty' "$1"; }

# 1. missing file -> created with default url
bash "$H" "$T/a.json" >/dev/null
[ "$(url "$T/a.json")" = "http://host.docker.internal:8765/mcp" ] && ok "missing file seeded" || bad "missing file seeded"

# 2. existing settings kept, url added
echo '{"theme":"dark","pluginConfigs":{"pb-graphiti@pb-graphiti":{"options":{"imap_host":"x"}}}}' > "$T/b.json"
bash "$H" "$T/b.json" >/dev/null
[ "$(jq -r .theme "$T/b.json")" = dark ] && [ "$(jq -r '.pluginConfigs["pb-graphiti@pb-graphiti"].options.imap_host' "$T/b.json")" = x ] \
  && [ -n "$(url "$T/b.json")" ] && ok "other keys preserved" || bad "other keys preserved"

# 3. existing url never overwritten
echo '{"pluginConfigs":{"pb-graphiti@pb-graphiti":{"options":{"graphiti_url":"http://elsewhere/mcp"}}}}' > "$T/c.json"
bash "$H" "$T/c.json" >/dev/null
[ "$(url "$T/c.json")" = "http://elsewhere/mcp" ] && ok "existing url wins" || bad "existing url wins"

# 4. invalid json left untouched, exit 0
echo 'not json' > "$T/d.json"
bash "$H" "$T/d.json" 2>/dev/null; rc=$?
[ $rc = 0 ] && [ "$(cat "$T/d.json")" = "not json" ] && ok "invalid json untouched" || bad "invalid json untouched"

# 5. idempotent: second run changes nothing
cp "$T/a.json" "$T/a.bak"; bash "$H" "$T/a.json" >/dev/null
cmp -s "$T/a.json" "$T/a.bak" && ok "idempotent" || bad "idempotent"

exit $fail
