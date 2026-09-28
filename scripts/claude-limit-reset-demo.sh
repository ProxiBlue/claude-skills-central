#!/usr/bin/env bash
# Launch Claude Code with a FAKE "reset available" grant so you can see the
# SessionStart banner + statusline segment end-to-end. Uses a throwaway cache
# path; the real ~/.cache/claude-limit-reset/ is untouched. Never claims anything.
set -eu
T="${TMPDIR:-/tmp}/claude-limit-reset-demo"
mkdir -p "$T"
cat > "$T/fixture.json" <<'J'
{"five_hour":{"utilization":22.0},"seven_day":{"utilization":85.0},
 "cedar_ember":{"eligible":true,"ineligible_reason":null,"at_limit":false,"exhausted":[],
  "grants":[{"id":"demo","label":"demo grant","resets_total":1,"resets_left":1,
   "starts_at":"2026-09-22T16:00:00+00:00","ends_at":"2026-10-22T16:00:00+00:00",
   "clears":["five_hour","seven_day"],"paused":false,"usable_now":true,
   "use_requires_limit":false,"percent_used":{},"blocking":[]}],
  "next_grant_id":null,"weekly_resets_at":"2026-09-28T08:00:00+00:00","cooldown_until":null}}
J
rm -f "$T/cache.json"
echo "demo: expect banner 'Usage-limit reset available: 1 left ...' + magenta '⟲ reset avail ×1' in statusline"
LIMIT_RESET_FIXTURE="$T/fixture.json" LIMIT_RESET_CACHE="$T/cache.json" exec claude "$@"
