#!/bin/bash
# PreToolUse hook: audit staged files before `git commit`.
# Runs phpcs (Magento2 for app/code/, PSR12 elsewhere), phpstan if configured,
# xmllint on staged XML, a comment-noise scan, and a duplicate-block scan.
# Silent unless issues are found.

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only intercept git commit commands
echo "$COMMAND" | grep -qE '(^|[[:space:]])git[[:space:]]+commit([[:space:]]|$)' || exit 0

CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$CWD" ] && CWD=$(pwd)
[ -d "$CWD" ] || exit 0

PROJECT_ROOT=$(cd "$CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$PROJECT_ROOT"

STAGED_PHP=$(git diff --cached --name-only --diff-filter=ACMR -- '*.php' 2>/dev/null || true)
STAGED_XML=$(git diff --cached --name-only --diff-filter=ACMR -- '*.xml' 2>/dev/null || true)
STAGED_CODE=$(git diff --cached --name-only --diff-filter=ACMR -- '*.php' '*.phtml' '*.js' '*.ts' 2>/dev/null || true)

# NOTE: must include STAGED_CODE here — a commit touching only .js/.ts files
# has empty STAGED_PHP/STAGED_XML but still needs the comment-noise and
# duplicate-block scans below to run.
[ -z "$STAGED_PHP" ] && [ -z "$STAGED_XML" ] && [ -z "$STAGED_CODE" ] && exit 0

ERRORS=""
WARNINGS=""

if [ -n "$STAGED_PHP" ] && [ -f vendor/bin/phpcs ]; then
    for file in $STAGED_PHP; do
        [ -f "$file" ] || continue
        # Skip Magento-generated config files (app/etc/) — not PSR-compliant by design
        echo "$file" | grep -qE '^app/etc/' && continue
        # Skip mage-os framework core paths deployed by the component installer — not custom code
        echo "$file" | grep -qE '^(app/autoload|app/bootstrap|bin/|dev/|lib/|pub/|setup/|var/)' && continue
        STANDARD="PSR12"
        echo "$file" | grep -q '^app/code/' && STANDARD="Magento2"
        # emacs report format: only real errors match "path:line:col: type - message"
        # Filter everything else (DEPRECATED, WARNING, sniff notices) by keeping only emacs-format lines
        RESULT=$(vendor/bin/phpcs --standard="$STANDARD" -n --report=emacs "$file" 2>/dev/null | grep -E '^/.+:[0-9]+:[0-9]+:') || true
        [ -n "$RESULT" ] && ERRORS="${ERRORS}\n--- phpcs ($STANDARD): $file ---\n${RESULT}\n"
    done
fi

if [ -n "$STAGED_PHP" ] && [ -f vendor/bin/phpstan ]; then
    PHPSTAN_FILES=""
    for file in $STAGED_PHP; do
        # Skip mage-os framework core paths deployed by the component installer — not custom code
        echo "$file" | grep -qE '^(app/autoload|app/bootstrap|bin/|dev/|lib/|pub/|setup/|var/)' && continue
        [ -f "$file" ] && PHPSTAN_FILES="${PHPSTAN_FILES} ${file}"
    done
    if [ -n "$PHPSTAN_FILES" ]; then
        # Use project phpstan config if available (handles Factory class ignores)
        PHPSTAN_OPTS="--no-progress --error-format=table"
        [ -f phpstan.neon ] && PHPSTAN_OPTS="$PHPSTAN_OPTS -c phpstan.neon"
        RESULT=$(vendor/bin/phpstan analyse $PHPSTAN_OPTS $PHPSTAN_FILES 2>&1) || true
        echo "$RESULT" | grep -q '\[ERROR\]' && ERRORS="${ERRORS}\n--- phpstan ---\n${RESULT}\n"
    fi
fi

# Comment-noise scan: added inline comments that narrate the code instead of
# stating a constraint (AI-generated "// call the helper" style). Only ADDED
# lines, only // and # inline comments (docblocks untouched), narrow patterns
# to keep false positives near zero. Blocking like the rest of the audit.
if [ -n "$STAGED_CODE" ]; then
    NOISE=$(git diff --cached -U0 -- '*.php' '*.phtml' '*.js' '*.ts' 2>/dev/null | awk '
        /^\+\+\+ b\// { file = substr($0, 7); skip = (file ~ /^(vendor|generated|var|pub\/static|node_modules)\//); next }
        /^\+/ && !skip {
            line = substr($0, 2)
            if (line ~ /(\/\/|#)[[:space:]]*([Cc]alls? the|[Ff]irst,|[Tt]hen,|[Nn]ow (we|call|check|create)|[Ll]oop (through|over)|[Ii]terate (through|over)|[Gg]et the|[Ss]et the|[Rr]eturn the|[Cc]reate a new|[Ii]nitiali[sz]e the|[Tt]his (fixes|ensures|change|will now)|[Cc]heck (if|that|whether) the|[Aa]dded (to|for|because)|[Mm]ake sure)/)
                print file ": " line
        }' | head -20)
    [ -n "$NOISE" ] && ERRORS="${ERRORS}\n--- comment noise (narration comments: delete, or replace with the WHY-constraint the code cannot show) ---\n${NOISE}\n"
fi

# Duplicate-block scan: six-plus consecutive ADDED lines (trivial/short lines
# filtered out) that repeat elsewhere in this same staged diff, same file or
# across files. Usually means copy-paste where a shared helper belonged.
# Advisory, not blocking — unlike phpcs/phpstan (compiler-verified) or the
# narration regex (near-zero false-positive phrases), literal-repeat is a
# fuzzy signal: legitimate near-duplicate scaffolding (parallel test cases,
# config arrays) can trip it. A gate that cries wolf gets ignored, so this
# one reports and lets the commit through; promote to blocking later only if
# it proves clean in practice.
if [ -n "$STAGED_CODE" ]; then
    DUPES=$(git diff --cached -U0 -- '*.php' '*.phtml' '*.js' '*.ts' 2>/dev/null | awk -v W=6 -v MINLEN=6 -v CAP=10 '
        /^\+\+\+ b\// { file = substr($0, 7); skip = (file ~ /^(vendor|generated|var|pub\/static|node_modules)\//); next }
        /^\+/ && !skip {
            line = substr($0, 2)
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            gsub(/[ \t]+/, " ", line)
            if (length(line) < MINLEN) next
            cnt++
            content[cnt] = line
            fname[cnt] = file
        }
        END {
            reports = 0
            for (i = 1; i + W - 1 <= cnt; i++) {
                if (fname[i] != fname[i+W-1]) continue
                key = ""
                for (j = 0; j < W; j++) key = key content[i+j] "\001"
                if (key in firstfile) {
                    if (!(key in reported)) {
                        reported[key] = 1
                        print fname[i] " (matches earlier addition in " firstfile[key] "): " content[i]
                        reports++
                        if (reports >= CAP) exit
                    }
                } else {
                    firstfile[key] = fname[i]
                }
            }
        }')
    [ -n "$DUPES" ] && WARNINGS="${WARNINGS}\n--- possible duplicate blocks (6+ line literal repeat added in this commit — consider extracting a shared helper) ---\n${DUPES}\n"
fi

if [ -n "$STAGED_XML" ] && command -v xmllint >/dev/null 2>&1; then
    for file in $STAGED_XML; do
        [ -f "$file" ] || continue
        RESULT=$(xmllint --noout "$file" 2>&1) || true
        [ -n "$RESULT" ] && ERRORS="${ERRORS}\n--- xmllint: $file ---\n${RESULT}\n"
    done
fi

if [ -n "$WARNINGS" ]; then
    echo -e "Pre-commit audit — advisory (not blocking):\n${WARNINGS}" >&2
fi

if [ -n "$ERRORS" ]; then
    echo -e "Pre-commit audit found issues:\n${ERRORS}" >&2
    exit 2
fi

exit 0
