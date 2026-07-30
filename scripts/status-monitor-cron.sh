#!/bin/bash
# Status Monitor Cron Script
# Uses Claude CLI with the status-page-monitoring skill to parse status pages
#
# Flow: cron -> this script -> claude (skill) -> parse -> output -> cache
#
# Run via cron: */1 * * * * /path/to/.claude/scripts/status-monitor-cron.sh

CACHE_FILE="${STATUS_CACHE_FILE:-/tmp/monitor-status.json}"
CLAUDE_CMD="${CLAUDE_CMD:-claude}"

# Call Claude CLI with the skill, requesting JSON output for the status bar
# The skill handles fetching and parsing from any supported provider
OUTPUT=$($CLAUDE_CMD --print --output-format json -p "Run /status-page-monitoring and return ONLY a JSON object with these fields: up (number of UP monitors), down (number of DOWN monitors), paused (number of PAUSED monitors), down_names (comma-separated names of DOWN monitors), error (boolean). No explanation, just JSON." 2>/dev/null)

# Check if Claude returned valid output
if [ -z "$OUTPUT" ]; then
    echo '{"up": 0, "down": 0, "paused": 0, "down_names": "", "error": true, "message": "Claude CLI failed", "timestamp": "'$(date -Iseconds)'"}' > "$CACHE_FILE"
    exit 1
fi

# Extract JSON from Claude's output (it may have markdown wrapper)
JSON=$(echo "$OUTPUT" | grep -o '{[^}]*}' | head -1)

if [ -z "$JSON" ]; then
    # Try to use full output if no JSON found
    JSON="$OUTPUT"
fi

# Add timestamp and write to cache
echo "$JSON" | jq --arg ts "$(date -Iseconds)" '. + {"timestamp": $ts}' > "$CACHE_FILE" 2>/dev/null

# Fallback if jq fails
if [ $? -ne 0 ]; then
    echo '{"up": 0, "down": 0, "paused": 0, "down_names": "", "error": true, "message": "Parse failed", "timestamp": "'$(date -Iseconds)'"}' > "$CACHE_FILE"
fi
