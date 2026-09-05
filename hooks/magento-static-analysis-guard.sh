#!/bin/bash
# PreToolUse Bash hook — enforced Magento coding-standard + static analysis
# on `git commit`, closing the gap where magento-standards MCP only answers
# "what's compliant" advisory-side with nothing actually linting a diff.
#
# Gated like bricklayer-mcp.sh: only acts when BOTH vendor/bin/phpcs and
# vendor/bin/phpstan exist at the project root (installed together per
# project via `composer require --dev magento/magento-coding-standard
# phpstan/phpstan bitexpert/phpstan-magento`) — silent exit 0 everywhere
# else (non-Magento containers, or a project that hasn't installed the
# tools yet). No noise fleet-wide.
#
# Scope: staged files under app/code/ and app/design/ only — custom code,
# never core/vendor. phpcs (standard=Magento2) runs against staged .php and
# .phtml; phpstan (project phpstan.neon, which should already point at a
# phpstan-baseline.neon grandfathering pre-existing debt) runs against
# staged .php only — .phtml mixes HTML+PHP and isn't a valid phpstan target.
#
# Grandfathering pre-existing debt: phpstan uses its native baseline file.
# phpcs has no equivalent baseline mechanism, and a mature Magento codebase
# reliably already has pre-existing errors in files a commit only touches
# incidentally — so the phpcs side only blocks on an ERROR whose line was
# actually ADDED by this diff (unified-diff hunk parsing against the
# staged patch), never on an untouched pre-existing line. Warnings never
# block either side. A quiet run (or a project with no phpstan.neon / no
# baseline yet) is not this hook's job to configure — see the
# magento-static-analysis-guard rollout notes for the one-time per-project
# setup steps.
#
# Per-project opt-out: add the line `magento-static-analysis-guard` to
# <repo>/.claude/rules-disable.
#
# Defensive: NO set -e. Silent no-op if jq missing, input unparseable, not
# a git commit, or not a git repo. Never blocks on infrastructure failure
# (a phpcs/phpstan crash prints a warning and lets the commit through —
# this gate is about catching real violations, not adding a new way for
# broken tooling to block unrelated work).

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null)
[ -z "$CMD" ] && exit 0

GIT_RE='(^|[;&|[:space:]])git[[:space:]]+([^;&|]*[[:space:]])?'
echo "$CMD" | grep -qE "${GIT_RE}commit([[:space:]]|\$)" || exit 0

CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD=$(pwd)
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

ROOT=$(cd "$CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
[ -z "$ROOT" ] && exit 0
cd "$ROOT" 2>/dev/null || exit 0

# Per-project opt-out
if [ -f "$ROOT/.claude/rules-disable" ]; then
  grep -qx 'magento-static-analysis-guard' "$ROOT/.claude/rules-disable" 2>/dev/null && exit 0
fi

# Gate: both tools must be installed, else this project hasn't opted in yet.
[ -x "$ROOT/vendor/bin/phpcs" ] || exit 0
[ -x "$ROOT/vendor/bin/phpstan" ] || exit 0

STAGED=$(git diff --cached --name-only --diff-filter=ACMR -- app/code app/design 2>/dev/null)
[ -z "$STAGED" ] && exit 0

PHP_FILES=$(printf '%s\n' "$STAGED" | grep -E '\.php$')
PHPCS_FILES=$(printf '%s\n' "$STAGED" | grep -E '\.(php|phtml)$')
[ -z "$PHPCS_FILES" ] && [ -z "$PHP_FILES" ] && exit 0

FAIL=0
REPORT=""

if [ -n "$PHPCS_FILES" ]; then
  # phpcs has no baseline mechanism (unlike phpstan below), and a mature
  # Magento codebase reliably already has pre-existing errors in files a
  # commit only touches incidentally — gating on "any error in the file"
  # would block on inherited debt, not the change. So: only fail on an
  # ERROR whose line was actually ADDED by this diff (unified-diff hunk
  # parsing, `+a,b` ranges = added-line numbers a..a+b-1). Pre-existing
  # lines in a touched file are left alone; warnings never block.
  CHANGED_LINES=$(mktemp)
  # shellcheck disable=SC2086
  printf '%s\n' $PHPCS_FILES | while IFS= read -r f; do
    [ -z "$f" ] && continue
    git diff --cached -U0 -- "$f" 2>/dev/null | awk -v f="$f" '
      /^@@/ {
        match($0, /\+[0-9]+(,[0-9]+)?/)
        spec = substr($0, RSTART+1, RLENGTH-1)
        split(spec, parts, ",")
        start = parts[1]+0
        count = (parts[2] == "" ? 1 : parts[2]+0)
        for (i = 0; i < count; i++) print f ":" (start+i)
      }'
  done > "$CHANGED_LINES"

  # shellcheck disable=SC2086
  PHPCS_JSON=$("$ROOT/vendor/bin/phpcs" --standard=Magento2 --report=json $PHPCS_FILES 2>/dev/null)
  NEW_ERRORS=""
  if echo "$PHPCS_JSON" | jq -e . >/dev/null 2>&1; then
    NEW_ERRORS=$(echo "$PHPCS_JSON" | jq -r '
      .files // {} | to_entries[] | .key as $file |
      .value.messages[]? | select(.type=="ERROR") |
      "\($file):\(.line): \(.message) (\(.source))"
    ' 2>/dev/null | while IFS= read -r line; do
      fl="${line%%: *}"
      grep -qFx "$fl" "$CHANGED_LINES" && echo "$line"
    done)
  fi
  rm -f "$CHANGED_LINES"

  if [ -n "$NEW_ERRORS" ]; then
    FAIL=1
    REPORT="${REPORT}--- phpcs (Magento2 standard, new lines only) ---
${NEW_ERRORS}

"
  fi
fi

if [ -n "$PHP_FILES" ] && [ -f "$ROOT/phpstan.neon" ]; then
  # shellcheck disable=SC2086
  PHPSTAN_OUT=$("$ROOT/vendor/bin/phpstan" analyse --no-progress --error-format=table $PHP_FILES 2>&1)
  PHPSTAN_RC=$?
  if [ "$PHPSTAN_RC" != "0" ]; then
    FAIL=1
    REPORT="${REPORT}--- phpstan (baseline-aware) ---
${PHPSTAN_OUT}

"
  fi
fi

[ "$FAIL" = "0" ] && exit 0

echo "BLOCKED by magento-static-analysis-guard.sh: violations in staged custom code" >&2
echo "" >&2
echo "$REPORT" >&2
echo "Fix the reported items (or, for a genuinely acceptable phpstan finding," >&2
echo "regenerate the baseline: vendor/bin/phpstan analyse --generate-baseline)." >&2
echo "Opt out for this project: add 'magento-static-analysis-guard' to .claude/rules-disable" >&2
exit 2
