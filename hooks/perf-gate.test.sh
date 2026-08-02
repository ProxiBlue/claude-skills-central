#!/bin/bash
# Tests for perf-gate.sh — the PreToolUse commit hook. Drives it with synthetic
# hook JSON on a throwaway git repo, using the same stub-mysql trick as
# perf-compare.test.sh so no live DB is needed.
set -u
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/perf-gate.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/proj"; mkdir -p "$REPO/.claude"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t

# stub mysql: emits $PERF_STUB_AFTER for request_ts>0 queries (the check path)
STUB="$TMP/mysql-stub.sh"
cat > "$STUB" <<'STUBEOF'
#!/bin/bash
sql="${!#}"
n=$(printf '%s' "$sql" | grep -oE 'request_ts > [0-9]+' | grep -oE '[0-9]+' | head -1)
[ "${n:-0}" = "0" ] && exit 0
printf '%b' "${PERF_STUB_AFTER:-}"
STUBEOF
chmod +x "$STUB"
export PERF_MYSQL="$STUB"

# baseline: homepage 1000ms
echo '{"/":{"wall_ms":1000,"traces":3,"watermark_ts":1000,"captured_at":1}}' > "$REPO/.claude/perf-baseline.json"

INPUT='{"tool_input":{"command":"git commit -m x"},"cwd":"'"$REPO"'"}'
run_hook() { printf '%s' "$INPUT" | bash "$HOOK" 2>"$TMP/err"; echo $?; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok  - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  BAD - $1"; }

# --- 1: not armed (no perf-gate.json) -> no-op pass --------------------------
export PERF_STUB_AFTER='/\t1400.0\t2\t2000'
rc=$(run_hook)
[ "$rc" = "0" ] && ok "no perf-gate.json -> pass (0)" || bad "unarmed exit $rc"

# --- 2: armed but enabled:false -> no-op ------------------------------------
echo '{"enabled":false}' > "$REPO/.claude/perf-gate.json"
rc=$(run_hook)
[ "$rc" = "0" ] && ok "enabled:false -> pass (0)" || bad "enabled:false exit $rc"

# --- 3: armed enabled:true, +40% regression -> BLOCK (2) --------------------
echo '{"enabled":true}' > "$REPO/.claude/perf-gate.json"
export PERF_STUB_AFTER='/\t1400.0\t2\t2000'
rc=$(run_hook)
[ "$rc" = "2" ] && ok "regression -> block (2)" || bad "regression exit $rc"
grep -q 'BLOCKED by perf-gate' "$TMP/err" && ok "block message present" || bad "no block message"
grep -q 'REGRESSION' "$TMP/err" && ok "shows the regressing line" || bad "no regression line"

# --- 4: armed, small +5% delta -> pass (0) ----------------------------------
export PERF_STUB_AFTER='/\t1050.0\t2\t2000'
rc=$(run_hook)
[ "$rc" = "0" ] && ok "within threshold -> pass (0)" || bad "small delta exit $rc"

# --- 5: armed, no after-data -> FAIL OPEN (0) -------------------------------
export PERF_STUB_AFTER=''
rc=$(run_hook)
[ "$rc" = "0" ] && ok "no after-data -> fail open (0)" || bad "no-data exit $rc"

# --- 6: kill switch overrides a real regression -----------------------------
export PERF_STUB_AFTER='/\t1400.0\t2\t2000'
rc=$(CLAUDE_PERF_GATE_ALLOWED=1 bash -c 'printf "%s" "'"$INPUT"'" | bash "'"$HOOK"'" 2>/dev/null; echo $?')
[ "$rc" = "0" ] && ok "CLAUDE_PERF_GATE_ALLOWED=1 bypasses (0)" || bad "kill switch exit $rc"

# --- 7: warn mode downgrades block to pass ----------------------------------
rc=$(CLAUDE_PERF_GATE_MODE=warn bash -c 'printf "%s" "'"$INPUT"'" | bash "'"$HOOK"'" 2>/dev/null; echo $?')
[ "$rc" = "0" ] && ok "warn mode -> pass (0)" || bad "warn mode exit $rc"

# --- 8: non-commit command ignored ------------------------------------------
rc=$(printf '%s' '{"tool_input":{"command":"git status"},"cwd":"'"$REPO"'"}' | bash "$HOOK" 2>/dev/null; echo $?)
[ "$rc" = "0" ] && ok "non-commit -> pass (0)" || bad "non-commit exit $rc"

echo
echo "perf-gate.test: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
