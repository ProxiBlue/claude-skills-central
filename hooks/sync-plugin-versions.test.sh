#!/bin/bash
# Tests for sync-plugin-versions.sh (auto-discovered by scripts/rule-evals.sh).
set -u
H="$(cd "$(dirname "$0")" && pwd)/sync-plugin-versions.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }

SEED="$T/seed"; PL="$T/plugins"
mkseed() { mkdir -p "$SEED/$1/.claude-plugin"; echo "{\"name\":\"$1\",\"version\":\"$2\"}" > "$SEED/$1/.claude-plugin/plugin.json"; echo x > "$SEED/$1/marker"; }
ver() { jq -r --arg k "$1" --arg s "$2" '[.plugins[$k][] | select(.scope==$s)][0].version' "$PL/installed_plugins.json"; }
run() { PB_PLUGIN_SYNC_PROJECT=/var/www/html bash "$H" "$@" "$SEED" "$PL"; }
reset() {
  rm -rf "$SEED" "$PL"; mkdir -p "$PL"
  mkseed pb-hcf 0.6.0; mkseed hcf 2.0.1; mkseed pb-board 0.2.0
  cat > "$PL/installed_plugins.json" <<'JSON'
{"version":2,"plugins":{
 "pb-hcf@pb-hcf":[{"scope":"project","projectPath":"/var/www/html","version":"0.5.0","installPath":"/old"}],
 "hcf@hcf":[{"scope":"project","projectPath":"/var/www/html","version":"2.0.0","installPath":"/old"}],
 "pb-board@pb-board":[{"scope":"user","version":"0.1.0","installPath":"/old"},
                      {"scope":"project","projectPath":"/somewhere/else","version":"0.1.0","installPath":"/old"}],
 "remote@remote":[{"scope":"user","version":"1.0.0","installPath":"/old"}]
}}
JSON
}

# 1. project-scope entry for this project advances (the ahhgg freeze)
reset; run >/dev/null
[ "$(ver pb-hcf@pb-hcf project)" = 0.6.0 ] && [ -f "$PL/cache/pb-hcf/pb-hcf/0.6.0/marker" ] \
  && ok "project-scope advances + cache materialised" || bad "project-scope advances + cache materialised"

# 2. excluded plugin advances within the same major (hcf 2.0.0 -> 2.0.1)
[ "$(ver hcf@hcf project)" = 2.0.1 ] && ok "excluded same-major advances" || bad "excluded same-major advances"

# 3. user scope advances; another project's project-scope entry untouched
[ "$(ver pb-board@pb-board user)" = 0.2.0 ] \
  && [ "$(jq -r '.plugins["pb-board@pb-board"][] | select(.projectPath=="/somewhere/else") | .version' "$PL/installed_plugins.json")" = 0.1.0 ] \
  && ok "user advances, foreign project untouched" || bad "user advances, foreign project untouched"

# 4. non-seeded plugin left alone
[ "$(ver remote@remote user)" = 1.0.0 ] && ok "non-seeded untouched" || bad "non-seeded untouched"

# 5. idempotent: second run reports 0 changes, manifest unchanged
cp "$PL/installed_plugins.json" "$T/m.bak"; out="$(run)"
cmp -s "$PL/installed_plugins.json" "$T/m.bak" && echo "$out" | grep -q '(0 change(s))' \
  && ok "idempotent" || bad "idempotent"

# 6. excluded plugin crossing a major is NOT advanced
reset; jq '.plugins["hcf@hcf"][0].version="1.1.1"' "$PL/installed_plugins.json" > "$T/m" && mv "$T/m" "$PL/installed_plugins.json"
out="$(run)"
[ "$(ver hcf@hcf project)" = 1.1.1 ] && echo "$out" | grep -q 'crosses a major' \
  && ok "excluded cross-major held" || bad "excluded cross-major held"

# 7. dry-run changes nothing
reset; cp "$PL/installed_plugins.json" "$T/m.bak"; run --dry-run >/dev/null
cmp -s "$PL/installed_plugins.json" "$T/m.bak" && [ ! -d "$PL/cache" ] && ok "dry-run no-op" || bad "dry-run no-op"

# 8. corrupt manifest -> exit 0, untouched
reset; echo 'not json' > "$PL/installed_plugins.json"; run >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && [ "$(cat "$PL/installed_plugins.json")" = "not json" ] && ok "corrupt manifest untouched" || bad "corrupt manifest untouched"

exit $fail
