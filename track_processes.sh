#!/bin/bash
set -euo pipefail

source /root/scripts/common_functions.sh
load_env /root/.env

LOG_FILE="/var/log/top_processes.csv"
LOG_DIR=$(dirname "$LOG_FILE")
MAX_SIZE=$((50 * 1024 * 1024))  # 50MB max log size

mkdir -p "$LOG_DIR"

if [ ! -f "$LOG_FILE" ]; then
    echo "timestamp,cpu_percent,mem_percent,command" > "$LOG_FILE"
fi

if [ -f "$LOG_FILE" ]; then
    # Get file size using portable approach
    local file_size
    if command -v stat >/dev/null 2>&1; then
        file_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    else
        file_size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    fi
    
    if [ "$file_size" -gt $MAX_SIZE ]; then
        mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d_%H%M%S)"
        echo "timestamp,cpu_percent,mem_percent,command" > "$LOG_FILE"
        ls -t "${LOG_FILE}".* 2>/dev/null | tail -n +6 | xargs -r rm -f
    fi
fi

ps -eo pid,%cpu,%mem,comm --sort=-%cpu | \
    awk -v ts=$(date +%s) 'NR>1 && NR<=11 {
        gsub(/,/, "_", $4)
        printf "%d,%.1f,%.1f,%s\n", ts, $2, $3, $4
    }' >> "$LOG_FILE"
