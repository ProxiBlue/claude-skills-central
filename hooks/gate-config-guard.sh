#!/bin/bash
# PreToolUse Edit|Write|Bash hook — protects the gate KILL-SWITCHES themselves.
#
# test-gate.sh, perf-gate.sh, and the rules-disable opt-out mechanism used by
# git-tree-guard/php-debug-guard/magento-*-guard/webfetch-completeness-guard/
# gh-comment-guard/playwright-trace-guard/hook-needs-eval-check all read a
# small on-disk file to decide whether to arm. If Claude can write that file,
# it can turn any of those gates off itself — the gate becomes decorative.
# This hook is the one thing standing between "hooks enforce invariants" and
# "hooks enforce invariants unless the AI would rather they didn't".
#
# Protected paths (anywhere in the tree, not just repo root — nested .claude/
# dirs in monorepos count too):
#   .claude/test-gate.json           - test-gate.sh enable/mode/relevance switch
#   .claude/perf-gate.json           - perf-gate.sh enable switch
#   .claude/rules-disable            - per-hook opt-out list (see header above)
#   */claude-test-gate/evidence.jsonl - test-gate's append-only proof log
#     (lives under the git dir, e.g. .git/claude-test-gate/evidence.jsonl;
#     test-gate.sh's own state-hash check already treats any edit to this
#     file as invalidating, but Bash can still stomp it directly)
#
# Blocks (exit 2), Edit/Write: any edit/create/overwrite of a protected path.
# Blocks (exit 2), Bash: any command that TARGETS a protected path with a
#   write-shaped token (redirection, tee, sed -i, cp/mv/install, dd, rm,
#   truncate, git checkout/restore/apply/reset, or a scripting interpreter
#   one-liner) — the protected path must appear after the write verb within
#   the same ; / && / || / | clause. Reads (cat, grep, jq without -i, git
#   diff/log/show), a bare MENTION of the path (e.g. a shell variable
#   assignment: EF=.../evidence.jsonl; tail "$EF"), and an unrelated write
#   elsewhere on the same command line (git diff .claude/test-gate.json >
#   /tmp/out.txt — the `>` targets /tmp, not the protected file) all pass.
#
# Scope: CONTAINER SESSIONS ONLY (Lucas, 2026-09-18).
# The host session is where the guard layer itself is authored and
# maintained — hooks, rules, settings wiring. Blocking it there blocks the
# maintainer, not an unsupervised agent. It also used to fire on a false
# positive that made guard work impossible: the Bash branch greps the WHOLE
# command string, so a heredoc whose BODY merely mentions .claude/rules-disable
# (which every new guard hook does, documenting its own opt-out) was blocked
# even though it writes nothing protected. Demonstrated 2026-09-18: a test
# script for this very hook was blocked for containing the string. The
# same-clause TARGET requirement above (added 2026-10-01) fixes this for
# both host and container — but host still exits early regardless, since
# the maintainer session should never be a subject of this hook at all.
#
# Deliberately NO bypass of any kind INSIDE A CONTAINER:
#   - no rules-disable opt-out (this hook guards rules-disable itself —
#     letting it check rules-disable would be checking the lock with its
#     own key)
#   - no CLAUDE_*_ALLOWED env var
# If a gate genuinely needs to change (enable/disable/relax) from inside a
# container, tell the user directly and have them make the edit, or run the
# specific command themselves. Do not try a different tool/subagent/heredoc/
# interpreter to write the file instead — that's exactly the class of
# workaround this hook exists to stop.
#
# Known gap this scoping opens: a subagent spawned BY a host session also
# runs on the host and is therefore also exempt. Accepted — host sessions
# are interactive and supervised.
#
# Known gaps (same class of gap other fleet guards document openly): a
# write via an interpreter one-liner that neither names an obvious write
# call nor the literal filename in a way grep catches, or indirection
# through a script file that itself contains the write, can still slip
# through. This hook raises the bar; it is not a sandbox.
#
# Defensive: NO set -e. Silent no-op if jq missing or input unparseable —
# never blocks on infrastructure.

command -v jq >/dev/null 2>&1 || exit 0

# Host session = not inside a DDEV container. The maintainer of the guard
# layer, so not a subject of it. See scope note in the header.
if [ -z "${DDEV_PROJECT:-}" ] && [ ! -f /.dockerenv ]; then
  exit 0
fi

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)

