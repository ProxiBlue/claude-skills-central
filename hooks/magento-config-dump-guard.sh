#!/bin/bash
# PreToolUse Bash hook — keeps `app:config:dump` and its fallout out of the tree.
#
# Origin incident (chatroom thread 50b98acf, pvcpipesupplies #465, 2026-09-22):
# a tdd-worker wanted to read the db block of env.php and ran
#   php bin/magento app:config:dump 2>/dev/null >/dev/null; grep -m1 -A5 "'db'" app/etc/env.php
# app:config:dump is not a read. It re-partitions configuration: app/etc/config.php
# became a 9,386-line dump carrying the Stripe test publishable key, stripe_mode=test
# and ShipperHQ DEVELOPMENT scope with encrypted credentials, while env.php was
# rewritten WITHOUT those values. The diff then sat unnoticed across four batches.
# Had it been committed and deployed it would have locked every admin config field
# on live and switched Stripe to test mode. simplify-pass caught it at
# post-implementation; nothing was committed, but only by luck.
#
# Two layers, matching the guards requested on that thread:
#
# LAYER 1 (container sessions only) — block the commands that cause it:
#   - `app:config:dump` in any invocation form
#   - `config:set --lock-config` / `--lock-env` (same re-partitioning effect)
#   - `app:config:import` (applies a dump; harmless alone, destructive after one)
#   - any WRITE-shaped command targeting app/etc/config.php (redirect, tee,
#     sed -i, cp/mv/rm/truncate/dd, git restore/apply/reset of that path)
#   Reads pass untouched: cat/grep/head/jq, git diff/log/show.
#   To read configuration, use `php -r` against env.php, or the Read tool.
#
# LAYER 2 (everywhere) — block a `git commit` that would carry a dump, by
# inspecting the working-tree app/etc/config.php against HEAD:
#   (a) newly added top-level 'scopes' or 'themes' keys
#   (b) an added key ending _pk / _sk / api_key / password / secret / token /
#       environment_scope
#   (c) growth of more than 200 lines vs HEAD
#   Offending PATHS are printed, never values.
#   A host session commits dumps just as badly as a container one, so this layer
#   is not scoped — but it only speaks when config.php is actually modified.
#
# Opt out per project: a line `magento-config-dump-guard` in the project's
# .claude/rules-disable file.
# User-only escape for a genuinely needed dump: run it yourself with the `!`
# prefix (that path does not go through the Bash tool, so no hook sees it), or
# export CLAUDE_MAGENTO_CONFIG_DUMP_ALLOWED=1 before starting claude. There is
# deliberately no in-session bypass Claude can set for itself.
#
# NOTE for future maintainers: keep destructive command literals (git checkout
# of a path, stash drop, reset --hard) OUT of this file's strings. git-tree-guard.sh
# scans whole Bash command strings, so a heredoc writing this file is blocked if
# its body contains one. Recovery guidance below names the operation in prose and
# routes it to the user, which is also the correct instruction: inside a container
# Claude is blocked from running it anyway.
#
# Defensive: no set -e. jq missing / unparseable input → silent no-op.

[ "${CLAUDE_MAGENTO_CONFIG_DUMP_ALLOWED:-0}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

TOOL=$(echo "$INPUT" | jq -r '.tool_name // "Bash"' 2>/dev/null)
[ "$TOOL" = "Bash" ] || exit 0
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null)
[ -z "$CMD" ] && exit 0

CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD=$(pwd)
ROOT=$(cd "$CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)

if [ -n "$ROOT" ] && [ -f "$ROOT/.claude/rules-disable" ]; then
  grep -qx 'magento-config-dump-guard' "$ROOT/.claude/rules-disable" 2>/dev/null && exit 0
fi

IN_CONTAINER=0
{ [ -n "${DDEV_PROJECT:-}" ] || [ -f /.dockerenv ]; } && IN_CONTAINER=1

# --- magento invocation detection -------------------------------------------
# `app:config:dump` only counts when it is a SUBCOMMAND of a magento call, not
# when it appears as a string — `grep -rn "app:config:dump" docs/` and
# `echo "never run app:config:dump"` must pass. Same command-position approach
# as tg__segment_is_test in test-gate-lib.sh: walk the tokens of each shell
# segment, skip env-var prefixes and wrappers, and only accept when the real
# command is magento. Echoes that segment's magento arguments.
mcg__segment_magento_args() {
  local depth=0 t base
  while [ $# -gt 0 ] && [ $depth -lt 8 ]; do
    t="$1"; t="${t#\(}"
    [ -z "$t" ] && { shift; continue; }
    case "$t" in [A-Za-z_]*=*) shift; continue ;; esac
    base="${t##*/}"
    case "$base" in
      magento)
        shift; printf '%s\n' "$*"; return 0 ;;
      php|sudo|time|nice|env|exec|xargs)
        shift
        while [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done
        depth=$((depth+1)); continue ;;
      ddev)
        case "${2:-}" in exec|php) shift 2 ;; *) return 1 ;; esac
        depth=$((depth+1)); continue ;;
      *) return 1 ;;
    esac
  done
  return 1
}

