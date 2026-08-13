#!/bin/bash
# PostToolUse Edit|Write hook — strips invisible/exotic Unicode from files
# Claude just wrote (docs, tickets-as-markdown, code, anything text).
#
# Input: Claude Code sends the tool JSON on stdin. For Edit/Write the file
# path is at `.tool_input.file_path`.
#
# Runs scripts/strip-invisible-unicode.py in place. Non-blocking — cleans
# and reports what it removed, never fails the edit. Silent when nothing to
# strip (the common case).
#
# Scope: zero-width/bidi-control/variation-selector/tag-block characters and
# exotic space normalization. Deterministic, no model calls. This is content
# hygiene (invisible Unicode is independently a security concern — see
# strip-invisible-unicode.py header) — NOT a statistical-watermark remover.
#
# Defensive: NO set -e. Silent no-op if jq/python3 missing or input unparseable.

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

F=$(echo "$INPUT" | jq -r '.tool_input.file_path // .file_path // ""' 2>/dev/null)
[ -z "$F" ] && exit 0

[ -f "$F" ] || exit 0

# Skip binary-ish extensions outright — no point trying to decode as UTF-8.
case "$F" in
  *.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.pdf|*.zip|*.tar|*.gz|*.woff|*.woff2|*.ttf|*.eot) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRIPPER="${SCRIPT_DIR}/scripts/strip-invisible-unicode.py"
[ -f "$STRIPPER" ] || exit 0

OUT=$(python3 "$STRIPPER" "$F" 2>&1)
if [ -n "$OUT" ]; then
  echo "[invisible-unicode-scrub] $OUT" >&2
fi

exit 0
