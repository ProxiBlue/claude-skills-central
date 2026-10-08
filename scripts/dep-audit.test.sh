#!/bin/bash
# Test suite for dep-audit.sh manifest branching — sandboxed HOME, stub
# pip-audit, dead chatroom URL. Run: bash dep-audit.test.sh
SCRIPT="$(cd "$(dirname "$0")" && pwd)/dep-audit.sh"
PASS=0; FAIL=0
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
command -v composer >/dev/null 2>&1 || { echo "SKIP: composer missing (script precondition)"; exit 0; }

H=$(mktemp -d); trap 'rm -rf "$H"' EXIT
mkdir -p "$H/claude-skills-central/host" "$H/workspace/pyproj/.ddev" "$H/workspace/nomanifest/.ddev" "$H/bin"
printf 'name: pyproj\n' > "$H/workspace/pyproj/.ddev/config.yaml"
printf 'name: nomanifest\n' > "$H/workspace/nomanifest/.ddev/config.yaml"
printf '[project]\nname="x"\n' > "$H/workspace/pyproj/pyproject.toml"
printf 'requests==2.0\n' > "$H/workspace/pyproj/requirements.txt"
printf '# scope\npyproj\tpython\nnomanifest\n' > "$H/claude-skills-central/host/tooling-scope.txt"

run() { OUT=$(HOME="$H" PATH="$H/bin:$PATH" PB_CHATROOM_REST_URL=http://127.0.0.1:9 bash "$SCRIPT" 2>&1); }
t() { if printf '%s' "$OUT" | grep -qF -- "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL ($1): missing '$2' in: $OUT"; fi; }

# pip-audit stub on PATH: one vuln, exit 1 like the real tool
cat > "$H/bin/pip-audit" <<'STUB'
#!/bin/bash
echo "$*" > "$HOME/pa-args"
echo '{"dependencies":[{"name":"requests","version":"2.0","vulns":[{"id":"PYSEC-2023-74","fix_versions":["2.31.0"],"aliases":["CVE-2023-32681"]}]},{"name":"idna","version":"3.7","vulns":[]}]}'
exit 1
STUB
chmod +x "$H/bin/pip-audit"
run
t "python vuln alerted"       "[pyproj] 1 advisories — ALERTED"
t "no-manifest skipped"       "[nomanifest] no composer.lock / Python manifest — skipped"
grep -q -- '-r requirements.txt' "$H/pa-args" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (requirements.txt passed to pip-audit): $(cat "$H/pa-args")"; }
run
t "unchanged second run"      "[pyproj] unchanged (1 advisories)"

# .venv/bin/pip-audit preferred over PATH (no uv.lock)
mkdir -p "$H/workspace/pyproj/.venv/bin"
printf '#!/bin/bash\necho venv > "$HOME/pa-which"\necho %s\n' "'{\"dependencies\":[]}'" > "$H/workspace/pyproj/.venv/bin/pip-audit"
chmod +x "$H/workspace/pyproj/.venv/bin/pip-audit"
run
t "venv pip-audit, cleared"   "[pyproj] advisories cleared (now 0)"
grep -q venv "$H/pa-which" 2>/dev/null && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (.venv pip-audit not used)"; }

# pip-audit absent everywhere -> graceful skip (PATH without stub/pipx)
rm -f "$H/bin/pip-audit" "$H/workspace/pyproj/.venv/bin/pip-audit"
if ! command -v pip-audit >/dev/null 2>&1 && ! command -v pipx >/dev/null 2>&1; then
  run
  t "absent pip-audit skipped" "pip-audit unavailable"
fi

echo "dep-audit tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
