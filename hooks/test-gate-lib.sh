#!/bin/bash
# Shared functions for test-gate.sh (PreToolUse) and test-evidence.sh
# (PostToolUse). Sourced, not executed. Defensive: no set -e; every function
# fails soft so a parse problem never blocks unrelated work.

# Resolve project root from a starting dir. Echoes abs path, or fails.
tg_project_root() {
  local d="$1"
  [ -d "$d" ] || return 1
  (cd "$d" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
}

# Evidence file lives inside the git dir: shared host<->container through the
# project mount, never committable, no .gitignore needed. NOTE: writes a
# subdirectory only — never touches anything else under .git.
tg_evidence_file() {
  local root="$1" gd
  gd=$(cd "$root" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  [ -z "$gd" ] && gd=$(cd "$root" 2>/dev/null && git rev-parse --git-dir 2>/dev/null)
  [ -z "$gd" ] && return 1
  case "$gd" in
    /*) : ;;
    *) gd="$root/$gd" ;;
  esac
  [ -d "$gd" ] || return 1
  mkdir -p "$gd/claude-test-gate" 2>/dev/null || return 1
  echo "$gd/claude-test-gate/evidence.jsonl"
}

# Pathspec excludes for the state hash, from .claude/test-gate.json
# "hash_exempt": ["<git glob>", ...] — for tracked files that churn
# constantly without being code (cron lock files, generated timestamps).
# Echoed one ':(exclude)glob' per line.
tg_hash_excludes() {
  local cfg="$1/.claude/test-gate.json"
  [ -f "$cfg" ] || return 0
  jq -r '(.hash_exempt // []) | .[]' "$cfg" 2>/dev/null | while IFS= read -r g; do
    [ -n "$g" ] && printf ':(exclude)%s\n' "$g"
  done
}

# Content hash of the current code state: HEAD sha + full working-tree diff
# (staged AND unstaged) + sha1 of untracked non-ignored files. `git add` does
# not change it; any file edit or new commit does — so passing evidence is
# automatically invalidated by any code change after the test run.
tg_state_hash() {
  local root="$1"
  (
    cd "$root" 2>/dev/null || exit 1
    ex=()
    while IFS= read -r e; do [ -n "$e" ] && ex+=("$e"); done <<EOF
$(tg_hash_excludes "$root")
EOF
    {
      git rev-parse HEAD 2>/dev/null || echo NOHEAD
      git diff HEAD -- . "${ex[@]}" 2>/dev/null
      # `git diff HEAD` fails in a no-commit repo — --cached still sees staged
      git diff --cached -- . "${ex[@]}" 2>/dev/null
      git ls-files -o --exclude-standard -- . "${ex[@]}" 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
        [ -f "$f" ] && sha1sum -- "$f" 2>/dev/null
      done
    } | sha1sum | awk '{print $1}'
  )
}

# --- relevance: which tests cover a changed file -----------------------------

# True when the path is itself a test file (test dir segment or test-suffixed
# name). Keep in sync with the tg_test_files grep below.
tg_is_test_path() {
  case "$1" in
    *Test.php|*.spec.js|*.spec.jsx|*.spec.ts|*.spec.tsx|*.spec.mjs|\
    *.test.js|*.test.jsx|*.test.ts|*.test.tsx|*.test.mjs) return 0 ;;
  esac
  case "/$1" in
    */Test/*|*/Tests/*|*/tests/*|*/test/*|*/__tests__/*) return 0 ;;
  esac
  return 1
}

# All test files in the repo (tracked + untracked non-ignored), one per line,
# capped for perf. Echoes repo-relative paths.
tg_test_files() {
  local root="$1"
  (
    cd "$root" 2>/dev/null || exit 1
    { git ls-files 2>/dev/null; git ls-files -o --exclude-standard 2>/dev/null; } \
      | sort -u \
      | grep -E '(^|/)(Test|Tests|tests|test|__tests__)/|Test\.php$|\.(spec|test)\.(js|jsx|ts|tsx|mjs)$' \
      | head -5000
  )
}

# Candidate tests covering ONE changed source file. Name-mapping first
# (Foo.php -> FooTest.php; foo.ts -> foo.spec.ts / foo.test.ts / __tests__/foo.*),
# then content grep: test files mentioning the stem as a whole word (catches
# specs that exercise a class without the mapped filename). A changed test
# file is its own candidate. $3 = pre-computed tg_test_files list (perf:
# one repo scan per commit, not per file). Echoes repo-relative paths;
# empty output = no test known to cover this file.
tg_candidate_tests() {
  local root="$1" f="$2" tests="$3" base stem esc out
  [ -z "$tests" ] && tests=$(tg_test_files "$root")
  if tg_is_test_support "$f"; then
    # page object / locator / fixture: covered by the specs that use it,
    # never by itself (pps #519: helpers were demanded as their own "test")
    base="${f##*/}"; stem="${base%.*}"
    [ "${#stem}" -ge 3 ] || return 0
    (cd "$root" 2>/dev/null && printf '%s\n' "$tests" \
      | grep -E '(Test\.php|\.(spec|test)\.[a-z]+)$' | head -2000 \
      | tr '\n' '\0' | xargs -0 -r grep -lF -- "$stem" 2>/dev/null | head -10)
    return 0
  fi
  if tg_is_test_path "$f"; then printf '%s\n' "$f"; return 0; fi
  [ -z "$tests" ] && return 0
  base="${f##*/}"; stem="${base%.*}"
  [ -z "$stem" ] && return 0
  esc=$(printf '%s' "$stem" | sed 's/[][\\.*^$()+?{}|]/\\&/g')
  out=$(printf '%s\n' "$tests" \
    | grep -E "(^|/)(${esc}Test\.php|${esc}\.(spec|test)\.[a-z]+)\$|(^|/)__tests__/${esc}\.[a-z]+\$" 2>/dev/null)
  if [ -z "$out" ] && [ "${#stem}" -ge 3 ]; then
    out=$(cd "$root" 2>/dev/null && printf '%s\n' "$tests" | head -2000 \
      | tr '\n' '\0' | xargs -0 -r grep -lswF -- "$stem" 2>/dev/null | head -10)
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# --- test-runner detection ---------------------------------------------------
# A command counts as a test run only when a known runner is the COMMAND of a
# shell segment (first token after env prefixes / wrappers), not a mere mention
# in arguments. `grep phpunit x` or `echo "run phpunit"` do NOT count.
#
# Runners are classified into evidence FAMILIES so the gate can require both:
#   unit — phpunit/pest/jest/vitest/pytest/... (also legacy records w/o family)
#   e2e  — playwright/codeception/behat, and npm-style scripts named *e2e*

# Internal: echo family (unit|e2e) for one segment's token list; fail if not a
# test invocation.
tg__segment_is_test() {
  local depth=0 t
  while [ $# -gt 0 ] && [ $depth -lt 8 ]; do
    t="$1"
    # strip leading subshell parens / redirects
    t="${t#\(}"
    [ -z "$t" ] && { shift; continue; }
    # env-var prefix (FOO=bar cmd ...)
    case "$t" in
      [A-Za-z_]*=*) shift; continue ;;
    esac
    local base="${t##*/}"
    # PHP test runners are commonly shipped/committed as a standalone .phar
    # (invoked as `php dev/phpunit.phar ...`) — normalize before matching so
    # phpunit.phar/paratest.phar/pest.phar/infection.phar are recognized the
    # same as their non-phar form, not just the bare binary name.
    case "$base" in *.phar) base="${base%.phar}" ;; esac
    case "$base" in
      phpunit|paratest|pest|infection|jest|vitest|pytest)
        echo unit; return 0 ;;
      codecept|codeception|behat)
        echo e2e; return 0 ;;
      playwright)
        [ "${2:-}" = "test" ] && { echo e2e; return 0; }
        return 1 ;;
      npm|pnpm)
        shift
        if [ "${1:-}" = "run" ] || [ "${1:-}" = "run-script" ]; then shift; fi
        case "${1:-}" in
          *e2e*|*playwright*) echo e2e; return 0 ;;
          test|test:*|tests) echo unit; return 0 ;;
        esac
        return 1 ;;
      yarn)
        shift
        [ "${1:-}" = "run" ] && shift
        case "${1:-}" in
          *e2e*|*playwright*) echo e2e; return 0 ;;
          test|test:*|tests) echo unit; return 0 ;;
        esac
        return 1 ;;
      composer)
        shift
        if [ "${1:-}" = "run" ] || [ "${1:-}" = "run-script" ]; then shift; fi
        case "${1:-}" in
          *e2e*|*playwright*) echo e2e; return 0 ;;
          test|test:*|tests) echo unit; return 0 ;;
        esac
        return 1 ;;
      magento)
        case "${2:-}" in dev:tests:run*) echo unit; return 0 ;; esac
        return 1 ;;
      php|npx|node|sudo|time|nice|xvfb-run)
        # `node --test ...` is Node's built-in runner (JS units), not a wrapper
        if [ "$base" = "node" ]; then
          local a
          for a in "${@:2}"; do
            case "$a" in --test|--test=*) echo unit; return 0 ;; -*) : ;; *) break ;; esac
          done
        fi
        # wrapper: skip it and its option flags, re-evaluate next real token
        shift
        while [ $# -gt 0 ]; do
          case "$1" in -*) shift ;; *) break ;; esac
        done
        depth=$((depth+1)); continue ;;
      ddev)
        case "${2:-}" in
          exec|php) shift 2 ;;
          *) return 1 ;;
        esac
        depth=$((depth+1)); continue ;;
      *) return 1 ;;
    esac
  done
  return 1
}

