#!/bin/bash
# perf-compare.sh — before/after runtime-regression compare from xhgui traces.
#
# The deterministic engine behind AP-1 Phase 3 (post-implementation perf review)
# and Phase 4 (perf-gate). It gates on ONE reliable, framework-agnostic signal:
# `main_wt` (wall time µs) from the xhgui `results` table. (Note: `main_ct` is
# NOT total call count — it is the `main()` node's own count, always 1 — so it
# is deliberately not used. Query-count / hotspot analysis needs the profile
# JSON and lives in the reviewer playbook, xhgui.md Query 3, where judgment
# applies. The gate stays on wall time: cheap, deterministic, no JSON parsing.)
#
# Model: a *baseline* is captured before a change (a watermark timestamp + the
# average wall time for a URL at that moment). A *check* averages only traces
# recorded AFTER the watermark and compares. So "after" is unambiguous: whatever
# you profiled since the baseline was taken.
#
#   perf-compare.sh save-baseline <url-substr>   # snapshot current wall + watermark
#   perf-compare.sh check         <url-substr>   # compare post-watermark traces vs baseline
#   perf-compare.sh gate                         # check every URL in the baseline file
#   perf-compare.sh show                         # print the baseline file
#
# Exit codes (check/gate): 0 = no regression, 1 = regression, 3 = no after-data
# or no baseline (indeterminate — callers FAIL OPEN on 3, never block).
#
# DB access, in order of precedence:
#   $PERF_MYSQL              — full mysql command (tests + non-ddev use this)
#   ddev mysql ... xhgui     — when `ddev` is on PATH and .ddev/ exists
#   mysql -hdb ... xhgui     — in-container fallback (DB reachable at host `db`)
#
# Config (optional): <root>/.claude/perf-gate.json
#   { "wall_pct": 25, "min_wall_ms": 100 }
# Baseline store:     <root>/.claude/perf-baseline.json
#
# Defensive: missing jq/mysql, no data, unparseable input → indeterminate (3),
# never a hard failure. This script only READS the perf DB; it never writes it.

set -u

command -v jq >/dev/null 2>&1 || { echo "perf-compare: jq not found" >&2; exit 3; }

# --- project root + config ---------------------------------------------------
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT=$(pwd)
BASELINE_FILE="${PERF_BASELINE_FILE:-$ROOT/.claude/perf-baseline.json}"
CFG="$ROOT/.claude/perf-gate.json"

WALL_PCT=25; MIN_WALL_MS=100
if [ -f "$CFG" ]; then
  v=$(jq -r '.wall_pct // empty'    "$CFG" 2>/dev/null); [ -n "$v" ] && WALL_PCT="$v"
  v=$(jq -r '.min_wall_ms // empty' "$CFG" 2>/dev/null); [ -n "$v" ] && MIN_WALL_MS="$v"
fi

# --- mysql command resolution ------------------------------------------------
resolve_mysql() {
  if [ -n "${PERF_MYSQL:-}" ]; then echo "$PERF_MYSQL"; return; fi
  if command -v ddev >/dev/null 2>&1 && [ -d "$ROOT/.ddev" ]; then
    echo "ddev mysql -uroot -proot xhgui"; return
  fi
  echo "mysql -hdb -uroot -proot xhgui"
}
MYSQL=$(resolve_mysql)

run_sql() {  # $1 = SQL; prints tab-separated rows, no header
  # shellcheck disable=SC2086
  $MYSQL -N -e "$1" 2>/dev/null
}

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# --- helpers -----------------------------------------------------------------
# Average wall_ms for URLs matching a substring, only traces with request_ts >
# a watermark. Emits: simple_url \t wall_ms \t n \t max_ts
agg_for() {  # $1 = url substring, $2 = min_ts (0 for all)
  local like ts
  like=$(sql_escape "$1"); ts="${2:-0}"
  run_sql "SELECT simple_url,
                  ROUND(AVG(main_wt)/1000,1),
                  COUNT(*),
                  MAX(request_ts)
           FROM results
           WHERE simple_url LIKE '%${like}%'
             AND simple_url LIKE '/%'
             AND request_ts > ${ts}
           GROUP BY simple_url
           ORDER BY AVG(main_wt) DESC"
}

pct_delta() {  # $1 = before, $2 = after -> integer percent (rounded), 0 if before<=0
  awk -v b="$1" -v a="$2" 'BEGIN{ if (b+0<=0){print 0} else {printf "%d", (a-b)/b*100 } }'
}

