#!/bin/bash
set -euo pipefail

source /root/scripts/common_functions.sh
load_env /root/.env

LOG_FILE="/var/log/container_monitor.log"

# Skip if a backup is in progress
if [ -f /tmp/backup_running ]; then
    log_message "Backup in progress, skipping container check" "$LOG_FILE"
    exit 0
fi

exited_containers=$(docker ps -a --filter "status=exited" --format '{{.Names}}')

if [ -n "$exited_containers" ]; then
    log_message "Found exited containers: $exited_containers" "$LOG_FILE"
    echo "$exited_containers"
    while IFS= read -r container_name; do
        echo "$(date): Restarting container: $container_name"
        send_telegram "🚨 Container '$container_name' was down. Restarting..."
        if docker restart "$container_name"; then
            echo "$(date): Successfully restarted $container_name"
            send_telegram "✅ Container '$container_name' restarted successfully"
        else
            echo "$(date): Failed to restart $container_name" >&2
            send_telegram "❌ Failed to restart container '$container_name'!"
        fi
    done <<< "$exited_containers"
else
    echo "$(date): All containers are running"
fi
