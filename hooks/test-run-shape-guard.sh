#!/bin/bash
# PreToolUse Bash hook — blocks test-runner command SHAPES whose result the
# test gate can never credit, BEFORE the run burns minutes.
#
# test-evidence.sh (PostToolUse) refuses to record two shapes, but only
# after the run is spent (pps #519, 2026-10-01: three piped runs and one
# wrapper-script full suite wasted before the rules were discovered):
#   1. runner piped into tail/grep/tee WITHOUT pipefail — the pipe's exit
#      status is the last command's, so a failing run would look green.
#   2. runner inside a wrapper script (`bash run-suite.sh`, `./e2e.sh`) — the
#      recorder sees only the wrapper command, not the runner.
# This hook catches both up front and says exactly how to re-shape the call.
#
# Opt out per project: line `test-run-shape-guard` in <root>/.claude/rules-disable
# Skipped when the test gate is off ({"enabled": false} in .claude/test-gate.json).
#
# Defensive: no set -e. jq missing / unparseable input → silent no-op.

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
[ -z "$ROOT" ] && exit 0

if [ -f "$ROOT/.claude/rules-disable" ]; then
  grep -qx 'test-run-shape-guard' "$ROOT/.claude/rules-disable" 2>/dev/null && exit 0
fi
if [ -f "$ROOT/.claude/test-gate.json" ]; then
  EN=$(jq -r '.enabled' "$ROOT/.claude/test-gate.json" 2>/dev/null)
  [ "$EN" = "false" ] && exit 0
fi

block() {
  {
    echo "BLOCKED by test-run-shape-guard.sh: this test run could not be credited as test-gate evidence."
    echo ""
    echo "Why: $1"
    echo ""
    echo "Fix: $2"
    echo ""
    echo "Recordable shape: cd <dir> && set -o pipefail && <runner> ... [| tail -N]"
    echo "  foreground, explicit Bash timeout (max 600000ms), one runner family per call."
    echo "Opt out (user only): line 'test-run-shape-guard' in .claude/rules-disable."
  } >&2
  exit 2
}

# 1. piped runner without pipefail
if [ -n "$(tg_test_families "$CMD")" ] && tg_runner_piped "$CMD" \
   && ! printf '%s' "$CMD" | grep -q 'pipefail'; then
  block "the test runner is piped (| tail / | grep / | tee) without pipefail, so its exit status is lost and test-evidence.sh will discard the run after it finishes." \
        "prefix the command with 'set -o pipefail && ' (or drop the pipe)."
fi

# 2. wrapper script that runs a test runner
RUNNER_RE='(^|[^[:alnum:]_-])(phpunit|paratest|pest|codecept|behat|playwright[[:space:]]+test|yarn[[:space:]]+(run[[:space:]]+)?test|npm[[:space:]]+(run[[:space:]]+)?test|node[[:space:]]+--test)([^[:alnum:]_-]|$)'
WRAPPER=""
while IFS= read -r seg; do
  # shellcheck disable=SC2086
  set -f; set -- $seg; set +f
  while [ $# -gt 0 ]; do
    case "$1" in [A-Za-z_]*=*|timeout|nice|time) shift; [ "${1:-}" != "" ] && case "$1" in [0-9]*) shift ;; esac; continue ;; esac
    break
  done
  f=""
  case "${1:-}" in
    bash|sh|zsh)
      shift
      while [ $# -gt 0 ]; do case "$1" in -c) f=""; break ;; -*) shift ;; *) f="$1"; break ;; esac; done ;;
    ./*.sh|/*.sh|*/*.sh|*.sh) f="$1" ;;
  esac
  [ -z "$f" ] && continue
  case "$f" in /*) p="$f" ;; *) p="$CWD/$f" ;; esac
  [ -f "$p" ] || continue
  if grep -qE "$RUNNER_RE" "$p" 2>/dev/null; then WRAPPER="$f"; break; fi
done <<EOF
$(printf '%s\n' "$CMD" | sed -E 's/(\|\|)|(&&)|;|\|/\n/g')
EOF
if [ -n "$WRAPPER" ]; then
  block "'$WRAPPER' is a wrapper script that invokes a test runner. test-evidence.sh only sees the wrapper command line, so this run records no evidence whether it passes or fails." \
        "run the runner command(s) from the script directly in the Bash tool, one runner family per call. If the suite exceeds 600s, split it by spec file / --grep / directory across calls — do not background it."
fi

exit 0
