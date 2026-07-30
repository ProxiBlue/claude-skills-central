#!/bin/bash
# Claude Code Status Line with Monitor Status
# Combines Claude Code context with UptimeRobot monitor status

CACHE_FILE="${STATUS_CACHE_FILE:-/tmp/monitor-status.json}"

# Read Claude Code context from stdin
input=$(cat)

# Extract Claude Code info
MODEL=$(echo "$input" | jq -r '.model.display_name // "Claude"' 2>/dev/null)
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0' 2>/dev/null)

# Format cost
if [ "$COST" != "0" ] && [ "$COST" != "null" ]; then
    COST_STR=$(printf "$%.2f" "$COST")
else
    COST_STR=""
fi

# Read monitor status from cache
if [ -f "$CACHE_FILE" ]; then
    UP=$(jq -r '.up // 0' "$CACHE_FILE" 2>/dev/null)
    DOWN=$(jq -r '.down // 0' "$CACHE_FILE" 2>/dev/null)
    ERROR=$(jq -r '.error // false' "$CACHE_FILE" 2>/dev/null)
    DOWN_NAMES=$(jq -r '.down_names // ""' "$CACHE_FILE" 2>/dev/null)

    # Check cache age (warn if older than 5 minutes)
    if [ -n "$(find "$CACHE_FILE" -mmin +5 2>/dev/null)" ]; then
        MONITOR_STR="\033[33m?\033[0m stale"
    elif [ "$ERROR" = "true" ]; then
        MONITOR_STR="\033[33m!\033[0m error"
    elif [ "$DOWN" -gt 0 ]; then
        # Red for DOWN monitors
        MONITOR_STR="\033[32m$UP\033[0m \033[31m$DOWN\033[0m"
        if [ -n "$DOWN_NAMES" ]; then
            # Truncate if too long
            if [ ${#DOWN_NAMES} -gt 20 ]; then
                DOWN_NAMES="${DOWN_NAMES:0:17}..."
            fi
            MONITOR_STR="$MONITOR_STR ($DOWN_NAMES)"
        fi
    else
        # Green for all UP
        MONITOR_STR="\033[32m$UP OK\033[0m"
    fi
else
    MONITOR_STR="\033[33m-\033[0m"
fi

# Build status line
if [ -n "$COST_STR" ]; then
    echo -e "[$MODEL] $COST_STR | $MONITOR_STR"
else
    echo -e "[$MODEL] | $MONITOR_STR"
fi