# --- commands ----------------------------------------------------------------
cmd_save_baseline() {
  local url="$1" rows any=0
  [ -z "$url" ] && { echo "usage: perf-compare.sh save-baseline <url-substr>" >&2; exit 2; }
  rows=$(agg_for "$url" 0)
  [ -z "$rows" ] && { echo "perf-compare: no traces match '$url' — profile the page first (ddev xhprof on; exercise it)." >&2; exit 3; }
  mkdir -p "$(dirname "$BASELINE_FILE")"
  [ -f "$BASELINE_FILE" ] || echo '{}' > "$BASELINE_FILE"
  local now; now=$(date +%s 2>/dev/null || echo 0)
  while IFS=$'\t' read -r surl wall n maxts; do
    [ -z "$surl" ] && continue
    any=1
    local tmp; tmp=$(mktemp)
    jq --arg u "$surl" --argjson w "$wall" \
       --argjson n "$n" --argjson ts "${maxts:-0}" --argjson cap "$now" \
       '.[$u] = {wall_ms:$w, traces:$n, watermark_ts:$ts, captured_at:$cap}' \
       "$BASELINE_FILE" > "$tmp" && mv "$tmp" "$BASELINE_FILE"
    printf 'baselined %-40s wall=%sms (n=%s)\n' "$surl" "$wall" "$n"
  done <<< "$rows"
  [ "$any" = "0" ] && exit 3
  echo "→ $BASELINE_FILE"
}

# Compare one baseline entry against post-watermark traces. Echoes a report line,
# returns 0 ok / 1 regression / 3 no-after-data.
check_one() {
  local surl="$1"
  local b_wall wm
  b_wall=$(jq -r --arg u "$surl" '.[$u].wall_ms // empty' "$BASELINE_FILE" 2>/dev/null)
  wm=$(jq -r --arg u "$surl" '.[$u].watermark_ts // 0' "$BASELINE_FILE" 2>/dev/null)
  [ -z "$b_wall" ] && { printf '  %-40s no baseline\n' "$surl"; return 3; }
  local row; row=$(agg_for "$surl" "$wm" | awk -F'\t' -v u="$surl" '$1==u{print; exit}')
  if [ -z "$row" ]; then
    printf '  %-40s baseline wall=%sms — NO new traces (re-profile to check)\n' "$surl" "$b_wall"
    return 3
  fi
  local a_wall; a_wall=$(echo "$row" | cut -f2)
  local dw; dw=$(pct_delta "$b_wall" "$a_wall")
  local verdict="ok" rc=0
  # Only a meaningful regression if the page is above the noise floor.
  local over_floor; over_floor=$(awk -v a="$a_wall" -v f="$MIN_WALL_MS" 'BEGIN{print (a+0>=f+0)?1:0}')
  if [ "$over_floor" = "1" ] && [ "$dw" -gt "$WALL_PCT" ]; then verdict="REGRESSION"; rc=1; fi
  printf '  %-40s wall %sms→%sms (%+d%%)  [%s]\n' "$surl" "$b_wall" "$a_wall" "$dw" "$verdict"
  return $rc
}

cmd_check() {
  local url="${1:-}"
  [ -f "$BASELINE_FILE" ] || { echo "perf-compare: no baseline ($BASELINE_FILE). Run save-baseline first." >&2; exit 3; }
  local urls
  if [ -n "$url" ]; then
    urls=$(jq -r --arg u "$url" 'keys[] | select(contains($u))' "$BASELINE_FILE" 2>/dev/null)
  else
    urls=$(jq -r 'keys[]' "$BASELINE_FILE" 2>/dev/null)
  fi
  [ -z "$urls" ] && { echo "perf-compare: nothing in baseline matches '${url:-*}'." >&2; exit 3; }
  local worst=3
  echo "perf regression check (threshold: wall +${WALL_PCT}%, floor ${MIN_WALL_MS}ms)"
  while IFS= read -r surl; do
    [ -z "$surl" ] && continue
    check_one "$surl"; local rc=$?
    if [ "$rc" = "1" ]; then worst=1
    elif [ "$rc" = "0" ] && [ "$worst" != "1" ]; then worst=0
    fi
  done <<< "$urls"
  exit $worst
}

case "${1:-}" in
  save-baseline) shift; cmd_save_baseline "${1:-}" ;;
  check)         shift; cmd_check "${1:-}" ;;
  gate)          cmd_check "" ;;
  show)          [ -f "$BASELINE_FILE" ] && jq . "$BASELINE_FILE" || echo "no baseline: $BASELINE_FILE" ;;
  *) echo "usage: perf-compare.sh {save-baseline <url>|check [url]|gate|show}" >&2; exit 2 ;;
esac