# Echo the distinct families of every test-runner invocation in the command
# string, one per line (a `phpunit && playwright test` chain yields both).
# Empty output = not a test command.
# Drop heredoc bodies from a command string: they are data fed to a program
# (python patch scripts, docs), not shell commands. Without this, a doc line
# starting `node --test …` inside `python3 - <<'EOF'` read as a test run —
# tripping guards and able to forge an evidence record (2026-10-01).
tg_strip_heredocs() {
  printf '%s\n' "$1" | awk '
    inh { if ($0 ~ "^[[:space:]]*" tag "[[:space:]]*$") inh=0; next }
    { print }
    match($0, /<<-?[[:space:]]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*/) {
      t=substr($0, RSTART, RLENGTH); sub(/^<<-?[[:space:]]*["'"'"']?/, "", t); tag=t; inh=1
    }'
}

# Split a command string into shell segments, QUOTE-AWARE. Echoes one line
# per segment: "<op>\t<segment>", where <op> is the operator that ENDS the
# segment (| || && ; & nl $( end). Operators inside '...' or "..." are text:
# `pgrep -af 'a|phpunit'` is ONE segment, not a pgrep piped into a phpunit
# runner (2026-10-01 — the old sed split recorded such a probe as a test run),
# and `--filter "Foo|Bar"` stays one token. Heredoc bodies are dropped first.
tg_split_segments() {
  tg_strip_heredocs "$1" | awk 'BEGIN { RS = "\001" } {
    s = $0; n = length(s); seg = ""; sq = 0; dq = 0
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1); nx = substr(s, i + 1, 1); pv = substr(s, i - 1, 1)
      if (sq) { seg = seg c; if (c == "\047") sq = 0; continue }
      if (c == "\\") { seg = seg c nx; i++; continue }
      if (dq) { seg = seg c; if (c == "\"") dq = 0; continue }
      if (c == "\047") { sq = 1; seg = seg c; continue }
      if (c == "\"") { dq = 1; seg = seg c; continue }
      op = ""
      if (c == "|" && nx == "|") { op = "||"; i++ }
      else if (c == "&" && nx == "&") { op = "&&"; i++ }
      else if (c == "|") op = "|"
      else if (c == ";") op = ";"
      else if (c == "\n") op = "nl"
      else if (c == "$" && nx == "(") { op = "$("; i++ }
      else if (c == "&" && nx != ">" && pv != ">") op = "&"
      if (op != "") { printf "%s\t%s\n", op, seg; seg = ""; continue }
      seg = seg c
    }
    printf "end\t%s\n", seg
  }'
}

