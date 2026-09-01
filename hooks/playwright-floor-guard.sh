#!/bin/bash
# Playwright-Floor Guard — MANDATORY on hcf:plan-create + hcf:plan-orchestrate.
#
# Enforces the fleet standing rule: money-moving surfaces (checkout, payment,
# order, cart) must retain end-to-end browser coverage even after the
# JS-unit-first shift (see host graphiti episodes 2026-08-06T14:45:00Z and
# 2026-08-06T15:00:00Z). Prevention = deterministic hook, never prose /
# frontmatter self-attestation. Same pattern as push-guard.sh /
# git-tree-guard.sh / test-gate.sh.
#
# Failure mode this prevents: a tdd-worker migrates cart-total /
# discount / address-validation / checkout / payment / order assertions
# fully into the JS-unit bucket with zero forced Playwright floor. Money
# path loses end-to-end wiring coverage silently.
#
# Rule:
#   IF a task file's domain matches (frontmatter `**Domain**:` in
#   {checkout,payment,order} OR title/path contains any of
#   {checkout,payment,stripe,order,cart} case-insensitive)
#   THEN the task file MUST contain a `## Requirements — Playwright`
#   section with >= 2 checkbox items (happy-path + error-path minimum).
#
# Enforcement points (belt + suspenders):
#   1. hcf:plan-create — after writing each task file, run this guard.
#      Refuse to finalise the plan if any file fails.
#   2. hcf:plan-orchestrate — before spawning tdd-worker for each ready
#      task, run this guard. Catches a worker who self-edited the task
#      file to dodge the floor after authoring.
#
# Usage:
#   playwright-floor-guard.sh <task-file-path>       # single file check
#   playwright-floor-guard.sh --plan <plan-dir-path> # all NNN-*.md files in dir
#
# Exit codes:
#   0 = pass (task not a floor-domain, OR is floor-domain and meets floor)
#   2 = fail (floor-domain task with < 2 Playwright items) — blocks caller
#   1 = argument error (usage / missing file)
#
# Not blocked by CLAUDE_TREE_GUARD_ALLOWED or similar — this guard is
# quality-of-coverage, not tree-safety, and has no legitimate bypass.

set -u

# NOTE: these two constants must stay byte-for-byte in sync with the actual
# task-file template in hcf:plan-create (plan-create-diff.md). The template
# emits `**Domain**: <value>` (bold markdown, capitalized) and `## Requirements
# — Playwright ...` (level-2 heading, trailing text allowed after the match).
# A 2026-08-06 draft of this script used `^domain:` (no bold, lowercase-only
# anchor) and `### Requirements — Playwright` (level-3) — neither ever matched
# a real template-generated file: the tag check silently never fired (floor
# silently skipped on untitled floor-domain tasks) and the heading check
# always returned a 0 count (every floor-domain task permanently blocked).
# Caught before landing — no live task file was ever run through the broken
# version.
FLOOR_DOMAINS_TAG_RE='\*\*Domain\*\*:[[:space:]]*(checkout|payment|order)\b'
FLOOR_DOMAINS_GREP_RE='(checkout|payment|stripe|order|cart)'
PLAYWRIGHT_SECTION_HDR='## Requirements — Playwright'
MIN_FLOOR=2

usage() {
    echo "usage: $0 <task-file>            check single task file" >&2
    echo "       $0 --plan <plan-dir>      check all NNN-*.md in dir" >&2
    exit 1
}

file_is_floor_domain() {
    local file="$1"
    local title_line basename_only
    title_line=$(head -1 "$file" 2>/dev/null || true)
    basename_only=$(basename "$file")

    # Backstop grep: title OR filename (not full path — plan directory names
    # like "vt-payment-links" would otherwise flag every file in the plan
    # regardless of content) matches floor-domain keyword (case-insensitive)
    if printf '%s\n%s\n' "$basename_only" "$title_line" | grep -Eqi "$FLOOR_DOMAINS_GREP_RE"; then
        return 0
    fi

    # Frontmatter tag: `domain: <one-of-set>`
    if grep -Eiq "$FLOOR_DOMAINS_TAG_RE" "$file"; then
        return 0
    fi

    return 1
}

file_has_jsunit_bucket() {
    grep -Fq "## Requirements — JS unit" "$1"
}

count_playwright_requirements() {
    local file="$1"
    # Count `- [ ]` OR `- [x]` items inside the Playwright section only.
    # Section runs from the `## Requirements — Playwright ...` line (matched
    # as a prefix, so trailing text like "(DOM + real integration)" is fine)
    # to the next level-2 `## ` heading OR end of file.
    awk -v hdr="$PLAYWRIGHT_SECTION_HDR" '
        $0 ~ hdr { in_section = 1; next }
        in_section && /^## / { in_section = 0 }
        in_section && /^-[[:space:]]+\[[ xX]\][[:space:]]+/ { count++ }
        END { print count + 0 }
    ' "$file"
}

check_file() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "$0: file not found: $file" >&2
        return 1
    fi

    if ! file_is_floor_domain "$file"; then
        # Not a floor-domain task — no floor enforced.
        return 0
    fi

    if ! file_has_jsunit_bucket "$file"; then
        # Backend-only Rule-3 task (schema, settle engine, webhook observer,
        # cron, ...): never had a JS-unit bucket to migrate browser
        # assertions out of, so the floor's failure mode (assertions
        # migrated into JS-unit, browser coverage silently dropped) cannot
        # apply. A worker that later deletes Playwright items while keeping
        # the JS-unit bucket still trips this guard; full flatten to
        # backend-only is caught by the pre-batch review agent, not here.
        return 0
    fi

    local pw_count
    pw_count=$(count_playwright_requirements "$file")

    if [ "$pw_count" -lt "$MIN_FLOOR" ]; then
        cat >&2 <<EOF
BLOCKED by playwright-floor-guard.sh: floor-domain task under Playwright coverage floor.

  Task file: $file
  Playwright requirements: $pw_count (minimum: $MIN_FLOOR — happy-path + error-path)

Money-moving surfaces (checkout/payment/order/cart) MUST retain end-to-end
browser coverage even after the JS-unit-first shift. Prevention rule:
prose self-attestation ("why not JS unit") is not sufficient — deterministic
hook enforces this at plan-create + plan-orchestrate.

Fix: author >=2 items under '## Requirements — Playwright' in this task file
     (typical shape: 1 happy-path + 1 error-path). Then retry.

Do NOT work around: this guard runs at both plan-create AND
plan-orchestrate; a worker that edits the task file to remove items
still trips at orchestrate-time. See host graphiti episodes
2026-08-06T14:45:00Z + 2026-08-06T15:00:00Z for the rationale.
EOF
        return 2
    fi

    return 0
}

check_plan_dir() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        echo "$0: plan dir not found: $dir" >&2
        return 1
    fi

    local failed=0
    for file in "$dir"/[0-9][0-9][0-9]-*.md; do
        [ -f "$file" ] || continue
        if ! check_file "$file"; then
            failed=1
        fi
    done

    return $failed
}

# ------------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------------

[ "$#" -ge 1 ] || usage

case "$1" in
    --plan)
        [ "$#" -eq 2 ] || usage
        check_plan_dir "$2"
        exit $?
        ;;
    -*)
        usage
        ;;
    *)
        [ "$#" -eq 1 ] || usage
        check_file "$1"
        exit $?
        ;;
esac
