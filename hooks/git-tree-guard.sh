#!/bin/bash
# PreToolUse Bash hook — blocks git commands that destroy uncommitted work in
# the working tree.
#
# Born from the 2026-08-05 pvcpipesupplies #351 incident: parallel
# plan-orchestrate tdd-workers share one working tree; one worker's exploratory
# `git stash` captured ALL tracked modifications (including sibling workers'
# unsaved edits), and its routine `git stash drop` destroyed them permanently.
# Recovery took a 170k-blob fsck grep. These commands are never safe for an
# agent to run against a tree that may hold work it doesn't know about.
#
# Blocks (exit 2 = hard block, surfaces message to Claude):
#   - git stash              (bare / push / save — captures other work)
#   - git stash pop|drop|clear      (destroys stashed work)
#   - git reset --hard              (discards tracked modifications)
#   - git clean                     (deletes untracked files; -n/--dry-run ok)
#   - git checkout -- <path> / git checkout . / git checkout -f
#                                   (discards worktree changes)
#   - git restore <path>            (discards worktree changes; pure
#                                    --staged unstaging is allowed)
#   - git switch -f|--discard-changes
#
# Allows:
#   - git stash list / git stash show / git stash apply (read-only / additive)
#   - git clean -n / --dry-run
#   - git restore --staged <path> (without --worktree)
#   - normal checkout/switch branch changes, soft/mixed resets
#
# Per-project opt-out: add `git-tree-guard` to <repo>/.claude/rules-disable
# (one hook name per line).
#
# Bypass: export `CLAUDE_TREE_GUARD_ALLOWED=1` in the shell session BEFORE
# starting claude. Inline prefix from inside a session does NOT work — the hook
# scans the command string, so the prefix is still present when the pattern is
# matched.
#
# Defensive: NO `set -e`. Silent no-op if jq missing or input unparseable —
# never blocks on infrastructure failure.

# Honor user bypass for this session
[ "${CLAUDE_TREE_GUARD_ALLOWED:-0}" = "1" ] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null)
[ -z "$CMD" ] && exit 0

# Fast path: nothing git-ish in the command at all
echo "$CMD" | grep -q 'git' || exit 0

# Per-project opt-out
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$TOPLEVEL" ] && [ -f "$TOPLEVEL/.claude/rules-disable" ]; then
  grep -qx 'git-tree-guard' "$TOPLEVEL/.claude/rules-disable" 2>/dev/null && exit 0
fi

block() {
  echo "BLOCKED by git-tree-guard.sh: $1" >&2
  echo "" >&2
  echo "This command can permanently destroy uncommitted work in the shared" >&2
  echo "working tree — including edits made by OTHER agents/workers that this" >&2
  echo "session does not know about (see: pvcpipesupplies #351 stash-loss" >&2
  echo "incident, 2026-08-05)." >&2
  echo "" >&2
  echo "STOP. Do NOT retry. Do NOT work around:" >&2
  echo "  - Do not prefix CLAUDE_TREE_GUARD_ALLOWED=1 (the hook scans the" >&2
  echo "    command string, so the prefix is still caught by the pattern)." >&2
  echo "  - Do not wrap in bash -c, eval, env, xargs, or a heredoc." >&2
  echo "  - Do not invoke a skill, sub-agent, or background task to do it." >&2
  echo "  - Do not read or modify this hook to find a way around it." >&2
  echo "" >&2
  echo "If the working tree state is in the way: COMMIT it (a WIP commit on" >&2
  echo "the current branch is always safe and always recoverable), or tell" >&2
  echo "the user what you want to discard and let them run the command. The" >&2
  echo "bypass env var must be exported BEFORE claude starts." >&2
  exit 2
}

# --- git stash: block every mutating form -----------------------------------
# Allowed read-only/additive subcommands: list, show, apply, branch.
if echo "$CMD" | grep -qE '(^|[^[:alnum:]_])git[[:space:]]+stash([[:space:]]|$|;|&|\|)'; then
  STASH_SUB=$(echo "$CMD" | sed -nE 's/.*git[[:space:]]+stash[[:space:]]*([[:alnum:]-]*).*/\1/p' | head -1)
  case "$STASH_SUB" in
    list|show|apply|branch) : ;;  # safe
    *) block "git stash (mutating form '${STASH_SUB:-bare}') detected: '$CMD'" ;;
  esac
fi

# --- git reset --hard --------------------------------------------------------
if echo "$CMD" | grep -qE 'git[[:space:]]+reset[[:space:]]([^;|&]*[[:space:]])?--hard' ; then
  block "git reset --hard detected: '$CMD'"
fi

# --- git clean (anything except a dry run) ----------------------------------
if echo "$CMD" | grep -qE 'git[[:space:]]+clean([[:space:]]|$)'; then
  echo "$CMD" | grep -qE 'git[[:space:]]+clean[[:space:]][^;|&]*(-n|--dry-run)' \
    || block "git clean detected (deletes untracked files): '$CMD'"
fi

# --- git checkout discarding worktree changes -------------------------------
# `git checkout [ref] -- <path>` / `git checkout .` / `git checkout -f`
if echo "$CMD" | grep -qE 'git[[:space:]]+checkout[[:space:]]([^;|&]*[[:space:]])?--([[:space:]]|$)'; then
  block "git checkout -- <path> detected (discards worktree changes): '$CMD'"
fi
if echo "$CMD" | grep -qE 'git[[:space:]]+checkout[[:space:]]+\.([[:space:]]|$|;)'; then
  block "git checkout . detected (discards worktree changes): '$CMD'"
fi
if echo "$CMD" | grep -qE 'git[[:space:]]+checkout[[:space:]]([^;|&]*[[:space:]])?(-f|--force)([[:space:]]|$)'; then
  block "git checkout --force detected (discards worktree changes): '$CMD'"
fi

# --- git restore (worktree restore discards changes) ------------------------
# Pure index unstage (`--staged` present, `--worktree` absent) is allowed.
if echo "$CMD" | grep -qE 'git[[:space:]]+restore([[:space:]]|$)'; then
  RESTORE_OK=0
  if echo "$CMD" | grep -qE 'git[[:space:]]+restore[[:space:]][^;|&]*(--staged|-S)([[:space:]]|$)' \
     && ! echo "$CMD" | grep -qE 'git[[:space:]]+restore[[:space:]][^;|&]*(--worktree|-W)([[:space:]]|$)'; then
    RESTORE_OK=1
  fi
  [ "$RESTORE_OK" = "1" ] || block "git restore detected (discards worktree changes): '$CMD'"
fi

# --- git switch with force/discard ------------------------------------------
if echo "$CMD" | grep -qE 'git[[:space:]]+switch[[:space:]]([^;|&]*[[:space:]])?(-f|--force|--discard-changes)([[:space:]]|$)'; then
  block "git switch --discard-changes detected: '$CMD'"
fi

exit 0
