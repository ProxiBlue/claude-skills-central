#!/bin/bash
# PreToolUse WebFetch hook — blocks ALL WebFetch calls, no exceptions by
# category. Blanket policy as of 2026-08-11 (widened from advisory/CVE-only).
#
# Why: WebFetch converts page -> markdown -> feeds a small fast model ->
# returns a SUMMARY. On long pages the summary silently drops content
# ("Results may be summarized if the content is very large" per WebFetch's
# own tool description). 2026-08-11: an Amasty security-advisory scan via
# WebFetch missed two critical High-severity RMA lines + a regenerate-url-
# rewrites line — task reported clean when a real critical update was live.
# User then widened the rule: not just security, EVERY fetch (including
# research) must load full page content, never a preview/summary.
# See claude-skills-central memory: feedback_security_advisory_scan_raw_grep.
#
# Blocks (exit 2): every WebFetch call. Redirects to curl (raw content) for
# static pages, or a browser tool's raw text extraction (not its summarizing
# variant) for JS-rendered/authenticated pages — the alternative is always
# available, so this is a tool-swap, not a "stop and ask the user" block.
#
# One structural exception: claude.ai/code/artifact/{uuid} (incl.
# preview.claude.ai) URLs — WebFetch's own docs say these ARE fetchable via
# claude.ai login and curl/headless-browser CANNOT authenticate there. Not a
# completeness loophole: there is no alternative tool for this one case.
#
# Per-project opt-out: add the line `webfetch-completeness-guard` to
# <repo>/.claude/rules-disable.
#
# Defensive: NO set -e. Silent no-op if jq missing or input unparseable.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

URL=$(echo "$INPUT" | jq -r '.tool_input.url // ""' 2>/dev/null)
[ -z "$URL" ] && exit 0

# Structural exception: claude.ai artifact URLs — only WebFetch can auth here.
case "$URL" in
  *claude.ai/code/artifact/*|*preview.claude.ai*) exit 0 ;;
esac

TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$TOPLEVEL" ] && [ -f "$TOPLEVEL/.claude/rules-disable" ]; then
  grep -qx 'webfetch-completeness-guard' "$TOPLEVEL/.claude/rules-disable" 2>/dev/null && exit 0
fi

echo "BLOCKED by webfetch-completeness-guard.sh: WebFetch is blanket-blocked." >&2
echo "" >&2
echo "WebFetch summarizes via a small fast model and can silently drop" >&2
echo "content on long pages (2026-08-11 incident: missed critical High-" >&2
echo "severity lines in an Amasty advisory scan — false 'all clear'; policy" >&2
echo "then widened to ALL fetches, including research — full pages only)." >&2
echo "" >&2
echo "Instead:" >&2
echo "  Static page:  curl -sL '$URL'  — read the FULL output yourself," >&2
echo "                not just a grep match. Grep only to LOCATE, then read" >&2
echo "                surrounding context in full, don't discard the rest." >&2
echo "  JS-rendered / authenticated page: use a browser tool's raw text" >&2
echo "                extraction (e.g. claude-in-chrome get_page_text /" >&2
echo "                chrome-devtools snapshot) — not a search/summarize" >&2
echo "                variant of it." >&2
echo "" >&2
echo "Genuinely need WebFetch (e.g. can't reach the page any other way)?" >&2
echo "Ask the user, or add 'webfetch-completeness-guard' to" >&2
echo ".claude/rules-disable." >&2
echo "Full reference: rules/reference/completeness-critical-fetch.md (claude-skills-central)." >&2
exit 2
