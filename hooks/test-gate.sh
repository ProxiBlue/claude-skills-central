#!/bin/bash
# PreToolUse Bash hook — machine-checked TEST GATE on `git commit` / `git push`.
#
# Closes the enforcement asymmetry called out in the 2026-07-31 tooling review:
# branch topology was hook-enforced while "test before push" was only prose
# (origin incident: lcdscreen #385 — upgrade declared "verified" off a partial
# test subset; a human caught 12 failing admin tests).
#
# Blocks (exit 2) a commit/push when the changed CODE files have no passing
# test-run evidence recorded at the CURRENT working-tree state. Evidence is
# written by test-evidence.sh (PostToolUse) whenever a real test runner is
# executed through the Bash tool; any code edit after that run changes the
# state hash and invalidates the evidence.
#
# Scope control — the gate only arms itself when the project shows test
# infrastructure (phpunit.xml*, vendor/bin/phpunit, playwright config,
# package.json test script) or an explicit config. Docs/skills/shell-only
# repos pass through untouched.
#
# Per-project config (optional): <root>/.claude/test-gate.json
#   {
#     "enabled": true|false,          // explicit on/off; wins over auto-detect
#     "test_hint": "ddev exec vendor/bin/phpunit -c dev/tests/unit/phpunit.xml",
#     "required_families": ["unit","e2e"],  // evidence families that must each
#                                           // pass; default = auto-detect
#                                           // (phpunit infra→unit, playwright cfg→e2e)
#     "code_patterns": ["\\.(php|phtml|js|ts)$"],   // regex allowlist override
#     "exempt_patterns": ["^docs/", "^Test/fixtures/"],
#     "coverage": {                   // opt-in changed-line coverage gate
#       "clover": "var/coverage/clover.xml",
#       "min_pct": 60,
#       "on_missing": "block"|"warn"  // clover absent/stale (default block)
#     }
#   }
#
# Bypass (user only, BEFORE starting claude — cannot be set mid-session):
#   export CLAUDE_TEST_GATE_ALLOWED=1
# Soft-launch mode (warn instead of block):
#   export CLAUDE_TEST_GATE_MODE=warn
#
# Defensive: no set -e. jq missing / input unparseable / not a git repo →
# silent no-op. Never blocks on infrastructure failure.

[ "${CLAUDE_TEST_GATE_ALLOWED:-0}" = "1" ] && exit 0
MODE="${CLAUDE_TEST_GATE_MODE:-block}"

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null)
[ -z "$CMD" ] && exit 0

GIT_RE='(^|[;&|[:space:]])git[[:space:]]+([^;&|]*[[:space:]])?'
OP=""
if printf '%s' "$CMD" | grep -qE "${GIT_RE}commit([[:space:]]|\$)"; then
  OP="commit"
elif printf '%s' "$CMD" | grep -qE "${GIT_RE}push([[:space:]]|\$)"; then
  OP="push"
else
  exit 0
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
[ -f "$SCRIPT_DIR/test-gate-lib.sh" ] || exit 0
# shellcheck source=test-gate-lib.sh
. "$SCRIPT_DIR/test-gate-lib.sh"

CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD=$(pwd)
FIRST_CD=$(printf '%s' "$CMD" | grep -oE '^[[:space:]]*cd[[:space:]]+[^;&|]+' | head -1 \
  | sed -E 's/^[[:space:]]*cd[[:space:]]+//; s/[[:space:]]+$//')
