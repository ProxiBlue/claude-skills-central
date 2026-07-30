#!/bin/bash
ALERT_FILE="/tmp/server-alert.txt"
LOGFILE="/tmp/status-monitor.log"

# Run Claude Code with your status page check
OUTPUT=$(claude -p "Check the status of my Magento servers and any critical services" 2>&1)

if echo "$OUTPUT" | grep -iE "(down|outage|degraded|incident|error|unavailable|failing)"; then
    {
        echo -e "\033[1;31m"
        echo "╔═══════════════════════════════════════════╗"
        echo "║     🚨  SERVER DOWN ALERT  🚨            ║"
        echo "╚═══════════════════════════════════════════╝"
        echo -e "\033[0m"
        echo "Detected at: $(date)"
        echo "$OUTPUT"
    } | tee -a "$LOGFILE" > "$ALERT_FILE"
else
    echo "$(date): All services operational" >> "$LOGFILE"
    rm -f "$ALERT_FILE"
fi
