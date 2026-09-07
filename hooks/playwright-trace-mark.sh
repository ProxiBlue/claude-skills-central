#!/bin/bash
# PostToolUse Bash hook — marks that the agent actually opened a Playwright
# trace.zip this session (companion to playwright-trace-guard.sh).
#
# Fires when a Bash command references trace.zip in a read/extract/inspect
# way (unzip, cat, strings, grep, tar, `playwright show-trace`, python
# zipfile, etc). Does NOT fire on a plain test run that merely PRODUCES a
# fresh trace.zip — only on commands that look at one.
#
# Writes a per-session marker file (keyed by session_id — see 2026-09-07 fix
# below) that playwright-trace-guard.sh checks before allowing edits to
# spec/page/config files.
#
# 2026-09-07 (pb-chatroom thread fa4f2504, pvcpipesupplies): was keyed by
# $PPID (same convention as test-failure-context.sh's debounce stamp), but
# this hook (PostToolUse) and the guard (PreToolUse) get DIFFERENT $PPID
# values per invocation in this harness — the marker guard.sh looked for
# could never match the one this hook wrote, so the documented "won't fire
# again this session" unlock never actually worked. session_id is stable
# across every hook invocation within one session; keying on it instead
# fixes that structurally rather than patching around one symptom.
#
# Defensive: NO set -e. Silent no-op on any parse failure. Never blocks
# (PostToolUse, exit 0 always).

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -z "$CMD" ] && exit 0

echo "$CMD" | grep -qE 'trace\.zip|playwright[[:space:]]+show-trace' || exit 0

# Must look like an inspection, not just a path mention with no verb
echo "$CMD" | grep -qE '(unzip|tar|cat|strings|grep|less|more|zipfile|show-trace)' || exit 0

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
touch "/tmp/claude-pw-trace-seen-${SESSION_ID:-$PPID}" 2>/dev/null

exit 0
