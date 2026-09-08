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
# Blocks (exit 2), Bash: any command that names a protected path AND carries
#   a write-shaped token (redirection, tee, sed -i, cp/mv/install, dd, rm,
#   truncate, git checkout/restore/apply/reset, or a scripting interpreter
#   one-liner). Reads (cat, grep, jq without -i, git diff/log/show) pass.
#
# Deliberately NO bypass of any kind:
#   - no rules-disable opt-out (this hook guards rules-disable itself —
#     letting it check rules-disable would be checking the lock with its
#     own key)
#   - no CLAUDE_*_ALLOWED env var
# If a gate genuinely needs to change (enable/disable/relax), tell the user
# directly and have them make the edit, or run the specific command
# themselves. Do not read or modify this hook to find a way around it, and
# do not try a different tool/subagent/heredoc/interpreter to write the file
# instead — that's exactly the class of workaround this hook exists to stop.
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
  echo "There is no bypass. If a gate genuinely needs to change, tell the" >&2
  echo "user exactly what needs to change and why, and have them make the" >&2
  echo "edit or run the command themselves." >&2
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
    WRITE_OPS='(>>?[^&]|<<<|[[:space:]]tee([[:space:]]|$)|sed[[:space:]]+-i|cp[[:space:]]|mv[[:space:]]|install[[:space:]]|dd[[:space:]]+of=|truncate[[:space:]]|rm[[:space:]]|unlink[[:space:]]|git[[:space:]]+(checkout|restore|apply|reset)|jq[[:space:]].*-i|python[0-9.]*[[:space:]]|perl[[:space:]]|node[[:space:]]|patch[[:space:]])'
    echo "$CMD" | grep -qE "$WRITE_OPS" && block "write to gate config detected: '$CMD'"
    ;;
esac

exit 0
