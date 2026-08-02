#!/bin/bash
# PreToolUse Bash hook — runtime PERF GATE on `git commit`.
#
# AP-1 Phase 4. The perf analogue of test-gate.sh: blocks a commit (exit 2) when
# a URL with a recorded perf baseline has regressed on wall time beyond the
# configured threshold, per xhgui traces captured since the baseline. Uses
# scripts/perf-compare.sh as the deterministic engine (wall time only — the one
# reliable, framework-agnostic signal; see that script's header).
#
# STRICTLY OPT-IN — arms only when BOTH exist in the project:
#   <root>/.claude/perf-gate.json      with {"enabled": true}
#   <root>/.claude/perf-baseline.json  (written by perf-compare.sh save-baseline)
# Absent either → silent pass-through. So the fleet sees zero noise until a
# project deliberately turns it on. There is no auto-detect.
#
# FAIL OPEN by design: if there are no post-baseline traces to compare (you
# didn't re-profile after the change), the gate does NOT block — a perf gate
# that blocks because data is missing is worse than useless. It only ever blocks
# on a MEASURED regression.
#
# Config: <root>/.claude/perf-gate.json
#   { "enabled": true, "wall_pct": 25, "min_wall_ms": 100 }
#
# Bypass (user only, BEFORE starting claude):  export CLAUDE_PERF_GATE_ALLOWED=1
# Warn instead of block:                        export CLAUDE_PERF_GATE_MODE=warn
#
# Defensive: no set -e. jq missing / not a git repo / engine missing / DB
# unreachable → silent no-op. Never blocks on infrastructure failure.

[ "${CLAUDE_PERF_GATE_ALLOWED:-0}" = "1" ] && exit 0
MODE="${CLAUDE_PERF_GATE_MODE:-block}"

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null)
[ -z "$CMD" ] && exit 0

# only git commit (not push — perf data is a working-tree/dev concern)
GIT_RE='(^|[;&|[:space:]])git[[:space:]]+([^;&|]*[[:space:]])?'
printf '%s' "$CMD" | grep -qE "${GIT_RE}commit([[:space:]]|\$)" || exit 0

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
ENGINE="$SCRIPT_DIR/../scripts/perf-compare.sh"
[ -f "$ENGINE" ] || exit 0

# resolve project root (honour a leading `cd` in the command, like test-gate)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD=$(pwd)
FIRST_CD=$(printf '%s' "$CMD" | grep -oE '^[[:space:]]*cd[[:space:]]+[^;&|]+' | head -1 \
  | sed -E 's/^[[:space:]]*cd[[:space:]]+//; s/[[:space:]]+$//')
if [ -n "$FIRST_CD" ]; then
  case "$FIRST_CD" in
    /*) CWD="$FIRST_CD" ;;
    *)  CWD="$CWD/$FIRST_CD" ;;
  esac
fi
ROOT=$(cd "$CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -z "$ROOT" ] && exit 0

# --- arm check (opt-in only) -------------------------------------------------
CFG="$ROOT/.claude/perf-gate.json"
BASELINE="$ROOT/.claude/perf-baseline.json"
[ -f "$CFG" ] || exit 0
[ -f "$BASELINE" ] || exit 0
[ "$(jq -r '.enabled // false' "$CFG" 2>/dev/null)" = "true" ] || exit 0

# --- run the engine ----------------------------------------------------------
OUT=$(cd "$ROOT" && bash "$ENGINE" gate 2>&1)
RC=$?

# 0 = clean, 3 = indeterminate (no after-data / DB unreachable) → pass through
[ "$RC" = "0" ] && exit 0
[ "$RC" = "3" ] && exit 0
# any code other than 1 is an engine/infra hiccup → do not block
[ "$RC" != "1" ] && exit 0

# --- block on a measured regression ------------------------------------------
{
  echo "BLOCKED by perf-gate.sh: git commit — a page with a perf baseline regressed on wall time."
  echo ""
  echo "$OUT"
  echo ""
  echo "What to do:"
  echo "  1. Investigate the flagged URL(s). Profile the hot path:"
  echo "     the xhgui.md playbook Query 3 (parse the profile JSON) names the"
  echo "     top functions + SQL query count behind the slowdown."
  echo "  2. Fix the regression, re-exercise the page (so fresh traces land),"
  echo "     then retry the commit — the gate re-checks post-baseline traces."
  echo "  3. If the delta is legitimate (feature genuinely costs more) update the"
  echo "     baseline: perf-compare.sh save-baseline <url>."
  echo ""
  echo "Cache caveat: baseline and after must be captured under comparable cache"
  echo "state. A cold-cache 'after' vs a warm baseline reads as a false regression."
  echo "Warm the page before re-profiling."
  echo ""
  echo "User-only bypass: export CLAUDE_PERF_GATE_ALLOWED=1 before starting claude,"
  echo "or set {\"enabled\": false} in .claude/perf-gate.json."
} >&2

if [ "$MODE" = "warn" ]; then
  echo "perf-gate: WARN mode — the above would have blocked in block mode." >&2
  exit 0
fi
exit 2
