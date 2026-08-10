#!/bin/bash
# PreToolUse WebFetch hook — blocks WebFetch on completeness-critical lookups
# (security advisories, CVEs, vuln scans, module/version cross-checks).
#
# Why: WebFetch converts page -> markdown -> feeds a small fast model ->
# returns a SUMMARY. On long pages the summary silently drops content
# ("Results may be summarized if the content is very large" per WebFetch's
# own tool description). 2026-08-11: an Amasty security-advisory scan via
# WebFetch missed two critical High-severity RMA lines + a regenerate-url-
# rewrites line — task reported clean when a real critical update was live.
# See claude-skills-central memory: feedback_security_advisory_scan_raw_grep.
#
# Blocks (exit 2): WebFetch where url or prompt matches advisory/CVE/vuln
# keywords. Redirects to curl + grep (raw content, full deterministic match)
# instead of a hard stop — the alternative tool is always available, so this
# is a tool-swap, not a "stop and ask the user" block.
#
# Per-project opt-out: add the line `webfetch-completeness-guard` to
# <repo>/.claude/rules-disable.
#
# Defensive: NO set -e. Silent no-op if jq missing or input unparseable.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

URL=$(echo "$INPUT" | jq -r '.tool_input.url // ""' 2>/dev/null)
PROMPT=$(echo "$INPUT" | jq -r '.tool_input.prompt // ""' 2>/dev/null)
[ -z "$URL" ] && [ -z "$PROMPT" ] && exit 0

TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$TOPLEVEL" ] && [ -f "$TOPLEVEL/.claude/rules-disable" ]; then
  grep -qx 'webfetch-completeness-guard' "$TOPLEVEL/.claude/rules-disable" 2>/dev/null && exit 0
fi

HAYSTACK="$URL $PROMPT"

if echo "$HAYSTACK" | grep -qEi 'CVE-[0-9]|security[[:space:]]+advisory|advisor(y|ies)|vulnerab|exploit|\bRCE\b|SQL[[:space:]]*injection|\bXSS\b|security[[:space:]]+(update|patch|bulletin|fix)|patch[[:space:]]+level|affected[[:space:]]+(version|module)|high[[:space:]]+severity|critical[[:space:]]+severity|zero-day'; then
  echo "BLOCKED by webfetch-completeness-guard.sh: security/advisory-shaped WebFetch call." >&2
  echo "" >&2
  echo "WebFetch summarizes via a small fast model and can silently drop" >&2
  echo "content on long pages (2026-08-11 incident: missed critical High-" >&2
  echo "severity lines in an Amasty advisory scan — false 'all clear')." >&2
  echo "" >&2
  echo "Instead: curl the raw page and grep deterministically, e.g.:" >&2
  echo "  curl -sL '$URL' | grep -iE '<keyword|package-name>'" >&2
  echo "Read the full matched output yourself — do not re-summarize it." >&2
  echo "" >&2
  echo "Genuinely not security/advisory-shaped (false positive)? Ask the" >&2
  echo "user, or add 'webfetch-completeness-guard' to .claude/rules-disable." >&2
  echo "Full reference: rules/reference/completeness-critical-fetch.md (claude-skills-central)." >&2
  exit 2
fi

exit 0
