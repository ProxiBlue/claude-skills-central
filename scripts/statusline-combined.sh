#!/usr/bin/env bash
# Combined statusline: ccusage (line 1) + extra info (line 2+).
# Resolves sibling extra script via SCRIPT_DIR so it works on host or in ddev.

input=$(cat)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf '%s' "$input" | npx ccusage statusline 2>/dev/null
printf '%s' "$input" | bash "$SCRIPT_DIR/statusline-extra.sh"
# Mirror a compact one-liner into GNU screen's bottom status bar (%h). Writes to
# /dev/tty, not stdout; no-op unless TERM=screen*. See statusline-screen.sh.
printf '%s' "$input" | bash "$SCRIPT_DIR/statusline-screen.sh"