tg_test_families() {
  local op seg
  while IFS=$'\t' read -r op seg; do
    # shellcheck disable=SC2086
    ( set -f; set -- $seg; tg__segment_is_test "$@" )
  done <<EOF | sort -u | grep .
$(tg_split_segments "$1")
EOF
}

# True (exit 0) when a test-runner segment is followed by a single `|` —
# i.e. its exit status is masked by a downstream command (`phpunit | tail`).
# `||` is not a pipe. Splits on single pipes only; `$(...)` bodies are not
# special-cased (a runner inside a substitution is already not recorded by
# tg_test_families' `$(` split).
tg_runner_piped() {
  local op seg
  while IFS=$'\t' read -r op seg; do
    [ "$op" = "|" ] || continue
    # shellcheck disable=SC2086
    ( set -f; set -- $seg; tg__segment_is_test "$@" >/dev/null ) && return 0
  done <<EOF
$(tg_split_segments "$1")
EOF
  return 1
}

# --- relevance coverage: did a recorded run execute a given test file? -------
# Runner KIND is finer than evidence family: a phpunit run never executes a
# .spec.ts, a playwright run never executes a FooTest.php (pps #519: any
# unfiltered phpunit run was crediting every .spec.ts/.test.js candidate,
# while a `--filter "Uptactics|ProxiBlue"` run that executed 1317 tests was
# credited with none).

