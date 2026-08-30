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
  if tg_is_test_path "$f"; then printf '%s\n' "$f"; return 0; fi
  [ -z "$tests" ] && tests=$(tg_test_files "$root")
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
tg_test_families() {
  local cmd="$1" seg
  while IFS= read -r seg; do
    # shellcheck disable=SC2086
    ( set -f; set -- $seg; tg__segment_is_test "$@" )
  done <<EOF | sort -u | grep .
$(printf '%s\n' "$cmd" | sed -E 's/(\|\|)|(&&)|;|\||\$\(/\n/g')
EOF
}

# True (exit 0) when the command string contains a test-runner invocation.
tg_is_test_command() {
  [ -n "$(tg_test_families "$1")" ]
}
