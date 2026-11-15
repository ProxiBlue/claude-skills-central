#!/bin/bash
# Daily HCF upstream watch — alerts (chatroom, host-auto -> host) when the
# upstream HCF plugin (github.com/markshust/hcf) has released a version newer
# than the fleet's manually-synced mirror, and keeps nudging while the mirror
# stays behind. Lucas directive 2026-11-15.
#
# Why: the mirror in claude-plugins-central/seed/marketplaces/hcf is synced by
# hand and carries local patches (PROXIBLUE-PATCHES.md). Nothing watched
# upstream, so on 2026-11-15 the mirror was found at 2.0.1 against upstream
# 2.4.0 — four minors behind, discovered only because upstream's author asked
# about a TDD-verification change. A sync that crosses many releases is far
# costlier than one that crosses a single release.
#
# Compares RELEASED versions only (plugin.json on upstream main). Changes that
# are merged but unreleased are listed in the alert as a heads-up and never
# trigger one on their own.
#
# Usage: hcf-upstream-watch.sh [--dry-run]
# State: ~/monitor/hcf-watch/last-alert   "<upstream-version>\t<epoch>" of the last alert
#        ~/monitor/hcf-watch/fetch-fail-count
# Env:   HCF_MIRROR_DIR, HCF_UPSTREAM_RAW (base URL of raw upstream files),
#        HCF_RENUDGE_DAYS (default 14), CLAUDE_BIN, PB_CHATROOM_REST_URL

set -u
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

# cron PATH omits ~/.local/bin (claude) — same repair as harness-release-watch.sh
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
export PATH

MIRROR="${HCF_MIRROR_DIR:-$HOME/claude-plugins-central/seed/marketplaces/hcf}"
UPSTREAM_RAW="${HCF_UPSTREAM_RAW:-https://raw.githubusercontent.com/markshust/hcf/main}"
RENUDGE_DAYS="${HCF_RENUDGE_DAYS:-14}"
STATEDIR="$HOME/monitor/hcf-watch"; mkdir -p "$STATEDIR"
LAST_FILE="$STATEDIR/last-alert"
FAIL_FILE="$STATEDIR/fetch-fail-count"
CHATROOM_URL="${PB_CHATROOM_REST_URL:-http://127.0.0.1:7476}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
NOW=$(date +%s)

# --- mirror version (a missing mirror is a real config fault, not a blip) -----
MIRROR_VER=$(jq -r '.version // empty' "$MIRROR/.claude-plugin/plugin.json" 2>/dev/null)
if [ -z "$MIRROR_VER" ]; then
  echo "HCF mirror version unreadable: $MIRROR/.claude-plugin/plugin.json"
  echo "Impact: ONLY the HCF upstream watch is blind — the plugin itself is untouched."
  exit 1
fi

