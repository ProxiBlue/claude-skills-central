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

# --- GitHub ticket channel (2026-11-01) -------------------------------------
# gh stub: logs every invocation; `issue list` answers from $H/gh-list;
# `issue create` prints a fake URL; edit/close/comment succeed silently.
cat > "$H/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$HOME/gh-args"
case "$1 $2" in
  "auth status") exit 0 ;;
  "issue list") cat "$HOME/gh-list" 2>/dev/null || echo '[]' ;;
  "issue create") echo "https://github.com/Acme/pyproj/issues/7" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$H/bin/gh"
vuln_stub() {  # <n-vulns> -> rewrite .venv pip-audit stub
  if [ "$1" = 0 ]; then V='[]'; else V='[{"id":"PYSEC-2023-74","fix_versions":["2.31.0"],"aliases":[]}]'; fi
  if [ "$1" = 2 ]; then V='[{"id":"PYSEC-2023-74","fix_versions":[],"aliases":[]},{"id":"PYSEC-2024-1","fix_versions":[],"aliases":[]}]'; fi
  printf '#!/bin/bash\necho %s\n' "'{\"dependencies\":[{\"name\":\"requests\",\"version\":\"2.0\",\"vulns\":$V}]}'" > "$H/workspace/pyproj/.venv/bin/pip-audit"
  chmod +x "$H/workspace/pyproj/.venv/bin/pip-audit"
}
# no git remote -> chatroom fallback even with gh present
vuln_stub 1; : > "$H/gh-args"
run
t "no-remote stays chatroom"  "[pyproj] 1 advisories — ALERTED"
grep -q "issue create" "$H/gh-args" 2>/dev/null && { FAIL=$((FAIL+1)); echo "FAIL (issue created without github remote)"; } || PASS=$((PASS+1))
# github remote + no existing issue -> create
( cd "$H/workspace/pyproj" && git init -q && git remote add origin git@github.com:Acme/pyproj.git )
vuln_stub 2; : > "$H/gh-args"
run
t "ticket created"            "[pyproj] 2 advisories — TICKET https://github.com/Acme/pyproj/issues/7"
grep -q "^issue create -R Acme/pyproj --title Dependency advisories: pyproj (2)" "$H/gh-args" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (create args): $(cat "$H/gh-args")"; }
# existing open issue + changed set -> edit in place, no second create
echo '[{"number":7,"title":"Dependency advisories: pyproj (2)"}]' > "$H/gh-list"
vuln_stub 1; : > "$H/gh-args"
run
t "ticket updated"            "[pyproj] 1 advisories — TICKET https://github.com/Acme/pyproj/issues/7"
grep -q "^issue edit 7 -R Acme/pyproj --title Dependency advisories: pyproj (1)" "$H/gh-args" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (edit args): $(cat "$H/gh-args")"; }
grep -q "^issue create" "$H/gh-args" && { FAIL=$((FAIL+1)); echo "FAIL (duplicate create)"; } || PASS=$((PASS+1))
# cleared -> close the open issue
vuln_stub 0; : > "$H/gh-args"
run
t "ticket closed on clean"    "[pyproj] advisories cleared (now 0) — CLOSED https://github.com/Acme/pyproj/issues/7"
grep -q "^issue close 7 -R Acme/pyproj" "$H/gh-args" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (close args): $(cat "$H/gh-args")"; }
# DEP_AUDIT_TICKETS=0 -> chatroom even with remote + gh
rm -f "$H/gh-list"; vuln_stub 1; : > "$H/gh-args"
OUT=$(HOME="$H" PATH="$H/bin:$PATH" PB_CHATROOM_REST_URL=http://127.0.0.1:9 DEP_AUDIT_TICKETS=0 bash "$SCRIPT" 2>&1)
t "tickets opt-out"           "[pyproj] 1 advisories — ALERTED"
git -C "$H/workspace/pyproj" remote remove origin

# pip-audit absent everywhere -> graceful skip (PATH without stub/pipx)
rm -f "$H/bin/pip-audit" "$H/workspace/pyproj/.venv/bin/pip-audit"
if ! command -v pip-audit >/dev/null 2>&1 && ! command -v pipx >/dev/null 2>&1; then
  run
  t "absent pip-audit skipped" "pip-audit unavailable"
fi

echo "dep-audit tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
