#!/bin/bash
# Test suite for the billing-context-guard hook family (billing-precompact-
# guard.py, billing-clear-end.py, billing-clear-start.py). Run:
#   bash billing-context-guard.test.sh
#
# Full "configured" behavior (real gh/graphiti calls, uninvoiced-ticket
# blocking) requires /etc/billing-bridge/token — a container-only mount this
# test suite deliberately does not fake (touching /etc isn't a test's job).
# What IS host-testable and matters most: the hooks must never crash outside
# a container that has this exact mount layout — the sys.path.insert bug
# fixed 2026-09-02 crashed all three with ModuleNotFoundError before
# billing_bridge_configured() ever got a chance to gate them out.

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0; SKIP=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1"; }

D=$(mktemp -d)
git -C "$D" init -q .

run_py() { # run_py <script> <json>
  OUT=$(printf '%s' "$2" | python3 "$HOOKS_DIR/$1" 2>/tmp/billing-test-err.txt)
  RC=$?
  ERR=$(cat /tmp/billing-test-err.txt)
}

# --- import must not crash on host (the actual bug this suite exists for) ----
run_py "billing-precompact-guard.py" "{\"trigger\":\"manual\",\"cwd\":\"$D\"}"
if [ "$RC" = 0 ] && [ -z "$ERR" ]; then ok; else bad "billing-precompact-guard.py crashed: rc=$RC err=$ERR"; fi

run_py "billing-clear-end.py" "{\"cwd\":\"$D\"}"
if [ "$RC" = 0 ] && [ -z "$ERR" ]; then ok; else bad "billing-clear-end.py crashed: rc=$RC err=$ERR"; fi

run_py "billing-clear-start.py" "{\"cwd\":\"$D\"}"
if [ "$RC" = 0 ] && [ -z "$ERR" ]; then ok; else bad "billing-clear-start.py crashed: rc=$RC err=$ERR"; fi

# --- silent no-op when unconfigured (no /etc/billing-bridge/token here) ------
if [ ! -f /etc/billing-bridge/token ]; then
  [ -z "$OUT" ] && ok || bad "expected silent no-op unconfigured, got: $OUT"
else
  skip "this host has /etc/billing-bridge/token configured — no-op path not exercised"
fi

# --- malformed stdin JSON does not crash --------------------------------------
run_py "billing-precompact-guard.py" "not json"
[ "$RC" = 0 ] && ok || bad "expected exit 0 on malformed JSON, got rc=$RC err=$ERR"

# --- clear-end / clear-start state-file round trip (bypasses the token gate:
#     write the state file directly, exactly as clear-end would if configured,
#     then verify clear-start reads + one-shot-deletes it) --------------------
STATE_DIR="$HOME/.claude/billing-context-guard"
mkdir -p "$STATE_DIR"
KEY=$(python3 -c "import re,sys; print(re.sub(r'[^A-Za-z0-9_-]', '_', sys.argv[1].strip('/')))" "$D")
STATE_FILE="$STATE_DIR/$KEY.json"
python3 -c "
import json
json.dump({'repo': 'acme/widget', 'tickets': [{'number': 42, 'title': 'Fix thing'}]}, open('$STATE_FILE', 'w'))
"
run_py "billing-clear-start.py" "{\"cwd\":\"$D\"}"
if echo "$OUT" | grep -q "#42" && [ ! -f "$STATE_FILE" ]; then
  ok
else
  bad "expected ticket #42 surfaced + state file one-shot-deleted, out=[$OUT] state_exists=$([ -f "$STATE_FILE" ] && echo yes || echo no)"
fi

# second run (nothing new) must be silent
run_py "billing-clear-start.py" "{\"cwd\":\"$D\"}"
[ -z "$OUT" ] && ok || bad "expected silent on 2nd clear-start (state already consumed), got: $OUT"

rm -f /tmp/billing-test-err.txt
rm -rf "$D"

echo "billing-context-guard tests: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = 0 ]
