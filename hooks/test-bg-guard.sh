#!/bin/bash
# PreToolUse Bash hook — stops an e2e test run from SILENTLY auto-backgrounding,
# which produces a run that passes but can never be credited by the test gate.
#
# The problem (chatroom thread c91f5a24, pvcpipesupplies #501):
# test-evidence.sh records evidence on PostToolUse. When a Bash command exceeds
# the tool's default 120s timeout the harness moves it to the background and
# returns a task id immediately; completion arrives later as a task
# notification. The suite passes, the operator sees 12/12 green — and the next
# `git commit` is still blocked with "MISSING: e2e", because no PostToolUse
# event ever carried a finished run. The cure people reach for is re-running
# the identical suite in the foreground: on that report, ~2.3 min and a full
# second set of tokens for exactly zero new signal.
#
# Why not credit the background run instead? Because nothing on disk supports
# it. A finished task leaves only <session>/tasks/<id>.output — no command, no
# exit code, no cwd. Crediting it would mean grepping suite output for "N
# passed", i.e. trusting a string the run itself prints. The gate's whole value
# is that evidence is machine-checked and state-hashed, so a forgeable heuristic
# is worse than no credit at all.
#
# So this hook removes the trap at the point where the decision is made: an e2e
# invocation must state a timeout big enough to finish in the foreground. The
# model is told the number, and the run it then makes is recordable.
#
# Fires ONLY on the e2e family (playwright/codeception/behat, npm-style *e2e*
# scripts — see tg_test_families). Unit runs are untouched: they finish well
# inside the default and never hit this.
#
# Per-project config, <root>/.claude/test-gate.json:
#   {"e2e_min_timeout_ms": 300000}   // default 300000 (5 min)
# Opt out per project: add a line `test-bg-guard` to <root>/.claude/rules-disable
# Skipped entirely when the test gate itself is off ({"enabled": false}) — with
# no gate there is no evidence to miss.
#
# Defensive: no set -e. jq missing / unparseable input / not a git repo →
# silent no-op. Never blocks on infrastructure failure.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

TOOL=$(echo "$INPUT" | jq -r '.tool_name // "Bash"' 2>/dev/null)
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null)
[ -z "$CMD" ] && exit 0

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
[ -f "$SCRIPT_DIR/test-gate-lib.sh" ] || exit 0
# shellcheck source=test-gate-lib.sh
. "$SCRIPT_DIR/test-gate-lib.sh"

# Only the long family. Anything else (unit, or not a test command at all) is
# none of this hook's business.
FAMS=$(tg_test_families "$CMD")
case "
$FAMS
" in *"
e2e
"*) : ;; *) exit 0 ;; esac

# --- project resolution (config + opt-out live in the repo) -------------------
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD=$(pwd)
FIRST_CD=$(printf '%s' "$CMD" | grep -oE '^[[:space:]]*cd[[:space:]]+[^;&|]+' | head -1 \
  | sed -E 's/^[[:space:]]*cd[[:space:]]+//; s/[[:space:]]+$//')
if [ -n "$FIRST_CD" ]; then
  case "$FIRST_CD" in
    "~")   FIRST_CD="$HOME" ;;
    "~/"*) FIRST_CD="$HOME/${FIRST_CD#\~/}" ;;
  esac
  case "$FIRST_CD" in
    /*) CWD="$FIRST_CD" ;;
    *)  CWD="$CWD/$FIRST_CD" ;;
  esac
fi
ROOT=$(tg_project_root "$CWD")

if [ -n "$ROOT" ]; then
  if [ -f "$ROOT/.claude/rules-disable" ]; then
    grep -qx 'test-bg-guard' "$ROOT/.claude/rules-disable" 2>/dev/null && exit 0
  fi
  CFG="$ROOT/.claude/test-gate.json"
  if [ -f "$CFG" ]; then
    EN=$(jq -r '.enabled' "$CFG" 2>/dev/null)
    [ "$EN" = "false" ] && exit 0
  fi
fi

MIN_MS=300000
if [ -n "$ROOT" ] && [ -f "$ROOT/.claude/test-gate.json" ]; then
  M=$(jq -r '.e2e_min_timeout_ms // empty' "$ROOT/.claude/test-gate.json" 2>/dev/null)
  case "$M" in ''|*[!0-9]*) : ;; *) MIN_MS="$M" ;; esac
fi
MIN_S=$((MIN_MS / 1000))

BG=$(echo "$INPUT" | jq -r '.tool_input.run_in_background // false' 2>/dev/null)
TIMEOUT=$(echo "$INPUT" | jq -r '.tool_input.timeout // empty' 2>/dev/null)
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT="" ;; esac

REASON=""
if [ "$BG" = "true" ]; then
  REASON="run_in_background:true — a background run produces no PostToolUse event, so test-evidence.sh records nothing and the gate cannot credit it."
elif [ -z "$TIMEOUT" ]; then
  REASON="no explicit timeout — the tool default is 120000ms (120s), and an e2e suite routinely exceeds it. The harness would move this run to the background, and a backgrounded run records no evidence."
elif [ "$TIMEOUT" -lt "$MIN_MS" ]; then
  REASON="timeout=${TIMEOUT}ms is below this project's e2e floor of ${MIN_MS}ms. A run that hits its timeout is backgrounded or killed, and records no evidence."
fi

[ -z "$REASON" ] && exit 0

{
  echo "BLOCKED by test-bg-guard.sh: e2e run would not be creditable as test evidence."
  echo ""
  echo "Why: $REASON"
  echo ""
  echo "What to do: re-run the SAME command with an explicit timeout of at least"
  echo "  ${MIN_MS}ms (${MIN_S}s) in the Bash tool's timeout parameter, in the foreground."
  echo "  Do not set run_in_background."
  echo ""
  echo "This is not a test failure and not a gate you need to argue with — it is the"
  echo "difference between a run the gate can credit and one it cannot. Running the"
  echo "suite twice (once backgrounded, once foreground) is the exact waste this"
  echo "prevents, so pick the timeout now."
  echo ""
  echo "Per-project floor: {\"e2e_min_timeout_ms\": N} in .claude/test-gate.json."
} >&2
exit 2
