#!/bin/bash
# PreToolUse Edit|Write hook — Python twin of php-debug-guard.sh. Enforces the
# echo/ad-hoc-debugger ban mechanically:
#
#   No breakpoint() / import pdb / pdb.set_trace() / ipdb / `from pdb import`
#   added to Python source, and no obvious print-debugging lines:
#   print(...) containing DEBUG or XXX, or an f-string self-documenting
#   specifier (print(f"{x=}")). Use debugpy (mcp-debugger MCP) and structlog
#   instead.
#
# Blocks (exit 2): Edit/Write ADDING such a line to a .py file.
# Allows: lines that already existed (Edit: old_string lines are not
#         re-flagged), comment lines, non-.py files, files under tests/,
#         scripts/ or experiments/, conftest.py, and opted-out projects.
#
# Per-project opt-out: add the line `python-debug-guard` to
# <repo>/.claude/rules-disable. Genuine production use: ask the user.
#
# Defensive: NO set -e. Silent no-op if jq missing or input unparseable.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
case "$FILE" in
  *.py) ;;
  *) exit 0 ;;
esac
case "/$FILE" in
  */tests/*|*/scripts/*|*/experiments/*|*/conftest.py) exit 0 ;;
esac

# Per-project opt-out (repo of the edited file; fall back to hook cwd)
# (Write may target a not-yet-existing dir: climb to the nearest existing one)
D=$(dirname "$FILE"); while [ -n "$D" ] && [ "$D" != "/" ] && [ ! -d "$D" ]; do D=$(dirname "$D"); done
TOPLEVEL=$(git -C "$D" rev-parse --show-toplevel 2>/dev/null)
[ -z "$TOPLEVEL" ] && TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$TOPLEVEL" ] && [ -f "$TOPLEVEL/.claude/rules-disable" ]; then
  grep -qx 'python-debug-guard' "$TOPLEVEL/.claude/rules-disable" 2>/dev/null && exit 0
fi

# Only lines being ADDED: Edit new_string minus old_string lines; Write content.
NEW=$(echo "$INPUT" | jq -r '[.tool_input.new_string // .tool_input.content // empty, (.tool_input.edits[]?.new_string // empty)] | join("\n")' 2>/dev/null)
OLD=$(echo "$INPUT" | jq -r '[.tool_input.old_string // empty, (.tool_input.edits[]?.old_string // empty)] | join("\n")' 2>/dev/null)
[ -z "$NEW" ] && exit 0
ADDED=$(awk 'NR==FNR { seen[$0]=1; next } !($0 in seen)' <(printf '%s\n' "$OLD") <(printf '%s\n' "$NEW") \
  | grep -vE '^[[:space:]]*#')
[ -z "$ADDED" ] && exit 0

ALWAYS='(^|[^A-Za-z0-9_.])breakpoint[[:space:]]*\(|^[[:space:]]*import[[:space:]]+(pdb|ipdb|pudb)([[:space:],;]|$)|^[[:space:]]*from[[:space:]]+(pdb|ipdb|pudb)[[:space:]]+import|(^|[^A-Za-z0-9_])(pdb|ipdb|pudb)\.(set_trace|post_mortem|pm)[[:space:]]*\('
PRINT_DBG='(^|[^A-Za-z0-9_.])print[[:space:]]*\((.*(DEBUG|XXX)|[[:space:]]*[rRbB]?[fF][rRbB]?["'"'"'].*\{[^{}]*=(![rsa])?(:[^{}]*)?\})'

MATCH=$(printf '%s\n' "$ADDED" | grep -E "$ALWAYS" | head -1)
[ -z "$MATCH" ] && MATCH=$(printf '%s\n' "$ADDED" | grep -E "$PRINT_DBG" | head -1)
[ -z "$MATCH" ] && exit 0

MATCH=$(printf '%s' "$MATCH" | sed -E 's/^[[:space:]]+//' | cut -c1-120)
{
  echo "BLOCKED by python-debug-guard.sh: adding '$MATCH' to $FILE"
  echo ""
  echo "RULE: no ad-hoc debugger stops or print-debugging in Python source."
  echo "  value at line N, why?        -> debugpy via the mcp-debugger MCP:"
  echo "                                  create_debug_session(language=python),"
  echo "                                  set_breakpoint(file, line), start_debugging"
  echo "  running server (uvicorn)?    -> python -m debugpy --listen 5678 -m uvicorn ...,"
  echo "                                  then attach on 127.0.0.1:5678"
  echo "  need to see it at runtime?   -> structlog: log = structlog.get_logger();"
  echo "                                  log.debug(\"event\", key=value) — stays, filterable"
  echo "  failing test?                -> pytest -x -l --tb=long (locals in traceback),"
  echo "                                  or --pdb in YOUR terminal, never committed"
  echo ""
  echo "Error already happened (cron/worker/uat/live)? Ask Bugsink first — see"
  echo ".claude/bugsink.md. Exempt: tests/, scripts/, experiments/, conftest.py."
  echo "Genuine production use? Ask the user — they can add 'python-debug-guard'"
  echo "to .claude/rules-disable. Reference: rules/reference/python-debugging.md."
} >&2
exit 2
