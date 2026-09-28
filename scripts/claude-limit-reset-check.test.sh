#!/usr/bin/env bash
# Tests for claude-limit-reset-check.sh (fixture-driven, no network).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/claude-limit-reset-check.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n  %s\n' "$1" "$2"; fail=1; }
future=$(date -u -d '+20 days' '+%Y-%m-%dT16:00:00+00:00')
past=$(date -u -d '-1 day' '+%Y-%m-%dT16:00:00+00:00')
mk() { # $1 file $2 resets_left $3 ends_at $4 paused $5 use_requires_limit
  cat > "$1" <<JSON
{"five_hour":{"utilization":22.0},"seven_day":{"utilization":85.0},
 "cedar_ember":{"eligible":true,"ineligible_reason":null,"at_limit":false,"exhausted":[],
  "grants":[{"id":"g1","label":"test grant","resets_total":1,"resets_left":$2,
   "starts_at":"2026-09-22T16:00:00+00:00","ends_at":"$3",
   "clears":["five_hour","seven_day"],"paused":$4,"usable_now":true,
   "use_requires_limit":$5,"percent_used":{},"blocking":[]}],
  "next_grant_id":null,"weekly_resets_at":"2026-09-28T08:00:00+00:00","cooldown_until":null}}
JSON
}
run() { LIMIT_RESET_FIXTURE="$1" LIMIT_RESET_CACHE="$T/cache.$RANDOM.json" bash "$S" "${@:2}"; }

mk "$T/avail.json" 1 "$future" false false
out=$(run "$T/avail.json" --line --pct 85)
[[ "$out" == *"reset avail ×1"* && "$out" == *"/limit-reset"* ]] && ok "line: available grant renders token" || bad "line available" "$out"

out=$(run "$T/avail.json" --startup)
printf '%s' "$out" | jq -e '.systemMessage | test("reset available")' >/dev/null && ok "startup: systemMessage present" || bad "startup systemMessage" "$out"
printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null && ok "startup: hookEventName" || bad "startup hookEventName" "$out"
printf '%s' "$out" | jq -e '.systemMessage | test("usable anytime")' >/dev/null && ok "startup: anytime wording" || bad "startup anytime" "$out"

mk "$T/spent.json" 0 "$future" false false
out=$(run "$T/spent.json" --line --pct 85)
[ -z "$out" ] && ok "line: spent grant prints nothing" || bad "line spent" "$out"
out=$(run "$T/spent.json" --startup)
[ -z "$out" ] && ok "startup: spent grant silent" || bad "startup spent" "$out"
out=$(run "$T/spent.json" --refresh)
[[ "$out" == *"no reset available"* && "$out" == *"g1"* ]] && ok "refresh: reports spent grant id" || bad "refresh spent" "$out"

mk "$T/expired.json" 1 "$past" false false
out=$(run "$T/expired.json" --line --pct 85)
[ -z "$out" ] && ok "line: expired grant ignored" || bad "line expired" "$out"

mk "$T/paused.json" 1 "$future" true false
out=$(run "$T/paused.json" --line --pct 85)
[ -z "$out" ] && ok "line: paused grant ignored" || bad "line paused" "$out"

mk "$T/wall.json" 1 "$future" false true
out=$(run "$T/wall.json" --startup)
printf '%s' "$out" | jq -e '.systemMessage | test("usable at limit")' >/dev/null && ok "startup: use_requires_limit wording" || bad "startup at-limit" "$out"

# cache gating: stale cache + low pct must NOT refetch (fixture would flip result)
c="$T/gate.json"
LIMIT_RESET_FIXTURE="$T/spent.json" LIMIT_RESET_CACHE="$c" bash "$S" --refresh >/dev/null
jq '.fetched_at = 0' "$c" > "$c.n" && mv "$c.n" "$c"
out=$(LIMIT_RESET_FIXTURE="$T/avail.json" LIMIT_RESET_CACHE="$c" bash "$S" --line --pct 40)
[ -z "$out" ] && ok "gate: stale cache + weekly<80 stays cache-only" || bad "gate low pct" "$out"
out=$(LIMIT_RESET_FIXTURE="$T/avail.json" LIMIT_RESET_CACHE="$c" bash "$S" --line --pct 80)
[ -n "$out" ] && ok "gate: stale cache + weekly>=80 refetches" || bad "gate high pct" "$out"

# bad fixture must not clobber good cache
LIMIT_RESET_FIXTURE="$T/avail.json" LIMIT_RESET_CACHE="$c" bash "$S" --refresh >/dev/null
printf 'not json' > "$T/bad.json"
out=$(LIMIT_RESET_FIXTURE="$T/bad.json" LIMIT_RESET_CACHE="$c" bash "$S" --refresh)
[[ "$out" == *"reset available"* ]] && ok "bad response keeps last good cache" || bad "bad response" "$out"

exit $fail
