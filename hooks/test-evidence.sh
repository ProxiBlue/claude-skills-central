#!/bin/bash
# PostToolUse Bash hook — records the evidence that test-gate.sh (PreToolUse)
# checks at commit/push time. Two record types, appended to
# <git-dir>/claude-test-gate/evidence.jsonl:
#
#   {"type":"test","family":"unit"|"e2e","ts":...,"state":<hash>,"exit_code":N,"cmd":...}
#       written when the Bash command was a real test-runner invocation
#       (see tg_test_families — mentions of "phpunit" in grep/echo do NOT
#       count; a chain running both runners records one line per family).
#       state is the working-tree content hash at recording time; any
#       later edit produces a different hash, invalidating the evidence.
#
#   {"type":"commit","ts":...,"head":<sha>}
#       written after a successful `git commit`, so a following `git push` of
#       that HEAD passes the gate without a redundant re-run (the commit
#       itself was already gated).
#
# Exit-code model (verified empirically 2026-08-01 on claude-code v2.1.198,
# via payload dump in a live headless session): PostToolUse for Bash fires
# ONLY when the command exited 0, and tool_response carries NO exit-code
# field at all ({stdout, stderr, interrupted, isImage, noOutputExpected}).
# Therefore: hook fired == command succeeded. We default the exit code to 0
# when absent, and still honor a numeric field if a future harness adds one.
# Failing runs produce no PostToolUse event, so they can never record a
# false pass. (The original .tool_response.exit_code extraction recorded
# nothing on any run — caught in the first live-fire, 2026-08-01.)
#
# Defensive: no set -e. Missing jq / unparseable input → silent no-op.
# Never blocks anything (PostToolUse, exit 0 always).

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -z "$CMD" ] && exit 0

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
[ -f "$SCRIPT_DIR/test-gate-lib.sh" ] || exit 0
# shellcheck source=test-gate-lib.sh
. "$SCRIPT_DIR/test-gate-lib.sh"

EXIT_CODE=$(echo "$INPUT" | jq -r '.tool_response.exit_code // .tool_response.exitCode // .tool_response.code // empty' 2>/dev/null)
# v2.1.198: field absent and hook only fires on success — absent means 0
case "$EXIT_CODE" in ''|*[!0-9]*) EXIT_CODE=0 ;; esac

CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD=$(pwd)

# honor a leading `cd <path> && ...` for project-root resolution
FIRST_CD=$(printf '%s' "$CMD" | grep -oE '^[[:space:]]*cd[[:space:]]+[^;&|]+' | head -1 \
  | sed -E 's/^[[:space:]]*cd[[:space:]]+//; s/[[:space:]]+$//')
if [ -n "$FIRST_CD" ]; then
  case "$FIRST_CD" in
    "~")   FIRST_CD="$HOME" ;;
    "~/"*) FIRST_CD="$HOME/${FIRST_CD#\~/}" ;;
  esac
  case "$FIRST_CD" in
    /*) CWD="$FIRST_CD" ;;
    *)  CWD="$CWD/$FIRST_CD" ;;
  esac
fi

ROOT=$(tg_project_root "$CWD") || exit 0
[ -z "$ROOT" ] && exit 0
EF=$(tg_evidence_file "$ROOT") || exit 0
[ -z "$EF" ] && exit 0

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

trim_log() {
  local lines
  lines=$(wc -l < "$EF" 2>/dev/null) || return 0
  if [ "${lines:-0}" -gt 1000 ]; then
    tail -n 500 "$EF" > "$EF.tmp" 2>/dev/null && mv "$EF.tmp" "$EF" 2>/dev/null
  fi
}

FAMS=$(tg_test_families "$CMD")
if [ -n "$FAMS" ]; then
  # non-zero only possible if a future harness adds the field — skip record
  [ "$EXIT_CODE" = "0" ] || exit 0
  # A test repo nested inside a project repo (e.g. tests/m2-hyva-playwright with
  # its own .git) validates the enclosing app too — record in both, each with
  # its own state hash, or the parent's push gate never sees e2e evidence
  # (chatroom thread e4bf2712: a leading `cd tests/...` resolved ROOT to the
  # sub-repo and all evidence landed there, blinding the project gate).
  ROOTS="$ROOT"
  PARENT=$(cd "$ROOT/.." 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$PARENT" ] && [ "$PARENT" != "$ROOT" ]; then
    ROOTS=$(printf '%s\n%s' "$ROOT" "$PARENT")
  fi
  while IFS= read -r R; do
    [ -z "$R" ] && continue
    EF=$(tg_evidence_file "$R") || continue
    [ -z "$EF" ] && continue
    HASH=$(tg_state_hash "$R")
    [ -z "$HASH" ] && continue
    for FAM in $FAMS; do
      jq -cn --arg ts "$TS" --arg state "$HASH" --argjson ec "$EXIT_CODE" --arg cmd "$CMD" --arg fam "$FAM" \
        '{type:"test", family:$fam, ts:$ts, state:$state, exit_code:$ec, cmd:$cmd}' >> "$EF" 2>/dev/null
    done
    trim_log
  done <<ROOTS_EOF
$ROOTS
ROOTS_EOF
  exit 0
fi

# bless successful commits (handles `git commit`, `git -C x commit`, chained forms)
if printf '%s' "$CMD" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+([^;&|]*[[:space:]])?commit([[:space:]]|$)'; then
  [ "$EXIT_CODE" = "0" ] || exit 0
  HEAD=$(cd "$ROOT" 2>/dev/null && git rev-parse HEAD 2>/dev/null)
  [ -z "$HEAD" ] && exit 0
  jq -cn --arg ts "$TS" --arg head "$HEAD" \
    '{type:"commit", ts:$ts, head:$head}' >> "$EF" 2>/dev/null
  trim_log
fi

exit 0