# All magento argument lists in the command string, one segment per line.
mcg_magento_args() {
  local seg
  while IFS= read -r seg; do
    # shellcheck disable=SC2086
    ( set -f; set -- $seg; mcg__segment_magento_args "$@" )
  done <<EOF
$(printf '%s\n' "$1" | sed -E 's/(\|\|)|(&&)|;|\||\$\(/\n/g')
EOF
}

# ---------------------------------------------------------------------------
# LAYER 1 — the dump-causing commands (container sessions only)
# ---------------------------------------------------------------------------
if [ "$IN_CONTAINER" = "1" ]; then
  BLOCK=""
  MAGENTO_ARGS=$(mcg_magento_args "$CMD")
  if printf '%s' "$MAGENTO_ARGS" | grep -qE '(^|[[:space:]])app:config:dump([[:space:]]|$)'; then
    BLOCK="app:config:dump re-partitions configuration: it rewrites app/etc/config.php as a full dump (modules + system + scopes + themes, including payment keys and encrypted third-party credentials) and strips those values out of env.php. It is not a way to read configuration."
  elif printf '%s' "$MAGENTO_ARGS" | grep -qE '(^|[[:space:]])config:set([[:space:]]|$)' && printf '%s' "$MAGENTO_ARGS" | grep -qE -- '--lock-(config|env)'; then
    BLOCK="config:set --lock-config / --lock-env writes the value into app/etc/config.php (or env.php) and locks the field in the admin, with the same deploy consequence as a dump: the field becomes uneditable on live."
  elif printf '%s' "$MAGENTO_ARGS" | grep -qE '(^|[[:space:]])app:config:import([[:space:]]|$)'; then
    BLOCK="app:config:import applies whatever app/etc/config.php currently holds. Run after an accidental dump, it makes the dump authoritative."
  elif printf '%s' "$CMD" | grep -qE 'app/etc/config\.php'; then
    # write-shaped access to app/etc/config.php
    if printf '%s' "$CMD" | grep -qE '>[[:space:]]*[^|;&]*app/etc/config\.php|(^|[[:space:]])tee([[:space:]]+-[a-zA-Z]+)*[[:space:]]+[^|;&]*app/etc/config\.php|sed[[:space:]]+[^|;&]*-i|(^|[[:space:]])(cp|mv|rm|install|truncate|dd|shred)([[:space:]]+-[a-zA-Z-]+)*[[:space:]]+[^|;&]*app/etc/config\.php|git[[:space:]]+(restore|apply|reset)[^|;&]*app/etc/config\.php|(perl|python3?|php)[[:space:]]+-[a-zA-Z]*[ei]'; then
      BLOCK="this command writes app/etc/config.php directly. That file is deploy-critical: what it contains becomes locked, non-editable configuration on live."
    fi
  fi

  if [ -n "$BLOCK" ]; then
    {
      echo "BLOCKED by magento-config-dump-guard.sh (layer 1): command would rewrite app/etc/config.php."
      echo ""
      echo "Why: $BLOCK"
      echo ""
      echo "Origin: pvcpipesupplies #465 — a worker ran app:config:dump to peek at env.php's db"
      echo "block. It produced a 9,386-line config.php holding the Stripe test publishable key"
      echo "and ShipperHQ DEVELOPMENT credentials, and removed those values from env.php. The"
      echo "diff went unnoticed for four batches; on deploy it would have locked every admin"
      echo "config field on live and put Stripe in test mode."
      echo ""
      echo "To READ configuration instead:"
      echo "  php -r '\$c = include \"app/etc/env.php\"; print_r(array_keys(\$c));'"
      echo "  php -r '\$c = include \"app/etc/env.php\"; print_r(\$c[\"db\"][\"connection\"][\"default\"]);'"
      echo "  or open app/etc/env.php with the Read tool. Neither mutates anything."
      echo ""
      echo "If a dump is genuinely required, STOP and ask the user to run it themselves"
      echo "(the \`!\` prefix bypasses the Bash tool). Do not re-shape this command to"
      echo "evade the guard."
    } >&2
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# LAYER 2 — never commit a dump (all sessions)
# ---------------------------------------------------------------------------
printf '%s' "$CMD" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+([^;&|]*[[:space:]])?commit([[:space:]]|$)' || exit 0
[ -n "$ROOT" ] || exit 0
[ -f "$ROOT/app/etc/config.php" ] || exit 0
git -C "$ROOT" ls-files --error-unmatch app/etc/config.php >/dev/null 2>&1 || exit 0

