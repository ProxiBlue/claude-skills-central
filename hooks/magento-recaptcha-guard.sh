#!/bin/bash
# PreToolUse hook (Edit|Write|Bash|database MCP) — reCAPTCHA stays on in every env.
#
# Origin incident (chatroom thread 7808dbfe, LaptopLCDScreen #448, 2026-11-09;
# same class previously on pvcpipesupplies): env.dev.php + env.uat.php had
# reCAPTCHA off for customer_login / customer_create while live had v3 on. A
# token-script change broke customer registration on live for ~5 days. Every
# Playwright test passed, because DDEV forms had no reCAPTCHA at all and the one
# test touching it skipped itself. Owner: "we must ensure it is same same. always."
#
# Blocks, in any environment:
#   Edit/Write app/etc/env*.php or app/etc/config.php when the resulting file
#     newly disables a form (null / '' / 0 / false / empty) under
#     recaptcha_frontend|backend/type_for, REMOVES a form that was on, or sets a
#     Magento_ReCaptcha* module to 0. Compared against the current file, so an
#     unrelated edit to a file that is already wrong is not blocked.
#   Edit/Write PHP under */Setup/* that deletes or blanks a recaptcha_* path.
#   Bash: config:set / config:store:set with an off value, config:delete /
#     config:store:delete, security:recaptcha:disable-for-user-*,
#     module:disable Magento_ReCaptcha*, direct writes to env files that mention
#     reCAPTCHA, and core_config_data writes that delete or blank recaptcha_*.
#   Database MCP tools: the same core_config_data writes.
#
# Setting a real type (recaptcha_v3 etc.), keys, score thresholds and
# recaptcha_frontend/test_mode/token all pass. Tests pass reCAPTCHA with the
# test-token pattern; they do not avoid it. See skills/recaptcha-env-parity.
#
# Known gap: a path built from constants or concatenation in a data patch.
# EnvFileParityTest is the backstop for anything that reaches the env files.
#
# Opt out per project: a line `magento-recaptcha-guard` in .claude/rules-disable.
# User-only escape: export CLAUDE_RECAPTCHA_DISABLE_ALLOWED=1 before starting
# claude. There is deliberately no in-session bypass.
#
# Defensive: no set -e. jq missing / unparseable input → silent no-op.

