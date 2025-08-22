#!/bin/bash
set -euo pipefail

source /root/scripts/common_functions.sh
load_env /root/.env

# CONFIGURATION
SERVICE_NAME="${ONEDRIVE_SERVICE:-onedrive-upload.service}"
LOG_FILE="/root/onedrive_monitor.log"

# Rotate log if it's too large
rotate_log "$LOG_FILE"

# Check if the service is running
STATUS=$(systemctl is-active $SERVICE_NAME)

if [ "$STATUS" != "active" ]; then
    MESSAGE="⚠️ OneDrive Service Alert: $SERVICE_NAME is DOWN on $(hostname). Trying to restart the service..."
    log_message "$MESSAGE" "$LOG_FILE"

    # Attempt to restart the service
    systemctl restart $SERVICE_NAME
    sleep 10  # Give it time to restart

    # Recheck the service status
    NEW_STATUS=$(systemctl is-active $SERVICE_NAME)
    if [ "$NEW_STATUS" != "active" ]; then
        MESSAGE="❌ OneDrive Service FAILED to restart! Immediate attention required on $(hostname)."
    else
        MESSAGE="✅ OneDrive Service was successfully restarted and is now running properly."
    fi

    # Send Telegram alert
    send_telegram "$MESSAGE" || log_message "Failed to send Telegram notification" "$LOG_FILE"
else
    MESSAGE="✅ OneDrive Service is running properly."
fi

# Log the message to the log file
log_message "$MESSAGE" "$LOG_FILE"
