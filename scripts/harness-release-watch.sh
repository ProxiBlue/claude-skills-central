#!/bin/bash
# Daily harness-release watch — notifies (chatroom, host-auto -> host) when a
# new @anthropic-ai/claude-code version is published, with the changelog delta
# and a cheap headless-claude summary of which TOOLING-SENSITIVE surfaces are
# affected. Lucas directive 2026-08-01.
#
# Why: harness behaviour changes between versions have twice silently broken
# carefully-tuned config (2.1.198 recursive rules auto-load; PostToolUse
# payload model). Fleet pins versions; this watch is the eyes on upstream so
# the pin moves deliberately: alert -> read impact -> run rule-evals.sh ->
# then move the pin.
#
# Usage: harness-release-watch.sh [--dry-run]
# State: ~/monitor/harness-watch/last-seen  (seeded on first run, no alert)

set -u
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

# PATH repair for cron. Cron runs with a minimal PATH (/usr/local/bin:/usr/bin:/bin)
# that omits nvm's node/npm bin and ~/.local/bin (claude). Without this, `npm view`
# failed EVERY run under cron — command-not-found, not a network blip — so the retry
# loop below was useless (all attempts fail identically). See 2026-08-06 alert streak.
if ! command -v npm >/dev/null 2>&1 && [ -s "$HOME/.nvm/nvm.sh" ]; then
  set +u; . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1; set -u
fi
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
export PATH

STATEDIR="$HOME/monitor/harness-watch"; mkdir -p "$STATEDIR"
LAST_FILE="$STATEDIR/last-seen"
CHATROOM_URL="${PB_CHATROOM_REST_URL:-http://127.0.0.1:7476}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

FAIL_FILE="$STATEDIR/npm-fail-count"

# Query upstream with retries (guards genuine registry/DNS blips; the cron PATH
# problem that caused the 2026-08-06 streak is handled by the PATH repair above).
# A single npm/registry/DNS blip is transient noise,
# not an actionable event — so a one-off miss must NOT page you (an rc!=0 here
# fires monitor's "harness failed" email with a cryptic body). Only a PERSISTENT
# failure — the check genuinely not working for days — is worth surfacing.
CUR=""
for attempt in 1 2 3; do
  CUR=$(npm view @anthropic-ai/claude-code version 2>/dev/null)
  [ -n "$CUR" ] && break
  sleep 5
done

if [ -z "$CUR" ]; then
  fails=$(( $(cat "$FAIL_FILE" 2>/dev/null || echo 0) + 1 ))
  echo "$fails" > "$FAIL_FILE"
  if [ "$fails" -ge 3 ]; then
    # 3+ consecutive days down — now it's real, and worded so it means something.
    echo "claude-code upstream version-check has failed $fails runs in a row."
    echo "The npm registry is unreachable from this host (network / npm / DNS)."
    echo "Impact: ONLY the release-watch is blind — no other tooling is broken."
    echo "Check by hand:  npm view @anthropic-ai/claude-code version"
    exit 1
  fi
  # transient (<3): stay quiet. Logged to /tmp/monitor.log, retries tomorrow.
  echo "[$(date -Iseconds)] npm view unavailable (transient, fail ${fails}/3) — no alert"
  exit 0
fi
# success — clear any prior failure streak
rm -f "$FAIL_FILE" 2>/dev/null

if [ ! -f "$LAST_FILE" ]; then
  echo "$CUR" > "$LAST_FILE"
  echo "[$(date -Iseconds)] seeded last-seen=$CUR (no alert on first run)"
  exit 0
fi
LAST=$(cat "$LAST_FILE")
if [ "$CUR" = "$LAST" ]; then
  echo "[$(date -Iseconds)] no new release ($CUR)"
  exit 0
fi

# Changelog delta: sections from CUR down to (exclusive) LAST
CHANGELOG=$(curl -sf https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md || true)
DELTA=$(printf '%s\n' "$CHANGELOG" | awk -v last="## $LAST" '
  $0 == last { exit } { print }' | head -200)
[ -z "$DELTA" ] && DELTA="(changelog fetch failed — review manually: https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md)"

# Impact summary via cheap headless claude
IMPACT_PROMPT=$(mktemp)
cat > "$IMPACT_PROMPT" <<PEOF
Below is the changelog delta for new claude-code releases. Summarize ONLY entries that could affect these tooling surfaces, per surface, one line each; say "no entries affect tooling surfaces" if none do. Surfaces:
- hooks (PreToolUse/PostToolUse firing conditions, payload shape, exit-code semantics)
- CLAUDE.md / .claude/rules loading (include lists, auto-load, paths: frontmatter)
- settings.json schema, permissions model, env handling
- headless/-p behaviour, output formats
- MCP wiring, plugins, marketplaces
- memory / context management

CHANGELOG DELTA ($LAST -> $CUR):
$DELTA
PEOF
IMPACT=$(timeout 120 "$CLAUDE_BIN" -p "$(cat "$IMPACT_PROMPT")" --model haiku --output-format text 2>/dev/null)
rm -f "$IMPACT_PROMPT"
[ -z "$IMPACT" ] && IMPACT="(impact summary unavailable — headless claude failed; read the delta manually)"

BODY=$(mktemp)
{
  PIN=$(jq -r '.fleet_target // "unknown"' "$HOME/claude-skills-central/host/pin-decision.json" 2>/dev/null)
  echo "New claude-code release(s): $LAST -> $CUR (fleet pin: $PIN; host frozen)."
  echo ""
  echo "TOOLING IMPACT (auto-summary):"
  echo "$IMPACT"
  echo ""
  echo "Before moving any pin: bash ~/claude-skills-central/scripts/rule-evals.sh (8/8 required)."
  echo ""
  echo "Raw delta:"
  echo '```'
  echo "$DELTA" | head -80
  echo '```'
} > "$BODY"

if [ "$DRY" = "1" ]; then
  echo "--- DRY RUN: would post 'claude-code $CUR released' ---"
  cat "$BODY"; rm -f "$BODY"; exit 0
fi

curl -sS -X POST "${CHATROOM_URL}/api/threads" \
  -H "Content-Type: application/json" \
  -H "X-PB-Chatroom-Participant: host-auto" \
  -d "$(python3 - "$BODY" "$CUR" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    body = f.read()
print(json.dumps({
    "to": "host",
    "subject": f"claude-code {sys.argv[2]} released — tooling impact summary",
    "body": body,
    "discussion_type": "postmortem",
}))
PYEOF
)" >/dev/null 2>&1 && echo "[$(date -Iseconds)] alert posted ($LAST -> $CUR)"

echo "$CUR" > "$LAST_FILE"
rm -f "$BODY"
