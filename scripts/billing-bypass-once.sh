#!/bin/bash
# One-shot mid-session bypass for billing-precompact-guard's manual /compact
# block. Run this from inside the blocked project (host or container — same
# script path is mounted at /var/www/html/.claude/scripts/ in every DDEV
# container) right before running /compact again:
#
#   bash ~/claude-skills-central/scripts/billing-bypass-once.sh
#
# Unlike BILLING_COMPACT_ALLOWED=1 (which only works if exported BEFORE the
# session starts — env vars can't change mid-session), this works immediately,
# mid-session, no restart. It's consumed (deleted) by the next manual compact
# it clears — a "just this once" pass, not a standing off switch. The gate
# it bypasses is a soft reminder (uninvoiced-but-deployed tickets), not a
# safety-critical guard, so an easy one-shot escape hatch is appropriate here
# (unlike merge-guard/push-guard, which don't get one).
set -e
CWD="${1:-$PWD}"
python3 -c "
import sys
sys.path.insert(0, '$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)')
from billing_context_lib import bypass_marker_path
p = bypass_marker_path('$CWD')
p.touch()
print(f'Bypass marker set for {\"$CWD\"} -> {p}')
print('Next manual /compact in this project will pass through once, then re-arm.')
"
