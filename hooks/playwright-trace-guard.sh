#!/bin/bash
# PreToolUse Edit|Write hook — blocks editing a Playwright spec/page/config
# file while a recent trace.zip sits unopened.
#
# Born from the 2026-08-08 LaptopLCDScreen incident (Mage-OS 3.3.0 upgrade,
# branch GITHUB_392, chatroom thread 05d6da8c): agent looped 3 rounds of
# speculative fixes (session-drop guards, networkidle swaps, timeout tweaks)
# off a misleading post-afterEach snapshot, never opened trace.zip, which had
# the actual failing locator in plain text ("locator resolved to <tr
# class=\"data-grid-bulk-edit-panel...\">"). Only opened it after the user
# pushed back with "you fixed the timeout, not the root cause".
#
# investigation.md already bans this pattern in prose ("read ALL failure
# artefacts, not a sample"). It didn't stop the loop because nothing forced
# the trace open before the edit, and the one deterministic backstop
# (test-failure-context.sh) only fires on exit-0 Bash commands — a real
# non-zero-exit Playwright timeout, like this one, never triggers it.
# Prevention = deterministic hook, never prose alone (same pattern as
# git-tree-guard.sh / push-guard.sh / php-debug-guard.sh).
#
# Rule:
#   IF a trace.zip under test-results/** exists, is < 3 hours old, and was
#   produced AFTER the last commit (i.e. from a failure this session, not a
#   stale historical artefact)
#   AND no playwright-trace-mark.sh marker newer than that trace.zip exists
#   (meaning the agent has not run unzip/cat/strings/grep/show-trace against
#   it this session)
#   THEN block edits to *.spec.ts, *.spec.js, *page.ts, *page.js,
#   playwright.config.ts, playwright.config.js.
#
# Per-project opt-out: add `playwright-trace-guard` to
# <repo>/.claude/rules-disable.
#
# Defensive: NO set -e. Silent no-op if jq/find missing or input unparseable
# — never blocks on infrastructure failure.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
case "$FILE" in
  *.spec.ts|*.spec.js|*page.ts|*page.js|*playwright.config.ts|*playwright.config.js) ;;
  *) exit 0 ;;
esac
case "$FILE" in
  */node_modules/*) exit 0 ;;
esac

TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
[ -z "$TOPLEVEL" ] && exit 0

# Per-project opt-out
if [ -f "$TOPLEVEL/.claude/rules-disable" ]; then
  grep -qx 'playwright-trace-guard' "$TOPLEVEL/.claude/rules-disable" 2>/dev/null && exit 0
fi

command -v find >/dev/null 2>&1 || exit 0

TRACE=$(find "$TOPLEVEL" -path '*/node_modules/*' -prune -o \
  -name 'trace.zip' -newermt '-3 hours' -print 2>/dev/null | head -1)
[ -z "$TRACE" ] && exit 0

MARKER="/tmp/claude-pw-trace-seen-$PPID"
if [ -f "$MARKER" ] && [ "$MARKER" -nt "$TRACE" ]; then
  exit 0
fi

echo "BLOCKED by playwright-trace-guard.sh: editing $FILE with an unopened trace" >&2
echo "" >&2
echo "A Playwright trace exists from this session ($TRACE) and hasn't been" >&2
echo "inspected yet. Open it and cite the actual failure line BEFORE editing" >&2
echo "the test — this is the exact loop that burned 3 rounds of speculative" >&2
echo "fixes in the 2026-08-08 LaptopLCDScreen incident (see chatroom thread" >&2
echo "05d6da8c: root cause — Mage-OS 3.3.0 admin grids inject a hidden" >&2
echo "data-grid-bulk-edit-panel row that bare 'tbody >> tr >> .first()'" >&2
echo "selectors resolve to — sitting in plain text in the trace the whole" >&2
echo "time)." >&2
echo "" >&2
echo "  mkdir -p /tmp/pw-trace && unzip -o '$TRACE' -d /tmp/pw-trace" >&2
echo "  grep -r 'locator resolved to' /tmp/pw-trace" >&2
echo "" >&2
echo "Do NOT patch the test/config on a guessed cause. Once the trace is" >&2
echo "read, this guard will not fire again this session." >&2
echo "" >&2
echo "Genuinely don't need the trace (e.g. pure refactor, not a failure fix)?" >&2
echo "Ask the user — they can add 'playwright-trace-guard' to" >&2
echo ".claude/rules-disable. Full protocol: rules/reference/investigation.md" >&2
echo "and rules/reference/playwright-debugging.md (claude-skills-central)." >&2
exit 2