[ "${CLAUDE_RECAPTCHA_DISABLE_ALLOWED:-0}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // "Bash"' 2>/dev/null)
[ -n "$TOOL" ] || exit 0

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD=$(pwd)
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
case "$FILE" in
  "") ;;
  /*) ;;
  *) FILE="$CWD/$FILE" ;;
esac

ROOT_FROM="$CWD"
[ -n "$FILE" ] && ROOT_FROM=$(dirname "$FILE")
ROOT=$(cd "$ROOT_FROM" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$ROOT" ] && [ -f "$ROOT/.claude/rules-disable" ]; then
  grep -qx 'magento-recaptcha-guard' "$ROOT/.claude/rules-disable" 2>/dev/null && exit 0
fi

rcg_block() {
  {
    echo "BLOCKED by magento-recaptcha-guard.sh: this would disable reCAPTCHA."
    echo ""
    echo "What tripped: $1"
    echo ""
    echo "reCAPTCHA stays on in every environment (LaptopLCDScreen #448: it was off in"
    echo "DDEV/UAT, a broken register form passed every test and hit live for ~5 days)."
    echo ""
    echo "If a test cannot get past reCAPTCHA, do not turn it off. Use the test token:"
    echo "  recaptcha_frontend/test_mode/token in the non-live env files, the"
    echo "  RecaptchaTestMode plugin, and the Playwright grecaptcha stub."
    echo "  See skills/recaptcha-env-parity in claude-skills-central."
    echo ""
    echo "If reCAPTCHA genuinely must change, STOP and ask the user. Do not re-shape"
    echo "this command to evade the guard."
  } >&2
  exit 2
}

# Flatten a PHP array file to "path<TAB>value", keeping only reCAPTCHA paths.
# A tokenizer, not line regexes, so one-line arrays and any layout work.
# Values: s:<string>, b:<lowercased bareword>, EMPTY for an empty array.
rcg_flatten() {
  awk '
    function here(  i, p) {
      p = ""
      for (i = 2; i <= d; i++) p = p (p == "" ? "" : "/") st[i]
      return p
    }
    function emit(p, v) {
      if (p ~ /recaptcha_(frontend|backend)|^modules\/Magento_ReCaptcha/) print p "\t" v
    }
    function flush(  p) {
      if (hk && hv) {
        kids[d]++
        p = here()
        emit((p == "" ? "" : p "/") k, val)
      }
      hk = 0; hv = 0; val = ""
    }
    BEGIN { d = 0; hk = 0; hv = 0; inc = 0 }
    {
      s = $0
      while (s != "") {
        if (inc) {
          i = index(s, "*/")
          if (!i) { s = ""; break }
          s = substr(s, i + 2); inc = 0; continue
        }
        c = substr(s, 1, 1); two = substr(s, 1, 2)
        if (c == " " || c == "\t" || c == "\r") { s = substr(s, 2); continue }
        if (two == "/*") { inc = 1; s = substr(s, 3); continue }
        if (two == "//" || c == "#") break
        if (two == "=>") { hk = hv; k = substr(val, 3); hv = 0; val = ""; s = substr(s, 3); continue }
        if (c == "[" || tolower(substr(s, 1, 6)) == "array(") {
          kids[d]++; d++
          st[d] = (hk ? k : "#"); op[d] = (c == "[" ? "[" : "("); kids[d] = 0
          hk = 0; hv = 0; val = ""
          s = substr(s, (c == "[" ? 2 : 7)); continue
        }
        if ((c == "]" && op[d] == "[") || (c == ")" && op[d] == "(")) {
          flush()
          if (kids[d] == 0 && d > 1) emit(here(), "EMPTY")
          d--; s = substr(s, 2); continue
        }
        if (c == ",") { flush(); s = substr(s, 2); continue }
        if (c == "\047" || c == "\"") {
          n = length(s); e = 0
          for (i = 2; i <= n; i++) {
            x = substr(s, i, 1)
            if (x == "\\") { i++; continue }
            if (x == c) { e = i; break }
          }
          if (!e) e = n
          val = "s:" substr(s, 2, e - 2); hv = 1
          s = substr(s, e + 1); continue
        }
        if (match(s, /^[A-Za-z0-9_.:-]+/)) {
          val = "b:" tolower(substr(s, 1, RLENGTH)); hv = 1
          s = substr(s, RLENGTH + 1); continue
        }
        s = substr(s, 2)
      }
    }
  '
}

RCG_OFF='$2=="b:null"||$2=="s:"||$2=="b:0"||$2=="s:0"||$2=="b:false"||$2=="EMPTY"'

