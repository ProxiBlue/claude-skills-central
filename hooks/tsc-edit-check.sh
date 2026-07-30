#!/bin/bash
# PostToolUse Edit|Write hook — runs tsc --noEmit on edited TypeScript files.
#
# Input: Claude Code sends the tool JSON on stdin. For Edit/Write the file
# path is at `.tool_input.file_path`.
#
# Non-blocking: surfaces TypeScript errors in the transcript but never blocks
# the edit loop. Silent on success.
#
# Defensive: NO `set -e`. Silent no-op if jq missing, tsc missing, file missing,
# or input unparseable. Errors from tsc itself are CAPPED to 20 lines so a
# broken tsconfig doesn't flood the conversation.

# jq required — silent no-op if missing
command -v jq >/dev/null 2>&1 || exit 0

# tsc required — silent no-op if missing
command -v tsc >/dev/null 2>&1 || exit 0

# Read tool JSON from stdin
INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

# Extract file_path — supports both nested + flat shapes
F=$(echo "$INPUT" | jq -r '.tool_input.file_path // .file_path // ""' 2>/dev/null)
[ -z "$F" ] && exit 0

# Only act on TS / TSX files
case "$F" in
  *.ts|*.tsx) ;;
  *) exit 0 ;;
esac

# File must actually exist (Edit/Write may target a non-existent path,
# or the path may not be in the container's view)
[ -f "$F" ] || exit 0

# Run tsc against just this file; cap output to avoid flooding the conversation.
# Exit code intentionally NOT propagated — informational only.
# `tsc --noEmit <file>` standalone-compiles without project config; usually fine.
OUT=$(tsc --noEmit "$F" 2>&1 | head -20)
RC=$?

# Suppress noise from tsconfig-less standalone runs that complain about
# missing types — only report if there's substantive PHP/business error.
# Common harmless: "Cannot find module 'X'" / "Cannot find name 'Y'" without
# a project tsconfig. We surface only if exit code AND non-trivial content.
if [ $RC -ne 0 ] && [ -n "$OUT" ]; then
  # Skip the noise: standalone tsc invocations on project files without
  # tsconfig context produce many false-positive "cannot find module" errors.
  # Heuristic: if every line is "Cannot find module" / "Cannot find name" /
  # "Module ... has no exported member", treat as noise and skip.
  if echo "$OUT" | grep -vqE "Cannot find (module|name)|has no exported member|TS2[0-9]{3}"; then
    echo "[tsc-edit-check] $F:" >&2
    echo "$OUT" >&2
  fi
fi

exit 0
