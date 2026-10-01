#!/bin/bash
# PreToolUse Bash hook — blocks Magento state-churn commands (cache clear,
# setup:upgrade / setup:di:compile / setup:static-content:deploy, config:set,
# indexer:reindex, or a pub/static | var/view_preprocessed | var/cache |
# var/page_cache | generated wipe) while a Playwright / phpunit / paratest
# suite is in flight.
#
# Origin incident: an orchestrator ran `bin/magento cache:clean` plus a
# pub/static + var/view_preprocessed wipe while a 4-worker Playwright full
# suite was still running. The churn landed on every in-flight browser
# session mid-request — compiled DI, static assets and page cache all moved
# under requests that were already executing — and produced spurious
# failures across the board: 2h46m lost plus 5 remediation batches spent
# separating real regressions from churn artifacts.
#
# Blocks (exit 2) only when BOTH:
#   a) the command is Magento / n98-magerun2 state churn (see patterns below)
#   b) a playwright-test / phpunit / paratest process is currently running
#
# Process probe is overridable for tests: set SUITE_INFLIGHT_PS_CMD to a
# command string that, when eval'd, prints `PID CMD` lines like `pgrep -af`
# does — so tests don't depend on a real suite actually running.
#
# Read-only magento commands (cache:status, config:show, indexer:status, …)
# are never matched by the churn patterns below and always pass, suite
# running or not.
#
# Per-project opt-out: a line `suite-inflight-guard` in
# <repo>/.claude/rules-disable.
#
# Defensive: no set -e. jq missing / unparseable input → silent no-op.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

TOOL=$(echo "$INPUT" | jq -r '.tool_name // "Bash"' 2>/dev/null)
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null)
[ -z "$CMD" ] && exit 0

# --- per-project opt-out -----------------------------------------------------
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD=$(pwd)
TOPLEVEL=$(cd "$CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$TOPLEVEL" ] && [ -f "$TOPLEVEL/.claude/rules-disable" ]; then
  grep -qx 'suite-inflight-guard' "$TOPLEVEL/.claude/rules-disable" 2>/dev/null && exit 0
fi

# --- (a) Magento / n98-magerun2 state-churn detection ------------------------
MAGENTO_INVOKE='(^|[;&|[:space:]])(ddev[[:space:]]+exec[[:space:]]+)?(php[[:space:]]+)?bin/magento([[:space:]]|$)'
DDEV_MAGENTO_SHORTCUT='(^|[;&|[:space:]])ddev[[:space:]]+magento([[:space:]]|$)'
MAGENTO_CHURN_SUBCMD='(^|[[:space:]])(cache:clean|cache:flush|setup:upgrade|setup:di:compile|setup:static-content:deploy|config:set|indexer:reindex)([[:space:]]|$)'
MAGERUN_CHURN='(^|[;&|[:space:]])n98-magerun2([[:space:]]+-[a-zA-Z-]+)*[[:space:]]+(config:store:set|cache:[a-z-]+)([[:space:]]|$)'
RM_TARGET_DIRS='(pub/static|var/view_preprocessed|var/cache|var/page_cache|generated)'
RM_CHURN="(^|[;&|[:space:]])rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*[[:space:]].*${RM_TARGET_DIRS}"
FIND_DELETE_CHURN="(^|[;&|[:space:]])find[[:space:]].*${RM_TARGET_DIRS}.*-delete"

IS_CHURN=0
if echo "$CMD" | grep -qE "$MAGENTO_INVOKE|$DDEV_MAGENTO_SHORTCUT"; then
  echo "$CMD" | grep -qE "$MAGENTO_CHURN_SUBCMD" && IS_CHURN=1
fi
[ "$IS_CHURN" = 0 ] && echo "$CMD" | grep -qE "$MAGERUN_CHURN" && IS_CHURN=1
[ "$IS_CHURN" = 0 ] && echo "$CMD" | grep -qE "$RM_CHURN" && IS_CHURN=1
[ "$IS_CHURN" = 0 ] && echo "$CMD" | grep -qE "$FIND_DELETE_CHURN" && IS_CHURN=1

[ "$IS_CHURN" = 1 ] || exit 0

# --- (b) is a test suite in flight? ------------------------------------------
# Only real test RUNS count: `playwright test`, phpunit, paratest. The
# long-lived @playwright/mcp servers (`playwright-mcp`) are always running in
# every container and on the host — matching bare "playwright" would block
# every cache clear forever.
PROBE_RE='playwright test|playwright\.js test|bin/phpunit|phpunit\.phar|(^|[ /])phpunit( |$)|paratest'
get_running_procs() {
  if [ -n "${SUITE_INFLIGHT_PS_CMD:-}" ]; then
    eval "$SUITE_INFLIGHT_PS_CMD" 2>/dev/null
  elif [ -n "${DDEV_PROJECT:-}" ] || [ -f /.dockerenv ]; then
    pgrep -af "$PROBE_RE" 2>/dev/null
  elif printf '%s' "$CMD" | grep -qE '(^|[;&|[:space:]])ddev[[:space:]]'; then
    # Host: pgrep would see EVERY container's processes (a pps run would block
    # an lcd cache clear). Probe the target project's own container instead.
    (cd "$CWD" 2>/dev/null && timeout 8 ddev exec "pgrep -af '$PROBE_RE'" 2>/dev/null)
  fi
  # host command not going through ddev: nothing in-container to protect
}

# Exclude this hook's own probe (pgrep's own command line matches its own
# pattern argument), MCP servers, and any line naming the hook itself.
PROCS=$(get_running_procs 2>/dev/null \
  | grep -viE 'pgrep|suite-inflight-guard|playwright-mcp|@playwright/mcp' \
  | grep -iE "$PROBE_RE")

[ -n "$PROCS" ] || exit 0

LINES=$(printf '%s\n' "$PROCS" | head -5 | cut -c1-200)

{
  echo "BLOCKED by suite-inflight-guard.sh: Magento state-churn command while a test suite is running."
  echo ""
  echo "Command:"
  echo "  $CMD"
  echo ""
  echo "Running process(es) that look like an in-flight test suite:"
  printf '%s\n' "$LINES" | sed 's/^/  /'
  echo ""
  echo "Why: cache:clean/cache:flush, setup:upgrade, setup:di:compile,"
  echo "setup:static-content:deploy, config:set, indexer:reindex, and a wipe of"
  echo "pub/static | var/view_preprocessed | var/cache | var/page_cache | generated"
  echo "all mutate state that every in-flight browser session is reading mid-request."
  echo "It produces spurious failures that look like real regressions, not infra noise."
  echo "Origin: an orchestrator ran exactly this during a 4-worker Playwright full"
  echo "suite — 2h46m lost plus 5 remediation batches spent separating real bugs from"
  echo "churn artifacts."
  echo ""
  echo "What to do: wait for the run above to finish, or kill it first if the churn is"
  echo "genuinely needed right now. If that process is actually stale/orphaned (a"
  echo "leftover from a crashed run, not a real in-flight suite), don't kill it and"
  echo "don't just re-run the churn command assuming it's dead — tell the user and let"
  echo "them confirm it's safe to clear."
} >&2
exit 2
