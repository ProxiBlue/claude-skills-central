#!/bin/bash
# Unit tests for perf-compare.sh — no live DB. A stub `mysql` (wired via
# $PERF_MYSQL) returns canned aggregate rows: it inspects the `request_ts > N`
# clause in the query and emits $PERF_STUB_BEFORE when N==0 (baseline snapshot)
# or $PERF_STUB_AFTER when N>0 (post-watermark check). Rows are the shape
# agg_for() produces: simple_url \t wall_ms \t n \t max_ts.
set -u
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/perf-compare.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- stub mysql --------------------------------------------------------------
STUB="$TMP/mysql-stub.sh"
cat > "$STUB" <<'STUBEOF'
#!/bin/bash
# args: -N -e "<sql>"
sql="${!#}"
n=$(printf '%s' "$sql" | grep -oE 'request_ts > [0-9]+' | grep -oE '[0-9]+' | head -1)
n="${n:-0}"
if [ "$n" = "0" ]; then printf '%b' "${PERF_STUB_BEFORE:-}"; else printf '%b' "${PERF_STUB_AFTER:-}"; fi
STUBEOF
chmod +x "$STUB"

export PERF_MYSQL="$STUB"
export PERF_BASELINE_FILE="$TMP/baseline.json"
# Force git-root resolution to TMP so config lookups don't wander.
cd "$TMP" || exit 1

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok  - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  BAD - $1"; }

# baseline dataset: homepage 1000ms; login 300ms
export PERF_STUB_BEFORE='/\t1000.0\t3\t1000\n/customer/account/login\t300.0\t3\t1000'

# --- test 1: save-baseline writes expected JSON ------------------------------
out=$("$SCRIPT" save-baseline / 2>&1); rc=$?
[ "$rc" = "0" ] && ok "save-baseline exit 0" || bad "save-baseline exit $rc"
w=$(jq -r '."/".wall_ms == 1000' "$PERF_BASELINE_FILE" 2>/dev/null)
[ "$w" = "true" ] && ok "baseline homepage wall=1000" || bad "baseline homepage wall != 1000"
wm=$(jq -r '."/".watermark_ts' "$PERF_BASELINE_FILE" 2>/dev/null)
[ "$wm" = "1000" ] && ok "baseline records watermark_ts=1000" || bad "watermark_ts=$wm"

# --- test 2: after +40% wall -> REGRESSION, exit 1 ---------------------------
export PERF_STUB_AFTER='/\t1400.0\t2\t2000'
out=$("$SCRIPT" check / 2>&1); rc=$?
[ "$rc" = "1" ] && ok "check +40% wall -> exit 1" || bad "check +40% wall -> exit $rc"
echo "$out" | grep -q 'REGRESSION' && ok "reports REGRESSION" || bad "no REGRESSION in: $out"
echo "$out" | grep -q '+40%' && ok "shows +40%" || bad "no +40% in: $out"

# --- test 3: after +5% wall -> ok, exit 0 ------------------------------------
export PERF_STUB_AFTER='/\t1050.0\t2\t2000'
out=$("$SCRIPT" check / 2>&1); rc=$?
[ "$rc" = "0" ] && ok "check +5% wall -> exit 0" || bad "check +5% -> exit $rc ($out)"
echo "$out" | grep -q 'REGRESSION' && bad "false REGRESSION on +5%: $out" || ok "no false REGRESSION on +5%"

# --- test 4: no after-data -> indeterminate, exit 3 --------------------------
export PERF_STUB_AFTER=''
out=$("$SCRIPT" check / 2>&1); rc=$?
[ "$rc" = "3" ] && ok "no after-data -> exit 3 (fail open)" || bad "no after-data -> exit $rc ($out)"

# --- test 5: improvement (faster) -> ok, exit 0 ------------------------------
export PERF_STUB_AFTER='/\t700.0\t2\t2000'   # -30%, a win
out=$("$SCRIPT" check / 2>&1); rc=$?
[ "$rc" = "0" ] && ok "faster after (-30%) -> exit 0" || bad "improvement -> exit $rc ($out)"
echo "$out" | grep -q 'REGRESSION' && bad "improvement flagged as REGRESSION: $out" || ok "improvement not flagged"

# --- test 6: noise floor — small page, big % ignored -------------------------
echo '{"/tiny":{"wall_ms":10,"traces":3,"watermark_ts":1000,"captured_at":1}}' > "$PERF_BASELINE_FILE"
export PERF_STUB_AFTER='/tiny\t30.0\t2\t2000'  # +200% but under 100ms floor
out=$("$SCRIPT" check /tiny 2>&1); rc=$?
[ "$rc" = "0" ] && ok "under noise floor -> ok despite +200%" || bad "floor not applied -> exit $rc ($out)"

echo
echo "perf-compare.test: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