# --- upstream version, with retries; a one-off network miss must not page -----
UP_VER=""
for attempt in 1 2 3; do
  UP_VER=$(curl -sf --max-time 20 "$UPSTREAM_RAW/.claude-plugin/plugin.json" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
  [ -n "$UP_VER" ] && break
  [ "$attempt" -lt 3 ] && sleep "${HCF_RETRY_SLEEP:-5}"
done
if [ -z "$UP_VER" ]; then
  fails=$(( $(cat "$FAIL_FILE" 2>/dev/null || echo 0) + 1 ))
  echo "$fails" > "$FAIL_FILE"
  if [ "$fails" -ge 3 ]; then
    echo "HCF upstream version-check has failed $fails runs in a row."
    echo "Upstream plugin.json is unreachable (network / GitHub / repo moved or went private)."
    echo "Impact: ONLY the HCF upstream watch is blind — no other tooling is broken."
    echo "Check by hand:  curl -sf $UPSTREAM_RAW/.claude-plugin/plugin.json"
    exit 1
  fi
  echo "[$(date -Iseconds)] upstream plugin.json unavailable (transient, fail ${fails}/3) — no alert"
  exit 0
fi
rm -f "$FAIL_FILE" 2>/dev/null

# --- behind? ------------------------------------------------------------------
is_newer() {  # is $1 newer than $2
  python3 -c 'import re,sys
t=lambda v: tuple(int(x) for x in re.findall(r"\d+", v)[:3])
sys.exit(0 if t(sys.argv[1]) > t(sys.argv[2]) else 1)' "$1" "$2"
}
if ! is_newer "$UP_VER" "$MIRROR_VER"; then
  rm -f "$LAST_FILE" 2>/dev/null
  echo "[$(date -Iseconds)] HCF mirror current (mirror $MIRROR_VER, upstream $UP_VER)"
  exit 0
fi

RENUDGE=0
if [ -f "$LAST_FILE" ]; then
  LAST_VER=$(cut -f1 "$LAST_FILE"); LAST_AT=$(cut -f2 "$LAST_FILE")
  AGE_DAYS=$(( (NOW - ${LAST_AT:-0}) / 86400 ))
  if [ "$LAST_VER" = "$UP_VER" ]; then
    if [ "$AGE_DAYS" -lt "$RENUDGE_DAYS" ]; then
      echo "[$(date -Iseconds)] HCF mirror behind (mirror $MIRROR_VER < upstream $UP_VER) — alerted ${AGE_DAYS}d ago, next nudge at ${RENUDGE_DAYS}d"
      exit 0
    fi
    RENUDGE=1
  fi
fi

# --- changelog delta: every released section newer than the mirror -------------
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
curl -sf --max-time 30 "$UPSTREAM_RAW/CHANGELOG.md" > "$WORK/changelog.md" 2>/dev/null || : > "$WORK/changelog.md"
python3 - "$WORK/changelog.md" "$MIRROR_VER" "$WORK" "$MIRROR/CHANGELOG.md" <<'PYEOF'
import re, sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text(errors="replace")
mirror = tuple(int(x) for x in re.findall(r"\d+", sys.argv[2])[:3])
out = pathlib.Path(sys.argv[3])
split = lambda t: [(m.group(1), s) for s in re.split(r"(?m)^(?=## \[)", t) for m in [re.match(r"## \[([^\]]+)\]", s)] if m]
sections = split(text)
newer, delta, unreleased = [], [], ""
# Mirror changelog sections for versions upstream never released = local changes
# that a copy-over sync would silently drop (PROXIBLUE-PATCHES.md may not list them all).
upstream_names = {n for n, _ in sections}
try:
    local = [s.rstrip() for n, s in split(pathlib.Path(sys.argv[4]).read_text(errors="replace"))
             if n.lower() != "unreleased" and n not in upstream_names] if upstream_names else []
except OSError:
    local = []
(out / "local").write_text("\n\n".join(local))
for name, s in sections:
    if name.lower() == "unreleased":
        body = s.split("\n", 1)[1].strip() if "\n" in s else ""
        unreleased = body
        continue
    ver = tuple(int(x) for x in re.findall(r"\d+", name)[:3])
    if ver > mirror:
        newer.append(name)
        delta.append(s.rstrip())
(out / "newer").write_text(" ".join(newer))
(out / "delta").write_text("\n\n".join(delta))
(out / "unreleased").write_text(unreleased)
PYEOF
NEWER=$(cat "$WORK/newer" 2>/dev/null)
COUNT=$(printf '%s' "$NEWER" | wc -w)
DELTA=$(cat "$WORK/delta" 2>/dev/null)
UNRELEASED=$(cat "$WORK/unreleased" 2>/dev/null)
[ -z "$DELTA" ] && DELTA="(changelog fetch/parse failed — review manually: https://github.com/markshust/hcf/blob/main/CHANGELOG.md)"

# --- sync-impact summary (reporter work: sonnet, per rules/model-tiering.md) ---
PATCHES=$(cat "$MIRROR/PROXIBLUE-PATCHES.md" 2>/dev/null || echo "(PROXIBLUE-PATCHES.md missing)")
LOCAL_CL=$(cat "$WORK/local" 2>/dev/null)
[ -z "$LOCAL_CL" ] && LOCAL_CL="(none)"
PROMPT="$WORK/prompt"
cat > "$PROMPT" <<PEOF
Below is (1) the local patches a team keeps on its hand-synced mirror of the HCF Claude Code plugin — its patch notes plus the mirror's own changelog entries for versions upstream never released, which are also local changes — and (2) the upstream changelog for every release newer than the mirror. A sync = copy upstream over the mirror, then re-apply the local patches.

Write a short sync-impact summary, plain text, no preamble:
- one line per upstream release: what changed that matters operationally
- then "Patch collisions:" — which local patches touch files or behaviour the upstream changes also touch (name the file); "none found" if none
- then "New requirements:" — new dependencies, hooks, config files or migration steps; "none found" if none
Use only what the text below states. Do not guess at changes it does not mention.

LOCAL PATCHES (patch notes):
$PATCHES

LOCAL PATCHES (mirror-only changelog entries):
$(printf '%s\n' "$LOCAL_CL" | head -60)

UPSTREAM CHANGELOG (mirror $MIRROR_VER -> upstream $UP_VER):
$(printf '%s\n' "$DELTA" | head -250)
PEOF
IMPACT=$(timeout 180 "$CLAUDE_BIN" -p "$(cat "$PROMPT")" --model sonnet --output-format text 2>/dev/null)
[ -z "$IMPACT" ] && IMPACT="(impact summary unavailable — headless claude failed; read the changelog below)"

BODY="$WORK/body"
{
  if [ "$RENUDGE" = "1" ]; then
    echo "REMINDER: HCF mirror still behind upstream, ${AGE_DAYS} days after the first alert."
  else
    echo "HCF upstream has released ahead of the fleet mirror."
  fi
  echo ""
  echo "Mirror:   $MIRROR_VER  ($MIRROR)"
  echo "Upstream: $UP_VER  (https://github.com/markshust/hcf)"
  echo "Behind by $COUNT release(s): $NEWER"
  echo ""
  echo "SYNC IMPACT (auto-summary):"
  echo "$IMPACT"
  echo ""
  echo "To sync: copy upstream over the mirror, re-apply PROXIBLUE-PATCHES.md, run its verify grep, then trial on one project before the fleet."
  if [ -n "$UNRELEASED" ]; then
    echo ""
    echo "Merged upstream but not yet released (heads-up only):"
    echo '```'
    printf '%s\n' "$UNRELEASED" | head -30
    echo '```'
  fi
} > "$BODY.head"
# pb-chatroom rejects a body over 10,000 chars (HTTP 422). The summary is the part
# worth reading, so it keeps priority; the raw changelog takes whatever room is left.
printf '%s\n' "$DELTA" > "$WORK/delta.full"
python3 - "$BODY.head" "$WORK/delta.full" "$BODY" <<'PYEOF'
import sys, pathlib
LIMIT, HEAD_MAX = 9500, 7000
URL = "https://github.com/markshust/hcf/blob/main/CHANGELOG.md"
head = pathlib.Path(sys.argv[1]).read_text(errors="replace").rstrip()
delta = pathlib.Path(sys.argv[2]).read_text(errors="replace").strip()
if len(head) > HEAD_MAX:
    head = head[:HEAD_MAX].rsplit("\n", 1)[0] + "\n… (summary truncated)"
intro, fence = "\n\nChangelog since mirror:\n```\n", "\n```\n"
note = f"\n… (truncated — full changelog: {URL})"
room = LIMIT - len(head) - len(intro) - len(fence)
if len(delta) > room:
    delta = delta[:max(room - len(note), 0)].rsplit("\n", 1)[0] + note
pathlib.Path(sys.argv[3]).write_text(head + intro + delta + fence)
PYEOF

if [ "$RENUDGE" = "1" ]; then
  SUBJECT="HCF upstream $UP_VER — mirror STILL at $MIRROR_VER ($COUNT releases behind, ${AGE_DAYS}d)"
else
  SUBJECT="HCF upstream $UP_VER released — mirror at $MIRROR_VER ($COUNT releases behind)"
fi

if [ "$DRY" = "1" ]; then
  echo "--- DRY RUN: would post '$SUBJECT' ---"
  cat "$BODY"; exit 0
fi

HTTP=$(curl -sS --max-time 20 -o "$WORK/resp" -w '%{http_code}' -X POST "${CHATROOM_URL}/api/threads" \
  -H "Content-Type: application/json" \
  -H "X-PB-Chatroom-Participant: host-auto" \
  -d "$(python3 - "$BODY" "$SUBJECT" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    body = f.read()
print(json.dumps({
    "to": "host",
    "subject": sys.argv[2],
    "body": body,
    "discussion_type": "postmortem",
}))
PYEOF
)" 2>/dev/null)
THREAD_ID=$(python3 -c "import sys,json
try: print(json.load(open(sys.argv[1])).get('id',''))
except Exception: print('')" "$WORK/resp" 2>/dev/null)

if [ -z "$THREAD_ID" ]; then
  # Do NOT record the alert as sent: state stays untouched so the next run retries.
  echo "HCF upstream watch: mirror $MIRROR_VER is behind upstream $UP_VER ($COUNT releases) but the chatroom post failed."
  if [ "${HTTP:-000}" = "000" ]; then
    echo "Chatroom unreachable at $CHATROOM_URL — alert not delivered, will retry next run."
  else
    echo "Chatroom rejected the post (HTTP $HTTP): $(head -c 200 "$WORK/resp" 2>/dev/null) — alert not delivered, will retry next run."
  fi
  exit 1
fi
echo "[$(date -Iseconds)] alert posted (mirror $MIRROR_VER -> upstream $UP_VER, $COUNT releases behind) thread $THREAD_ID"

# Each alert is a snapshot of the current gap; older ones are superseded.
RETIRE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/chatroom-retire-superseded.sh"
[ -x "$RETIRE" ] && { "$RETIRE" "HCF upstream " "$THREAD_ID" || true; }

printf '%s\t%s\n' "$UP_VER" "$NOW" > "$LAST_FILE"
