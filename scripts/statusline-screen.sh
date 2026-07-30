#!/usr/bin/env bash
# Push a COMPACT status into the GNU screen window TITLE (%t), so the bottom
# screen status bar shows which project + model/context/limits the current
# `ddev claude` (or host claude) session is at.
#
# Why the title and not %h: screen 4.09.01 does NOT store the APC hardstatus
# sequence (ESC_...ESC\) into %h (verified 2026-07-17 — APC rendered nothing,
# while an OSC/ESC-k title change rendered fine). The window title is the only
# app-settable slot that this screen build honours, and it is already surfaced
# in ~/.screenrc's `hardstatus string` via %t (the left [ ... ] box). We set it
# with screen's native title escape `ESC k <string> ESC \`, written to /dev/tty
# (the real pty) — NOT stdout, which belongs to Claude's own statusline.
#
# The ddev() bash wrapper sets the title to the bare project name when
# `ddev claude` launches and restores the hostname on exit; this script refines
# it to "proj | <status>" on every statusline refresh in between.
#
# Gating: only when TERM looks like screen OR tmux. Works on the host (STY/TMUX
# set) AND inside the ddev container (both unset, but TERM=screen*/tmux*
# propagates through `docker exec -t`, pty routed through the host multiplexer).
# The `ESC k <name> ESC \` title escape below is honored by both screen (%t) and
# tmux (window name; needs `allow-rename on` in ~/.tmux.conf). Host swapped from
# screen -> tmux 2026-07-18; kept screen matching for any lingering screen use.
set -u
export LC_ALL=C

case "${TERM:-}" in
  screen*|tmux*) ;;
  *) exit 0 ;;   # not inside a multiplexer — nothing to push
esac

command -v jq >/dev/null 2>&1 || exit 0
[ -w /dev/tty ] || exit 0

input=$(cat)

IFS=$'\x1f' read -r model ctx_pct rl_pct wk_pct cwd ws_cwd <<< "$(
  printf '%s' "$input" | jq -r '
    [ (.model.display_name // "Claude"),
      (.context_window.used_percentage // ""),
      (.rate_limits.five_hour.used_percentage // ""),
      (.rate_limits.seven_day.used_percentage // ""),
      (.cwd // ""),
      (.workspace.current_dir // "")
    ] | join("")
  ' 2>/dev/null
)"

# Trim "Claude " prefix and any " (1M context)"-style suffix to a short label.
model=${model% (*}
model=${model#Claude }
[ -z "$model" ] && model="Claude"

# Project name: DDEV_PROJECT is authoritative inside the container; fall back to
# the cwd basename on the host.
proj="${DDEV_PROJECT:-}"
if [ -z "$proj" ]; then
  d="$cwd"; [ -z "$d" ] && d="$ws_cwd"; [ -z "$d" ] && d="$PWD"
  proj="${d##*/}"
fi
[ -z "$proj" ] && proj="claude"

round() { # -> ROUND_OUT integer, or empty if not numeric
  ROUND_OUT=""
  [[ $1 =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && printf -v ROUND_OUT '%.0f' "$1"
}

parts="$proj | $model"
round "${ctx_pct:-}"; [ -n "$ROUND_OUT" ] && parts="$parts ctx${ROUND_OUT}%"
round "${rl_pct:-}";  [ -n "$ROUND_OUT" ] && parts="$parts 5h${ROUND_OUT}%"
round "${wk_pct:-}";  [ -n "$ROUND_OUT" ] && parts="$parts 7d${ROUND_OUT}%"

# Set the screen window title (%t). Truncate defensively.
printf '\033k%.100s\033\\' "$parts" > /dev/tty 2>/dev/null || true