# Echo each runner segment of a command, one per line. Non-runner segments
# (`git add X`, `cd`, `set -o pipefail`) are dropped so their tokens can never
# make a run look targeted.
tg_runner_segments() {
  local op seg
  while IFS=$'\t' read -r op seg; do
    # shellcheck disable=SC2086
    ( set -f; set -- $seg; tg__segment_is_test "$@" >/dev/null ) && printf '%s\n' "$seg"
  done <<EOF
$(tg_split_segments "$1")
EOF
}

# Kind of one runner segment: php | js | e2e | jsany (npm/yarn script) | other
tg_segment_kind() {
  local s=" $1 "
  case "$s" in
    *[/[:space:]]phpunit[[:space:]]*|*[/[:space:]]phpunit.phar[[:space:]]*|*[/[:space:]]paratest[[:space:]]*|\
    *[/[:space:]]pest[[:space:]]*|*[/[:space:]]infection[[:space:]]*|*" dev:tests:run"*) echo php; return ;;
    *[/[:space:]]playwright[[:space:]]test*|*[/[:space:]]codecept[[:space:]]*|*[/[:space:]]codeception[[:space:]]*|\
    *[/[:space:]]behat[[:space:]]*) echo e2e; return ;;
    *" node "*--test*|*[/[:space:]]jest[[:space:]]*|*[/[:space:]]vitest[[:space:]]*) echo js; return ;;
    *[/[:space:]]composer[[:space:]]*) echo php; return ;;
    *[/[:space:]]npm[[:space:]]*|*[/[:space:]]pnpm[[:space:]]*|*[/[:space:]]yarn[[:space:]]*) echo jsany; return ;;
  esac
  echo other
}

# Kind of a candidate test file: php | js | spec | other
tg_test_kind() {
  case "$1" in
    *Test.php) echo php ;;
    *.test.js|*.test.jsx|*.test.ts|*.test.tsx|*.test.mjs|*/__tests__/*) echo js ;;
    *.spec.js|*.spec.jsx|*.spec.ts|*.spec.tsx|*.spec.mjs) echo spec ;;
    *) echo other ;;
  esac
}

tg__kind_ok() { # <run-kind> <test-kind>
  case "$1:$2" in
    php:php|js:js|js:spec|e2e:spec|jsany:js|jsany:spec|other:other) return 0 ;;
  esac
  return 1
}

# True when the path is a test-SUPPORT file (page object, locator, fixture,
# helper under a test dir) rather than an executable test file.
tg_is_test_support() {
  tg_is_test_path "$1" || return 1
  [ "$(tg_test_kind "$1")" = "other" ]
}

# Base dir (repo-relative, may be empty) a command's runner paths resolve
# against: the first leading `cd <dir>`, made relative to <root>.
tg__cmd_basedir() { # <root> <cmd>
  local root="$1" d
  d=$(printf '%s' "$2" | grep -oE '^[[:space:]]*cd[[:space:]]+[^;&|]+' | head -1 \
    | sed -E 's/^[[:space:]]*cd[[:space:]]+//; s/[[:space:]]+$//; s/^"//; s/"$//')
  [ -z "$d" ] && return 0
  case "$d" in
    "$root") d="" ;;
    "$root"/*) d="${d#"$root"/}" ;;
    /var/www/html) d="" ;;
    /var/www/html/*) d="${d#/var/www/html/}" ;;
    /*) d="" ;;
  esac
  printf '%s' "$d"
}

# Normalise a runner path token to repo-relative, honouring the cd base dir.
tg__norm_path() { # <root> <basedir> <token>
  local root="$1" base="$2" t="$3"
  t="${t#./}"
  case "$t" in
    "$root"/*) t="${t#"$root"/}" ;;
    /var/www/html/*) t="${t#/var/www/html/}" ;;
    /*) : ;;
    *) [ -n "$base" ] && t="$base/$t" ;;
  esac
  # collapse a/b/../c segments
  while printf '%s' "$t" | grep -qE '(^|/)[^/.][^/]*/\.\./'; do
    t=$(printf '%s' "$t" | sed -E 's#(^|/)[^/.][^/]*/\.\./#\1#')
  done
  printf '%s' "${t%/}"
}