rcg_disabled() {
  awk -F'\t' "
    (\$1 ~ /recaptcha_(frontend|backend)\\/type_for\\// || \$1 ~ /recaptcha_(frontend|backend)(\\/type_for)?\$/) && ($RCG_OFF) { print \$1; next }
    \$1 ~ /^modules\\/Magento_ReCaptcha/ && (\$2==\"b:0\"||\$2==\"s:0\"||\$2==\"b:false\") { print \$1 }
  " | LC_ALL=C sort -u
}

rcg_active() {
  awk -F'\t' "\$1 ~ /recaptcha_(frontend|backend)\\/type_for\\// && !($RCG_OFF) { print \$1 }" | LC_ALL=C sort -u
}

rcg_keys() { cut -f1 | LC_ALL=C sort -u; }

rcg_check_sql() {
  local sql="$1"
  printf '%s' "$sql" | grep -qiE 'core_config_data' || return 0
  printf '%s' "$sql" | grep -qiE 'recaptcha_(frontend|backend)' || return 0
  if printf '%s' "$sql" | grep -qiE 'delete[[:space:]]+from'; then
    rcg_block "SQL DELETE of recaptcha_* rows in core_config_data"
  fi
  if printf '%s' "$sql" | grep -qiE "value[\`\"]?[[:space:]]*=[[:space:]]*(null|''|\"\"|'0'|0)([^0-9a-z_]|\$)"; then
    rcg_block "SQL UPDATE blanking recaptcha_* in core_config_data"
  fi
  if printf '%s' "$sql" | grep -qiE "(insert|replace)[[:space:]]" \
    && printf '%s' "$sql" | grep -qiE "recaptcha_(frontend|backend)[^,)]*['\"][[:space:]]*,[[:space:]]*(null|''|\"\"|'0'|0)([^0-9a-z_]|\$)"; then
    rcg_block "SQL INSERT/REPLACE blanking recaptcha_* in core_config_data"
  fi
  return 0
}

# --- Edit / Write -----------------------------------------------------------
if [ "$TOOL" = "Edit" ] || [ "$TOOL" = "Write" ]; then
  [ -n "$FILE" ] || exit 0

  case "$FILE" in
    */app/etc/env*.php|*/app/etc/config.php)
      PRE_FILE="$FILE"
      [ -r "$PRE_FILE" ] || PRE_FILE=/dev/null
      if [ "$TOOL" = "Write" ]; then
        POST=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // ""' 2>/dev/null)
      else
        POST=$(printf '%s' "$INPUT" | jq -r --rawfile pre "$PRE_FILE" '
          (.tool_input.old_string // "") as $o
          | (.tool_input.new_string // "") as $n
          | if $o == "" then $pre
            elif (.tool_input.replace_all // false) then ($pre | split($o) | join($n))
            else ($pre | split($o)) as $p
              | if ($p | length) < 2 then $pre
                else $p[0] + $n + ($p[1:] | join($o)) end
            end' 2>/dev/null)
      fi
      PRE_FLAT=$(rcg_flatten < "$PRE_FILE")
      POST_FLAT=$(printf '%s\n' "$POST" | rcg_flatten)

      NEWLY_OFF=$(LC_ALL=C comm -13 \
        <(printf '%s\n' "$PRE_FLAT" | rcg_disabled) \
        <(printf '%s\n' "$POST_FLAT" | rcg_disabled) | grep -v '^$')
      REMOVED=$(LC_ALL=C comm -23 \
        <(printf '%s\n' "$PRE_FLAT" | rcg_active) \
        <(printf '%s\n' "$POST_FLAT" | rcg_keys) | grep -v '^$')

      [ -n "$NEWLY_OFF" ] && rcg_block "$(basename "$FILE") disables: $(printf '%s' "$NEWLY_OFF" | tr '\n' ' ')"
      [ -n "$REMOVED" ] && rcg_block "$(basename "$FILE") removes: $(printf '%s' "$REMOVED" | tr '\n' ' ')"
      exit 0
      ;;
    */Test/*) exit 0 ;;
    */Setup/*.php)
      TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // ""' 2>/dev/null | tr '\n' ' ')
      printf '%s' "$TEXT" | grep -qE 'recaptcha_(frontend|backend)' || exit 0
      if printf '%s' "$TEXT" | grep -qE "deleteConfig[[:space:]]*\([[:space:]]*['\"]recaptcha_(frontend|backend)"; then
        rcg_block "$(basename "$FILE") deletes a recaptcha_* config path"
      fi
      if printf '%s' "$TEXT" | grep -qiE "recaptcha_(frontend|backend)/[a-z0-9_/]*['\"][[:space:]]*,[[:space:]]*(null|''|\"\"|'0'|0|false)[[:space:]]*[,)]"; then
        rcg_block "$(basename "$FILE") blanks a recaptcha_* config path"
      fi
      rcg_check_sql "$TEXT"
      exit 0
      ;;
  esac
  exit 0
fi

# --- Database MCP tools -----------------------------------------------------
case "$TOOL" in
  mcp__*)
    SQL=$(printf '%s' "$INPUT" | jq -r '.tool_input.query // .tool_input.sql // .tool_input.statement // ""' 2>/dev/null)
    [ -n "$SQL" ] && rcg_check_sql "$SQL"
    exit 0
    ;;
esac

[ "$TOOL" = "Bash" ] || exit 0
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null)
[ -n "$CMD" ] || exit 0

# Command-position walk, same approach as magento-config-dump-guard.sh: only a
# real magento invocation counts, so `grep "config:delete" docs/` passes.
rcg__segment_magento_args() {
  local depth=0 t base
  while [ $# -gt 0 ] && [ $depth -lt 8 ]; do
    t="$1"; t="${t#\(}"
    [ -z "$t" ] && { shift; continue; }
    case "$t" in [A-Za-z_]*=*) shift; continue ;; esac
    base="${t##*/}"
    case "$base" in
      magento|n98-magerun2|n98-magerun2.phar|magerun2|magerun)
        shift; printf '%s\n' "$*"; return 0 ;;
      php|sudo|time|nice|env|exec|xargs)
        shift
        while [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done
        depth=$((depth+1)); continue ;;
      ddev)
        case "${2:-}" in
          exec|php) shift 2 ;;
          magento|magerun|magerun2) shift ;;
          *) return 1 ;;
        esac
        depth=$((depth+1)); continue ;;
      *) return 1 ;;
    esac
  done
  return 1
}