DIFF=$(git -C "$ROOT" diff HEAD -- app/etc/config.php 2>/dev/null)
[ -n "$DIFF" ] || exit 0

ADDED=$(printf '%s\n' "$DIFF" | grep '^+' | grep -v '^+++')
NOW=$(wc -l < "$ROOT/app/etc/config.php" 2>/dev/null)
WAS=$(git -C "$ROOT" show HEAD:app/etc/config.php 2>/dev/null | wc -l)
GROWTH=$(( ${NOW:-0} - ${WAS:-0} ))

FINDINGS=""
SECTIONS=$(printf '%s\n' "$ADDED" | grep -oE "'(scopes|themes)'[[:space:]]*=>" | grep -oE "'(scopes|themes)'" | sort -u | tr -d "'" | tr '\n' ' ')
[ -n "$SECTIONS" ] && FINDINGS="${FINDINGS}  (a) adds top-level dump section(s): ${SECTIONS}
"
SECRETS=$(printf '%s\n' "$ADDED" \
  | grep -oE "'[A-Za-z0-9_/.-]*(_pk|_sk|api_key|password|secret|secret_token|token|environment_scope)'[[:space:]]*=>" \
  | grep -oE "'[^']*'" | tr -d "'" | sort -u | head -25)
if [ -n "$SECRETS" ]; then
  FINDINGS="${FINDINGS}  (b) adds credential-shaped config path(s) — values withheld:
$(printf '%s\n' "$SECRETS" | sed 's/^/        /')
"
fi
[ "$GROWTH" -gt 200 ] && FINDINGS="${FINDINGS}  (c) grows by ${GROWTH} lines vs HEAD (${WAS} -> ${NOW}); threshold is 200
"

[ -z "$FINDINGS" ] && exit 0

{
  echo "BLOCKED by magento-config-dump-guard.sh (layer 2): app/etc/config.php in this commit looks like an app:config:dump artefact."
  echo ""
  echo "What tripped:"
  printf '%s' "$FINDINGS"
  echo ""
  echo "Committing a dump locks every field it contains on live (non-editable in the"
  echo "admin) and can flip payment modes. See pvcpipesupplies #465, where exactly this"
  echo "diff sat in the tree for four batches with Stripe test keys in it."
  echo ""
  echo "What to do:"
  echo "  1. Look at what changed, values aside:"
  echo "       git diff --stat HEAD -- app/etc/config.php"
  echo "       git diff HEAD -- app/etc/config.php | grep -E \"^\\+\" | head -30"
  echo "  2. Commit only your real changes by naming them explicitly, leaving"
  echo "     config.php out of the commit:"
  echo "       git commit -- <your files>"
  echo "  3. If it IS a dump artefact, the file must be restored to its HEAD version"
  echo "     and env.php checked for the values the dump moved out of it (compare"
  echo "     against app/etc/env.local.php). STOP and ask the user to do that restore —"
  echo "     it discards working-tree state, git-tree-guard.sh blocks you from running"
  echo "     it, and in a shared worktree it can destroy another worker's edits."
  echo "  4. If this dump is intentional and reviewed, STOP and ask the user to confirm."
  echo "     Do not decide this yourself — it is a deploy-affecting change."
} >&2
exit 2