if [ -n "$FIRST_CD" ]; then
  case "$FIRST_CD" in
    "~")   FIRST_CD="$HOME" ;;
    "~/"*) FIRST_CD="$HOME/${FIRST_CD#\~/}" ;;
  esac
  case "$FIRST_CD" in
    /*) CWD="$FIRST_CD" ;;
    *)  CWD="$CWD/$FIRST_CD" ;;
  esac
fi

ROOT=$(tg_project_root "$CWD") || exit 0
[ -z "$ROOT" ] && exit 0
cd "$ROOT" 2>/dev/null || exit 0

# Playwright configs may live in subdirs (tests/, tests/<suite>/), not repo root.
tg_playwright_cfgs() {
  find "$ROOT" -maxdepth 3 \( -name node_modules -o -name vendor -o -name dist -o -name .git \) -prune \
    -o -type f \( -name 'playwright.config.js' -o -name 'playwright.config.ts' \) -print 2>/dev/null | head -5
}

# --- infra detection (feeds arm check, evidence families, and hint) ----------
CFG="$ROOT/.claude/test-gate.json"
PW_CFGS=$(tg_playwright_cfgs)
UNIT_INFRA=0
for f in phpunit.xml phpunit.xml.dist phpunit.dist.xml; do
  [ -f "$ROOT/$f" ] && UNIT_INFRA=1 && break
done
[ "$UNIT_INFRA" = "0" ] && [ -f "$ROOT/vendor/bin/phpunit" ] && UNIT_INFRA=1
[ "$UNIT_INFRA" = "0" ] && [ -d "$ROOT/dev/tests" ] && UNIT_INFRA=1
if [ "$UNIT_INFRA" = "0" ] && [ -f "$ROOT/package.json" ]; then
  PJT=$(jq -r '.scripts.test // empty' "$ROOT/package.json" 2>/dev/null)
  case "$PJT" in
    ''|*'no test specified'*) : ;;
    *) UNIT_INFRA=1 ;;
  esac
fi

# --- arm check ---------------------------------------------------------------
ENABLED=""
if [ -f "$CFG" ]; then
  ENABLED=$(jq -r '.enabled // empty' "$CFG" 2>/dev/null)
fi
if [ "$ENABLED" = "false" ]; then
  exit 0
fi
if [ -z "$ENABLED" ]; then
  [ "$UNIT_INFRA" = "0" ] && [ -z "$PW_CFGS" ] && exit 0
fi

# Evidence families this project must show at the current state hash.
# Override via config: "required_families": ["unit","e2e"]
REQ_FAMS=""
[ -f "$CFG" ] && REQ_FAMS=$(jq -r '(.required_families // []) | join(" ")' "$CFG" 2>/dev/null)
if [ -z "$REQ_FAMS" ]; then
  [ "$UNIT_INFRA" = "1" ] && REQ_FAMS="unit"
  [ -n "$PW_CFGS" ] && REQ_FAMS="${REQ_FAMS:+$REQ_FAMS }e2e"
  [ -z "$REQ_FAMS" ] && REQ_FAMS="unit"
fi

# --- changed code files ------------------------------------------------------
DEFAULT_CODE_RE='\.(php|phtml|js|mjs|cjs|ts|tsx|jsx|graphqls?)$'
CODE_RE="$DEFAULT_CODE_RE"
EXEMPT_RE=""
if [ -f "$CFG" ]; then
  C=$(jq -r '(.code_patterns // []) | join("|")' "$CFG" 2>/dev/null)
  [ -n "$C" ] && CODE_RE="$C"
  EXEMPT_RE=$(jq -r '(.exempt_patterns // []) | join("|")' "$CFG" 2>/dev/null)
fi

CHANGED=""
if [ "$OP" = "commit" ]; then
  CHANGED=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null)
  # `git commit -a` also sweeps unstaged tracked modifications in
  if printf '%s' "$CMD" | grep -qE "${GIT_RE}commit[[:space:]]+([^;&|]*[[:space:]])?(-[a-zA-Z]*a[a-zA-Z]*|--all)([[:space:]]|\$)"; then
    CHANGED=$(printf '%s\n%s\n' "$CHANGED" "$(git diff --name-only --diff-filter=ACMR HEAD 2>/dev/null)")
  fi
else
  # push: everything on top of the upstream (fallback: remote branch, then
  # remote default). Unresolvable base → fall through with empty set; the
  # HEAD-blessing check below still applies.
  BASE=""
  if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    BASE='@{u}'
  else
    BR=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -n "$BR" ] && git rev-parse --verify -q "origin/$BR" >/dev/null 2>&1; then
      BASE="origin/$BR"
    elif git rev-parse --verify -q 'origin/HEAD' >/dev/null 2>&1; then
      BASE=$(git merge-base HEAD origin/HEAD 2>/dev/null)
    fi
  fi
  [ -n "$BASE" ] && CHANGED=$(git diff --name-only "$BASE"..HEAD 2>/dev/null)
fi

GATED=$(printf '%s\n' "$CHANGED" | grep -E "$CODE_RE" 2>/dev/null | sort -u)
if [ -n "$EXEMPT_RE" ] && [ -n "$GATED" ]; then
  GATED=$(printf '%s\n' "$GATED" | grep -vE "$EXEMPT_RE" 2>/dev/null)
fi

if [ "$OP" = "commit" ] && [ -z "$GATED" ]; then
  exit 0  # docs/config-only commit — not gated
fi

# --- evidence check ----------------------------------------------------------
EF=$(tg_evidence_file "$ROOT")
HASH=$(tg_state_hash "$ROOT")

# Per-family check: every required family needs a passing run at the current
# state hash. Legacy records without a family field count as "unit".
PASSED=""
MISSING_FAMS="$REQ_FAMS"
if [ -n "$EF" ] && [ -f "$EF" ] && [ -n "$HASH" ]; then
  MISSING_FAMS=""
  for FAM in $REQ_FAMS; do
    P=$(jq -r --arg h "$HASH" --arg f "$FAM" \
      'select(.type=="test" and .state==$h and .exit_code==0) | select((.family // "unit")==$f) | .ts' \
      "$EF" 2>/dev/null | tail -1)
    [ -z "$P" ] && MISSING_FAMS="${MISSING_FAMS:+$MISSING_FAMS }$FAM"
  done
  [ -z "$MISSING_FAMS" ] && PASSED="ok"
fi

if [ "$OP" = "push" ] && [ -z "$PASSED" ]; then
  # a HEAD that was itself committed through the gate is already proven
  HEAD=$(git rev-parse HEAD 2>/dev/null)
  if [ -n "$EF" ] && [ -f "$EF" ] && [ -n "$HEAD" ]; then
    PASSED=$(jq -r --arg h "$HEAD" 'select(.type=="commit" and .head==$h) | .ts' "$EF" 2>/dev/null | tail -1)
  fi
  # nothing code-relevant in the outgoing range and no evidence system in play
  [ -z "$PASSED" ] && [ -z "$GATED" ] && [ -n "$BASE" ] && exit 0
fi

# --- coverage layer (opt-in) -------------------------------------------------
cov_gate() {
  [ -f "$CFG" ] || return 0
  local clover minpct onmiss out rc
  clover=$(jq -r '.coverage.clover // empty' "$CFG" 2>/dev/null)
  [ -z "$clover" ] && return 0
  case "$clover" in /*) : ;; *) clover="$ROOT/$clover" ;; esac
  minpct=$(jq -r '.coverage.min_pct // 60' "$CFG" 2>/dev/null)
  onmiss=$(jq -r '.coverage.on_missing // "block"' "$CFG" 2>/dev/null)
  printf '%s\n' "$GATED" | grep -qE '\.php$' || return 0
  out=$("$SCRIPT_DIR/../scripts/changed-line-coverage.sh" "$ROOT" "$clover" "$minpct" HEAD 2>&1)
  rc=$?
  if [ "$rc" = "1" ]; then
    COV_FAIL="changed-line coverage below threshold:\n$out"
    return 1
  fi
  if [ "$rc" = "3" ] && [ "$onmiss" = "block" ]; then
    COV_FAIL="coverage report missing or stale (coverage.on_missing=block):\n$out\nRe-run the test suite with coverage enabled so the clover report matches the changed code."
    return 1
  fi
  return 0
}

COV_FAIL=""
if [ -n "$PASSED" ] && [ "$OP" = "commit" ]; then
  if ! cov_gate; then
    PASSED=""
  fi
fi

[ -n "$PASSED" ] && exit 0

# --- block -------------------------------------------------------------------
HINT=""
[ -f "$CFG" ] && HINT=$(jq -r '.test_hint // empty' "$CFG" 2>/dev/null)
if [ -z "$HINT" ]; then
  [ -f "$ROOT/vendor/bin/phpunit" ] && HINT="vendor/bin/phpunit (use the project's phpunit.xml / dev/tests config)"
  [ -z "$HINT" ] && HINT="this project's test suite (see package.json / dev/tests)"
fi

FILE_LIST=$(printf '%s\n' "$GATED" | head -20 | sed 's/^/    /')
[ -z "$FILE_LIST" ] && FILE_LIST="    (outgoing commits — no per-file breakdown available)"

fam_missing() {
  case " $MISSING_FAMS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

{
  echo "BLOCKED by test-gate.sh: git $OP without passing test evidence for the current code state."
  if [ -n "$MISSING_FAMS" ]; then
    echo "Required evidence families: $REQ_FAMS — MISSING at current state: $MISSING_FAMS"
    echo "(each family needs its own passing run; a phpunit pass does NOT cover e2e)"
  fi
  echo ""
  if [ -n "$COV_FAIL" ]; then
    echo -e "$COV_FAIL"
  else
    echo "Changed code files needing a test run:"
    echo "$FILE_LIST"
  fi
  echo ""
  echo "What to do:"
  N=1
  if [ -z "$MISSING_FAMS" ] || fam_missing unit; then
    echo "  $N. Run the unit tests NOW via the Bash tool: $HINT"
    echo "     (a passing run auto-records evidence; no extra step needed)"
    N=$((N+1))
  fi
  if [ -n "$PW_CFGS" ] && { [ -z "$MISSING_FAMS" ] || fam_missing e2e; }; then
    echo "  $N. Run the RELATED Playwright e2e specs — this project depends on"
    echo "     e2e coverage, not phpunit alone. Do NOT run the full e2e suite:"
    echo "     identify the spec files covering the changed functions/flows"
    echo "     (grep the spec dirs for the affected feature/route/selector) and"
    echo "     run only those, e.g.: npx playwright test <related>.spec.ts -c <config>"
    echo "     Playwright configs found:"
    printf '%s\n' "$PW_CFGS" | sed "s|^$ROOT/|       |"
    echo "     If genuinely NO e2e spec touches the changed behavior, run the"
    echo "     nearest smoke/spec instead and say so explicitly in your summary"
    echo "     — the e2e evidence requirement does not waive itself."
    N=$((N+1))
  fi
  echo "  $N. Then retry the $OP. Any code edit AFTER the test run invalidates"
  echo "     the evidence — rerun tests after fixes."
  echo "  $((N+1)). If tests fail, fix the code first. Never commit failing work."
  echo ""
  echo "Do NOT work around this gate:"
  echo "  - Do not edit/delete the evidence file, this hook, or .claude/test-gate.json."
  echo "  - Do not fake a run (echo/grep mentioning a runner does not count)."
  echo "  - Do not use a sub-agent, background task, or bash -c wrapping to $OP."
  echo "  - If tests cannot run in this environment, STOP and tell the user; wait."
  echo ""
  echo "User-only bypass: export CLAUDE_TEST_GATE_ALLOWED=1 before starting claude,"
  echo "or set {\"enabled\": false} in .claude/test-gate.json."
} >&2

if [ "$MODE" = "warn" ]; then
  echo "test-gate: WARN mode — the above would have blocked in block mode." >&2
  exit 0
fi
exit 2