tg__unquote() { local t="$1"; t="${t%\"}"; t="${t#\"}"; t="${t%\'}"; t="${t#\'}"; printf '%s' "$t"; }

# Classify one runner segment: echoes "broad" or "targeted". Broad = no
# filter/grep, no test-file, glob or directory argument (a suite-wide run).
tg_segment_scope() { # <root> <basedir> <segment>
  local root="$1" base="$2" tok p
  # shellcheck disable=SC2086
  for tok in $(set -f; printf '%s\n' $3); do
    tok=$(tg__unquote "$tok")
    case "$tok" in
      --filter|--filter=*|--grep|--grep=*|-g) echo targeted; return ;;
      *Test.php|*.spec.*|*.test.*|*'*'*) echo targeted; return ;;
      -*|*=*) continue ;;
    esac
    p=$(tg__norm_path "$root" "$base" "$tok")
    [ -n "$p" ] && [ "$p" != "." ] && [ -d "$root/$p" ] && { echo targeted; return; }
  done
  echo broad
}

# True (exit 0) when the recorded run <cmd> executed candidate test <c>
# (repo-relative). Per runner segment: kind must match; a broad segment covers
# every test of its kind; a targeted one covers named files, globs,
# directories it was pointed at, and --filter regex matches on the test's
# class name or path.
tg_run_covers() { # <root> <cmd> <candidate>
  local root="$1" cmd="$2" c="$3" ck base seg sk tok p next stem rx
  ck=$(tg_test_kind "$c")
  base=$(tg__cmd_basedir "$root" "$cmd")
  stem="${c##*/}"; stem="${stem%.*}"
  while IFS= read -r seg; do
    [ -z "$seg" ] && continue
    sk=$(tg_segment_kind "$seg")
    tg__kind_ok "$sk" "$ck" || continue
    [ "$(tg_segment_scope "$root" "$base" "$seg")" = "broad" ] && return 0
    next=""
    # shellcheck disable=SC2086
    for tok in $(set -f; printf '%s\n' $seg); do
      tok=$(tg__unquote "$tok")
      if [ "$next" = "filter" ]; then
        next=""; rx="${tok%%::*}"
        printf '%s\n%s\n' "$stem" "$c" | grep -qE -- "$rx" 2>/dev/null && return 0
        continue
      fi
      case "$tok" in
        --filter) next="filter"; continue ;;
        --filter=*) rx="${tok#--filter=}"; rx="${rx%%::*}"
          printf '%s\n%s\n' "$stem" "$c" | grep -qE -- "$rx" 2>/dev/null && return 0
          continue ;;
        -*|*=*) continue ;;
      esac
      p=$(tg__norm_path "$root" "$base" "$tok")
      [ -z "$p" ] && continue
      case "$p" in
        *'*'*) [[ "$c" == $p ]] && return 0 ;;
        *) [ "$c" = "$p" ] && return 0
           case "$c" in "$p"/*) [ -d "$root/$p" ] && return 0 ;; esac
           # basename / class stem named (`phpunit FooTest`, a spec given
           # relative to a symlinked app dir)
           case "${p##*/}" in "${c##*/}"|"$stem") return 0 ;; esac ;;
      esac
    done
  done <<EOF
$(tg_runner_segments "$cmd")
EOF
  return 1
}

# True (exit 0) when the command string contains a test-runner invocation.
tg_is_test_command() {
  [ -n "$(tg_test_families "$1")" ]
}
