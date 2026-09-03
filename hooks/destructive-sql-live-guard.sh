#!/bin/bash
# PreToolUse Bash hook — gate destructive raw SQL run against LIVE via ssh.
#
# Local/uat DB accidents (ddev exec mysql, local mysql client, bin/magento
# db:query against the local/uat DB) are cheap to recover from — NOT gated
# here, on purpose. Fleet convention: local/uat DB work goes through `ddev
# exec` or a bare local client, never `ssh`; `ssh` to a remote host is how
# LIVE is reached (e.g. ai_assistant's jump host through
# demo.proxiblue.com.au to a client droplet). So "ssh" in the command is
# used as the live signal.
#
# Fires (forces human confirmation) when:
#   1. Command contains an actual `ssh`/`autossh` invocation (live DB is not
#      directly network-reachable in this fleet — ssh is the only path in,
#      confirmed 2026-09-03 — so this is a sound signal, not a heuristic).
#   2. Command contains a raw-SQL-client context (mysql/mariadb/psql/
#      db:query/magerun2) — so unrelated ssh commands (npm update, git
#      rename, etc.) don't false-positive on step 3/4's keywords.
#   3. EITHER a destructive SQL keyword appears (DELETE/DROP/TRUNCATE/
#      UPDATE/ALTER/RENAME TABLE/REPLACE INTO/disabling SQL_SAFE_UPDATES),
#      OR the command imports/streams unreviewed content into the SQL
#      client (`< file.sql`, `< file.dump`, or `cat ... | mysql`) — the
#      hook can't read the file/pipe source to know if it's destructive,
#      so unknown content on live is treated as destructive by default.
#
# Action: permissionDecision "ask" — NOT a hard block. Surfaces an
# interactive confirmation prompt to the human. Unlike merge-guard.sh /
# push-guard.sh, there is deliberately NO bypass env var: auto mode and
# bypassPermissions must not skip this prompt. If you need this changed,
# edit this file — do not try to work around it from inside a session.
#
# Known gaps NOT covered here (regex-on-a-single-command-string ceiling):
#   - Multi-call statement splitting (payload built in one Bash call,
#     executed in a later separate call — this hook is stateless per call).
#   - Destructive SQL living inside a remote script (`ssh host bash x.sh`)
#     rather than in the command string itself.
#   - Non-Bash destructive actions (browser/API against live) — out of
#     scope for a Bash-matcher hook entirely.
#   - Backup verification — this hook can force a human "ask", it cannot
#     confirm a recent backup/snapshot exists. That's a human checklist
#     item, not something regex can enforce.
#
# Defensive: no `set -e`. Silent no-op if jq missing or input unparseable —
# never blocks on infrastructure failure.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null)
[ -z "$CMD" ] && exit 0

# 1. Must contain an actual ssh/autossh invocation (path-prefixed forms like
#    /usr/bin/ssh count too).
echo "$CMD" | grep -qE '(^|[;&|[:space:]/])(ssh|autossh)([[:space:]]|$)' || exit 0

# 2. Must contain a raw-SQL-client context.
echo "$CMD" | grep -qiE '\b(mysql|mariadb|psql|mysqldump|magerun2|db:query)\b' || exit 0

# 3. Destructive keyword, OR unreviewed file/stream import into the client.
DESTRUCTIVE=0
echo "$CMD" | grep -qiE '\b(delete|drop|truncate|update|alter)\b|rename[[:space:]]+table|replace[[:space:]]+into|sql_safe_updates[[:space:]]*=[[:space:]]*0' && DESTRUCTIVE=1
echo "$CMD" | grep -qiE '(mysql|mariadb)[^|;&]*<[[:space:]]*[^[:space:]]+\.(sql|dump)' && DESTRUCTIVE=1
echo "$CMD" | grep -qiE '\|[[:space:]]*(sudo[[:space:]]+)?((ssh|autossh)[^|;&]*[[:space:]])?(mysql|mariadb)\b' && DESTRUCTIVE=1
[ "$DESTRUCTIVE" = "1" ] || exit 0

REASON="Destructive/unreviewed raw SQL over ssh (LIVE) detected — requires explicit human confirmation. Verify a recent backup/snapshot exists before approving: $CMD"

jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: $reason
  }
}'
exit 0
