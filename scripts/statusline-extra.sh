#!/usr/bin/env bash
set -u
export LC_ALL=C
command -v jq >/dev/null || exit 0
cols=$( { stty size </dev/tty; } 2>/dev/null | cut -d' ' -f2)
[ -z "${cols:-}" ] && cols=${COLUMNS:-0}
[ "$cols" -le 0 ] && cols=$(tput cols 2>/dev/null || echo 0)
[ "$cols" -le 0 ] && cols=120
WIDE_MIN=100
MED_MIN=60
WK_PACE_TOLERANCE=2
WK_PACE_WARN=12
GIT_CACHE_TTL=2
RESET=$'\033[0m'
DIM=$'\033[2m'
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
MAGENTA=$'\033[35m'
CYAN=$'\033[36m'
ORANGE=$'\033[38;5;208m'
if [ -n "${NO_COLOR:-}" ]; then
  RESET="" DIM="" RED="" GREEN="" YELLOW="" MAGENTA="" CYAN="" ORANGE=""
fi
BARS=('' '█' '██' '███' '████' '█████' '██████' '███████' '████████' '█████████' '██████████')
EMPTIES=('' '░' '░░' '░░░' '░░░░' '░░░░░' '░░░░░░' '░░░░░░░' '░░░░░░░░' '░░░░░░░░░' '░░░░░░░░░░')
NOW=$(date +%s)
input=$(</dev/stdin)
model=""; ctx_pct_raw=""; ctx_total=""; ctx_used_sum="0"
rl_pct_raw=""; rl_reset=""; wk_pct_raw=""; wk_reset=""
cwd=""; ws_cwd=""
IFS=$'\x1f' read -r model ctx_pct_raw ctx_total ctx_used_sum \
  rl_pct_raw rl_reset wk_pct_raw wk_reset \
  cwd ws_cwd <<< "$(
  printf '%s' "$input" | jq -r '
    (.context_window.current_usage // {}) as $u
    | [
        (.model.display_name // ""),
        (.context_window.used_percentage // ""),
        (.context_window.context_window_size // ""),
        (($u.input_tokens // 0) + ($u.output_tokens // 0)
          + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0)),
        (.rate_limits.five_hour.used_percentage // ""),
        (.rate_limits.five_hour.resets_at // ""),
        (.rate_limits.seven_day.used_percentage // ""),
        (.rate_limits.seven_day.resets_at // ""),
        (.cwd // ""),
        (.workspace.current_dir // "")
      ]
    | map(tostring) | join("")
  ' 2>/dev/null
)"
model=${model% (*}
[ -z "$model" ] && model="Claude"
[ -z "$cwd" ] && cwd=$ws_cwd
[ -z "$cwd" ] && cwd=$PWD
[ -z "$ctx_used_sum" ] && ctx_used_sum=0
is_num() { [[ $1 =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }
USAGE_COLOR_OUT=""
usage_color() {
  local pct=$1
  if [ "$pct" -ge 90 ]; then USAGE_COLOR_OUT=$RED
  elif [ "$pct" -ge 75 ]; then USAGE_COLOR_OUT=$YELLOW
  else USAGE_COLOR_OUT=$CYAN
  fi
}
BAR_OUT=""
make_bar() {
  local pct=$1 width=${2:-10} color=${3:-} filled empty
  [ "$pct" -gt 100 ] && pct=100
  [ "$pct" -lt 0 ] && pct=0
  filled=$(( (pct * width + 50) / 100 ))
  [ "$filled" -eq 0 ] && [ "$pct" -gt 0 ] && filled=1
  [ "$filled" -gt "$width" ] && filled=$width
  empty=$(( width - filled ))
  printf -v BAR_OUT '%s%s%s%s%s%s' \
    "$color" "${BARS[$filled]}" "$RESET" "$DIM" "${EMPTIES[$empty]}" "$RESET"
}
FMT_TOKENS_OUT=""
fmt_tokens() {
  local n=$1 whole frac
  if [ "$n" -ge 1000000 ]; then
    whole=$((n/1000000))
    frac=$(((n/100000)%10))
    if [ "$frac" -eq 0 ]; then
      printf -v FMT_TOKENS_OUT '%dM' "$whole"
    else
      printf -v FMT_TOKENS_OUT '%d.%dM' "$whole" "$frac"
    fi
  elif [ "$n" -ge 1000 ]; then
    printf -v FMT_TOKENS_OUT '%dk' "$((n/1000))"
  else
    printf -v FMT_TOKENS_OUT '%d' "$n"
  fi
}
FMT_ETA_OUT=""
fmt_eta() {
  local target=$1 diff d h m
  diff=$(( target - NOW ))
  [ "$diff" -lt 0 ] && diff=0
  d=$(( diff / 86400 ))
  h=$(( (diff % 86400) / 3600 ))
  m=$(( (diff % 3600) / 60 ))
  if [ "$d" -gt 0 ]; then printf -v FMT_ETA_OUT '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf -v FMT_ETA_OUT '%dh %dm' "$h" "$m"
  else printf -v FMT_ETA_OUT '%dm' "$m"
  fi
}
ctx_pct=0
[ -n "$ctx_pct_raw" ] && is_num "$ctx_pct_raw" && printf -v ctx_pct '%.0f' "$ctx_pct_raw"
ctx_color=$GREEN
if [ "$ctx_used_sum" != "0" ]; then
  usage_pct=0
  [ -n "$ctx_total" ] && [ "$ctx_total" -gt 0 ] && usage_pct=$(( ctx_used_sum * 100 / ctx_total ))
  if [ "$usage_pct" -ge 85 ] || [ "$ctx_used_sum" -ge 400000 ]; then ctx_color=$RED
  elif [ "$usage_pct" -ge 75 ] || [ "$ctx_used_sum" -ge 200000 ]; then ctx_color=$YELLOW
  fi
fi
make_bar "$ctx_pct" 10 "$ctx_color"
bar=$BAR_OUT
tokens_str=""
if [ "$ctx_used_sum" != "0" ] && [ -n "$ctx_total" ]; then
  fmt_tokens "$ctx_used_sum"; used_str=$FMT_TOKENS_OUT
  fmt_tokens "$ctx_total"; total_str=$FMT_TOKENS_OUT
  tokens_str=" ${ctx_color}(${used_str}/${total_str})${RESET}"
fi
printf -v ctx_seg '%s %s%d%%%s%s' \
  "$bar" \
  "$ctx_color" "$ctx_pct" "$RESET" \
  "$tokens_str"
printf -v model_seg '%s%s%s' "$CYAN" "$model" "$RESET"
proj=${cwd##*/}
[ -z "$proj" ] && proj="/"
git_seg=""
branch="" dirty_count=0 ahead=0 behind=0
if [ -d "$cwd" ]; then
  git_dir=$(cd "$cwd" 2>/dev/null && git rev-parse --git-dir 2>/dev/null)
  if [ -n "$git_dir" ]; then
    case $git_dir in /*) ;; *) git_dir="$cwd/$git_dir" ;; esac
    cache_key=$(printf '%s' "$cwd" | cksum | cut -d' ' -f1)
    git_cache="${TMPDIR:-/tmp}/statusline-git-${cache_key}"
    use_git_cache=0
    if [ -f "$git_cache" ]; then
      c_exp=""; c_branch=""; c_dirty=0; c_ahead=0; c_behind=0
      IFS=$'\x1f' read -r c_exp c_branch c_dirty c_ahead c_behind < "$git_cache" 2>/dev/null || c_exp=""
      [[ $c_dirty =~ ^[0-9]+$ ]] || c_dirty=0
      [[ $c_ahead =~ ^[0-9]+$ ]] || c_ahead=0
      [[ $c_behind =~ ^[0-9]+$ ]] || c_behind=0
      if [ -n "${c_exp:-}" ] && [[ $c_exp =~ ^[0-9]+$ ]] && [ "$NOW" -lt "$c_exp" ]; then
        use_git_cache=1
        for f in "$git_dir/HEAD" "$git_dir/index"; do
          if [ -f "$f" ] && [ "$f" -nt "$git_cache" ]; then
            use_git_cache=0
            break
          fi
        done
      fi
    fi
    if [ "$use_git_cache" = 1 ]; then
      branch=$c_branch; dirty_count=$c_dirty; ahead=$c_ahead; behind=$c_behind
    else
      IFS=$'\x1f' read -r branch dirty_count ahead behind < <(
        cd "$cwd" || exit
        b=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --abbrev-ref HEAD 2>/dev/null)
        s=$(git status --porcelain 2>/dev/null)
        nl=${s//[!$'\n']/}
        [ -n "$s" ] && d=$(( ${#nl} + 1 )) || d=0
        a=$(git rev-list --count @{u}..HEAD 2>/dev/null)
        bh=$(git rev-list --count HEAD..@{u} 2>/dev/null)
        printf '%s\x1f%s\x1f%s\x1f%s\n' "${b:--}" "$d" "${a:-0}" "${bh:-0}"
      )
      if [ -n "${branch:-}" ] && [ "$branch" != "-" ]; then
        tmp_cache="$git_cache.tmp.$$"
        if printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$((NOW + GIT_CACHE_TTL))" \
          "$branch" "$dirty_count" "$ahead" "$behind" > "$tmp_cache" 2>/dev/null; then
          mv -f "$tmp_cache" "$git_cache" 2>/dev/null || rm -f "$tmp_cache" 2>/dev/null
        fi
      fi
    fi
    if [ -n "${branch:-}" ] && [ "$branch" != "-" ]; then
      marker=""
      [ "$dirty_count" -gt 0 ] && marker="${YELLOW}*${RESET}"
      extras=""
      [ "$ahead" -gt 0 ] && extras="${extras} ${CYAN}↑${ahead}${RESET}"
      [ "$behind" -gt 0 ] && extras="${extras} ${CYAN}↓${behind}${RESET}"
      [ "$dirty_count" -gt 0 ] && extras="${extras} ${CYAN}!${dirty_count}${RESET}"
      git_seg=" ${MAGENTA}${branch}${RESET}${marker}${extras}"
    fi
  fi
fi
printf -v proj_seg '%s%s%s%s' "$GREEN" "$proj" "$RESET" "$git_seg"
usage_seg=""
rl_pct=0
if [ -n "$rl_pct_raw" ] && is_num "$rl_pct_raw"; then
  printf -v rl_pct '%.0f' "$rl_pct_raw"
  usage_color "$rl_pct"; rl_color=$USAGE_COLOR_OUT
  eta=""
  if [ -n "$rl_reset" ]; then
    fmt_eta "$rl_reset"
    eta=" ${DIM}${FMT_ETA_OUT}${RESET}"
  fi
  make_bar "$rl_pct" 10 "$rl_color"
  printf -v usage_seg '5h %s %s%d%%%s%s' "$BAR_OUT" "$rl_color" "$rl_pct" "$RESET" "$eta"
fi
weekly_seg=""
wk_pace=""
wk_pct=0
if [ -n "$wk_pct_raw" ] && is_num "$wk_pct_raw"; then
  printf -v wk_pct '%.0f' "$wk_pct_raw"
  usage_color "$wk_pct"; wk_color=$USAGE_COLOR_OUT
  wk_eta=""
  if [ -n "$wk_reset" ]; then
    fmt_eta "$wk_reset"
    wk_eta=" ${DIM}${FMT_ETA_OUT}${RESET}"
    wk_calc=$(awk -v pct="$wk_pct_raw" -v reset="$wk_reset" -v now="$NOW" \
      -v tol="$WK_PACE_TOLERANCE" -v warn="$WK_PACE_WARN" '
      BEGIN {
        win = 604800
        diff = reset - now
        if (diff <= 0 || diff > win) exit
        elapsed = win - diff
        if (elapsed <= 0) exit
        expected = (elapsed / win) * 100
        delta = pct - expected
        abs_delta = delta < 0 ? -delta : delta
        abs_rounded = int(abs_delta + 0.5)
        if (abs_delta <= tol) stage = "on_pace"
        else if (delta > warn) stage = "over_red"
        else if (delta > 0) stage = "over_yellow"
        else stage = "behind"
        printf "%s %d\n", stage, abs_rounded
      }
    ')
    if [ -n "$wk_calc" ]; then
      read -r wk_stage wk_abs_delta <<< "$wk_calc"
      case "$wk_stage" in
        on_pace) wk_pace="${GREEN}◐ on pace${RESET}" ;;
        over_red) wk_pace="${RED}◐ ${wk_abs_delta}% over${RESET}" ;;
        over_yellow) wk_pace="${YELLOW}◐ ${wk_abs_delta}% over${RESET}" ;;
        behind) wk_pace="${YELLOW}◐ ${wk_abs_delta}% behind${RESET}" ;;
      esac
    fi
  fi
  make_bar "$wk_pct" 10 "$wk_color"
  printf -v weekly_seg '7d %s %s%d%%%s%s' "$BAR_OUT" "$wk_color" "$wk_pct" "$RESET" "$wk_eta"
fi
sep=" ${DIM}|${RESET} "
join_segs() {
  local first=1 s
  for s in "$@"; do
    [ -z "$s" ] && continue
    if [ "$first" -eq 1 ]; then printf '%s' "$s"; first=0
    else printf '%s%s' "$sep" "$s"
    fi
  done
}
if [ "$cols" -ge "$WIDE_MIN" ]; then
  join_segs "$proj_seg" "$ctx_seg" "$model_seg" "$usage_seg" "$weekly_seg" "$wk_pace"
  printf '\n'
elif [ "$cols" -ge "$MED_MIN" ]; then
  join_segs "$proj_seg" "$ctx_seg" "$model_seg"; printf '\n'
  if [ -n "$usage_seg$weekly_seg$wk_pace" ]; then
    join_segs "$usage_seg" "$weekly_seg" "$wk_pace"; printf '\n'
  fi
else
  printf '%s\n' "$proj_seg"
  join_segs "$ctx_seg" "$model_seg"; printf '\n'
  if [ -n "$usage_seg$weekly_seg$wk_pace" ]; then
    join_segs "$usage_seg" "$weekly_seg" "$wk_pace"; printf '\n'
  fi
fi