PROTECTED_PATH='(^|/)\.claude/(test-gate\.json|perf-gate\.json|rules-disable)$|(^|/)claude-test-gate/evidence\.jsonl$'
# Same paths, but as a substring inside an arbitrary shell command line: the
# boundary can't require "^|/" immediately before ".claude" (a space, quote,
# or pipe usually sits there instead) or "$" immediately after (quotes,
# commas, more of the command usually follow). Use non-identifier-char
# boundaries instead, and explicitly exclude "." after the extension so
# "test-gate.json.bak" / "evidence.jsonl.old" don't false-match.
PROTECTED_CMD='(^|[^A-Za-z0-9_])\.claude/(test-gate\.json|perf-gate\.json|rules-disable)([^A-Za-z0-9_.]|$)'
PROTECTED_CMD="$PROTECTED_CMD"'|(^|[^A-Za-z0-9_])claude-test-gate/evidence\.jsonl([^A-Za-z0-9_.]|$)'

block() {
  echo "BLOCKED by gate-config-guard.sh: $1" >&2
  echo "" >&2
  echo "STOP. This file is a gate kill-switch, not project content. Do NOT:" >&2
  echo "  - retry with a different tool (Bash instead of Edit, or vice versa)" >&2
  echo "  - wrap it in bash -c, eval, env, a heredoc, or a scripting one-liner" >&2
  echo "  - invoke a skill or sub-agent to make the edit for you" >&2
  echo "  - read or modify this hook to find a way around it" >&2
  echo "" >&2
  echo "There is no bypass from inside a container. If a gate genuinely" >&2
  echo "needs to change, tell the user exactly what needs to change and" >&2
  echo "why, and have them make the edit from the host session or run the" >&2
  echo "command themselves." >&2
  exit 2
}

case "$TOOL" in
  Edit|Write|MultiEdit|NotebookEdit)
    FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
    [ -z "$FILE" ] && exit 0
    echo "$FILE" | grep -qE "$PROTECTED_PATH" && block "$TOOL on gate config: $FILE"
    ;;
  Bash)
    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null)
    [ -z "$CMD" ] && exit 0
    echo "$CMD" | grep -qE "$PROTECTED_CMD" || exit 0
    # A mere MENTION of a protected path isn't a write — a plain read (cat,
    # grep, jq without -i, git diff/log/show), or a shell variable merely
    # holding the path (EF=.git/claude-test-gate/evidence.jsonl; tail "$EF"),
    # must pass. Each write-shaped alternative below therefore requires the
    # protected path to appear AFTER the write verb, within the same clause
    # (the [^|;&]* in TARGET never crosses ; | &). Without that requirement
    # the old flat regex matched on mere co-occurrence anywhere on the
    # command line — e.g. `git diff .claude/test-gate.json > /tmp/out.txt`
    # (the `>` redirects the diff elsewhere, not into the protected file) or
    # `cat .claude/rules-disable; rm /tmp/scratch.txt` (an unrelated rm after
    # a read) were wrongly blocked.
    # Note: TARGET deliberately does NOT reuse $PROTECTED_CMD's own leading
    # "(^|[^A-Za-z0-9_])" boundary — when embedded right after a write verb's
    # own [[:space:]]+ (which already consumed the single separating space),
    # that boundary alternative would itself consume the path's leading "."
    # and leave nothing for the literal "\.claude" that must follow it,
    # breaking the match entirely. The verb + [[:space:]]+/[^|;&]* before
    # TARGET already guarantees a non-identifier boundary, so only the
    # trailing boundary is needed here.
    PATH_CORE='\.claude/(test-gate\.json|perf-gate\.json|rules-disable)([^A-Za-z0-9_.]|$)'
    PATH_CORE="${PATH_CORE}"'|claude-test-gate/evidence\.jsonl([^A-Za-z0-9_.]|$)'
    TARGET="[^|;&]*(${PATH_CORE})"
    WRITE_OPS="(>>?[[:space:]]*${TARGET}"
    WRITE_OPS="${WRITE_OPS}|<<<${TARGET}"
    WRITE_OPS="${WRITE_OPS}|[[:space:]]tee([[:space:]]+-[a-zA-Z]+)*[[:space:]]+${TARGET}"
    WRITE_OPS="${WRITE_OPS}|sed[[:space:]]+-i${TARGET}"
    WRITE_OPS="${WRITE_OPS}|(cp|mv|install)[[:space:]]+${TARGET}"
    WRITE_OPS="${WRITE_OPS}|dd[[:space:]]+of=${TARGET}"
    WRITE_OPS="${WRITE_OPS}|truncate[[:space:]]+${TARGET}"
    WRITE_OPS="${WRITE_OPS}|(rm|unlink)[[:space:]]+${TARGET}"
    WRITE_OPS="${WRITE_OPS}|git[[:space:]]+(checkout|restore|apply|reset)${TARGET}"
    WRITE_OPS="${WRITE_OPS}|jq[[:space:]][^|;&]*-i${TARGET}"
    WRITE_OPS="${WRITE_OPS}|(python[0-9.]*|perl|node|patch)[[:space:]]+${TARGET})"
    echo "$CMD" | grep -qE "$WRITE_OPS" && block "write to gate config detected: '$CMD'"
    ;;
esac

exit 0
