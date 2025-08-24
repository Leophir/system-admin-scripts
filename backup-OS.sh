#!/bin/bash
set -euo pipefail

# Load shared functions and environment
source /root/scripts/common_functions.sh
load_env /root/.env

# Now BOT_TOKEN and CHAT_ID are available
BOT_TOKEN="${BOT_TOKEN:?Telegram bot token not set}"
CHAT_ID="${CHAT_ID:?Telegram chat ID not set}"

# Configurations
BACKUP_DIR="/srv/OneDrive/PCBOX-Backup"
DATE=$(date +%Y-%m-%d)
BACKUP_FILE="$BACKUP_DIR/dietpi-backup-$DATE.tar.zst"
LOG_FILE="/root/backup-OS.log"

# Required commands check
for cmd in tar zstd curl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd not found!"; exit 1; }
done

# Set compression level
COMPRESSION_LEVEL="${ZSTD_LEVEL:-3}"

mkdir -p "$BACKUP_DIR"

log_message "Starting OS backup..." "$LOG_FILE"
log_message "Cleaning up old backups..." "$LOG_FILE"

find "$BACKUP_DIR" -maxdepth 1 -type f -name "dietpi-backup-*.tar.zst" -mtime +${BACKUP_RETENTION_DAYS:-5} -print -delete >> "$LOG_FILE" 2>&1

START_TIME=$(date +%s)

# Remove existing backup file if it exists
if [ -f "$BACKUP_FILE" ]; then
    log_message "Removing existing backup file: $BACKUP_FILE" "$LOG_FILE"
    rm -f "$BACKUP_FILE"
fi

if tar \
    --exclude=/mnt \
    --exclude=/srv \
	--exclude=/root/YGG-Auto-Up \
    --exclude=/proc \
    --exclude=/sys \
    --exclude=/dev \
    --exclude=/run \
    --exclude=/tmp \
    --exclude=/var/tmp \
    --exclude=/var/cache \
    --exclude=/lost+found \
    -cvf - / | zstd -T$(nproc) -${COMPRESSION_LEVEL} -f -o "$BACKUP_FILE" >> "$LOG_FILE" 2>&1; then

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    TIME_TAKEN=$(printf "%02d:%02d:%02d" $((DURATION/3600)) $(((DURATION%3600)/60)) $((DURATION%60)))
    MESSAGE="✅ Backup completed successfully: $(basename $BACKUP_FILE)
Duration: $TIME_TAKEN
Size: $(du -h "$BACKUP_FILE" | cut -f1)"
    log_message "Backup completed successfully. Duration: $TIME_TAKEN" "$LOG_FILE"
    send_telegram "$MESSAGE" || log_message "Failed to send success notification" "$LOG_FILE"
else
    log_message "Backup failed!" "$LOG_FILE"
    send_telegram "❌ OS Backup failed on $(hostname)!" || log_message "Failed to send failure notification" "$LOG_FILE"
    exit 1
fi

# Rotate log if needed
rotate_log "$LOG_FILE"