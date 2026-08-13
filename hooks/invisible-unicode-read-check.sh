#!/bin/bash
# PostToolUse Read hook — warns (does not modify) when a file Claude just
# read contains invisible/exotic Unicode (zero-width, bidi-control,
# variation-selector, tag-block chars — see strip-invisible-unicode.py).
#
# Unlike invisible-unicode-scrub.sh (which cleans files Claude writes),
# this never mutates files Claude didn't create — vendor code, cloned
# repos, downloaded docs. Warn-only: surfaces possible hidden-text /
# prompt-injection carriers in third-party content without silently
# rewriting it.
#
# Defensive: NO set -e. Silent no-op if jq/python3 missing or input unparseable.

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

F=$(echo "$INPUT" | jq -r '.tool_input.file_path // .file_path // ""' 2>/dev/null)
[ -z "$F" ] && exit 0

[ -f "$F" ] || exit 0

case "$F" in
  *.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.pdf|*.zip|*.tar|*.gz|*.woff|*.woff2|*.ttf|*.eot) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRIPPER="${SCRIPT_DIR}/scripts/strip-invisible-unicode.py"
[ -f "$STRIPPER" ] || exit 0

OUT=$(python3 "$STRIPPER" --check "$F" 2>&1)
if [ -n "$OUT" ]; then
  echo "[invisible-unicode-check] WARNING: $OUT — possible hidden-text/prompt-injection carrier, file not modified (Claude did not write it)" >&2
fi

exit 0