rcg_unquote() {
  local v="$1"
  v="${v%)}"; v="${v#[\'\"]}"; v="${v%[\'\"]}"
  printf '%s' "$v"
}

rcg_is_off() {
  case "$(rcg_unquote "$1" | tr 'A-Z' 'a-z')" in
    ''|null|0|false|off|none|no|disabled) return 0 ;;
  esac
  return 1
}

rcg_check_magento() {
  local args="$1" sub t v found=0 want_value=0
  set -f
  # shellcheck disable=SC2086
  set -- $args
  set +f
  sub="${1:-}"
  case "$sub" in
    security:recaptcha:disable-for-user-*)
      rcg_block "$sub turns off admin reCAPTCHA" ;;
    module:disable)
      case "$args" in *Magento_ReCaptcha*) rcg_block "module:disable of a Magento_ReCaptcha module" ;; esac
      return 0 ;;
    config:delete|config:store:delete)
      case "$args" in
        *recaptcha_frontend*|*recaptcha_backend*) rcg_block "$sub of a recaptcha_* path" ;;
      esac
      return 0 ;;
    config:set|config:store:set)
      shift
      for t in "$@"; do
        if [ "$want_value" = 1 ]; then
          case "$t" in
            -*) continue ;;
            *) found=2; v="$t"; break ;;
          esac
        fi
        case "$(rcg_unquote "$t")" in
          recaptcha_frontend/type_for/*|recaptcha_backend/type_for/*) found=1; want_value=1 ;;
        esac
      done
      [ "$found" = 0 ] && return 0
      if [ "$found" = 1 ] || rcg_is_off "$v"; then
        rcg_block "$sub would blank a recaptcha type_for path"
      fi
      return 0 ;;
  esac
  return 0
}

while IFS= read -r SEG; do
  [ -n "$SEG" ] || continue
  ARGS=$( set -f; set -- $SEG; rcg__segment_magento_args "$@" )
  [ -n "$ARGS" ] && rcg_check_magento "$ARGS"
done <<EOF
$(printf '%s\n' "$CMD" | sed -E 's/(\|\|)|(&&)|;|\||\$\(/\n/g')
EOF

if printf '%s' "$CMD" | grep -qiE 'mysql|mariadb|db:query|db:console'; then
  rcg_check_sql "$CMD"
fi

# Direct writes to env files that mention reCAPTCHA. Plain copies between env
# files are normal deploy work; EnvFileParityTest covers what they carry.
if printf '%s' "$CMD" | grep -qE 'recaptcha_(frontend|backend)|type_for' \
  && printf '%s' "$CMD" | grep -qE 'app/etc/(env[^[:space:]/]*|config)\.php'; then
  P='app/etc/(env[^[:space:]/]*|config)\.php'
  if printf '%s' "$CMD" | grep -qE ">[[:space:]]*[^|;&]*$P|(^|[[:space:]])tee([[:space:]]+-[a-zA-Z]+)*[[:space:]]+[^|;&]*$P|sed[[:space:]]+[^|&]*-i[^|&]*$P|perl[[:space:]]+-[a-zA-Z]*i[^|;&]*$P|file_put_contents"; then
    rcg_block "shell write to an env file that touches reCAPTCHA config; use Edit so the change can be checked"
  fi
fi

exit 0
