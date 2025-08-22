#!/bin/bash
set -euo pipefail
source /root/scripts/common_functions.sh
load_env /root/.env

# Paths
SOURCE_DIR="/mnt/dietpi_userdata/docker-files/"
DEST_DIR="/srv/OneDrive/PCBOX-Backup"
DATE=$(date +%Y-%m-%d_%H-%M)
TEMP_BACKUP="$DEST_DIR/new-backup-$DATE.tar.zst"
FINAL_BACKUP="$DEST_DIR/docker-files-$DATE.tar.zst"
TELEGRAM_SCRIPT="/root/telegram_notify.sh"
MAX_DOWNTIME=900
BACKUP_IN_PROGRESS="/tmp/backup_running"

# Start time
START_TIME=$(date +%s)
mkdir -p "$DEST_DIR"

# Create backup in-progress flag
touch "$BACKUP_IN_PROGRESS"

# Cleanup function
cleanup() {
    rm -f "$BACKUP_IN_PROGRESS"
}
trap cleanup EXIT

# Stop ALL Docker containers
echo "🛑 Stopping all containers..."
ALL_CONTAINERS=$(docker ps -a -q)
if [ -n "$ALL_CONTAINERS" ]; then
    docker stop $ALL_CONTAINERS 2>/dev/null || true
else
    echo "No containers to stop."
fi

# Timeout fallback
(
    sleep $MAX_DOWNTIME
    if kill -0 $$ 2>/dev/null; then
        echo "⏰ Timeout reached. Restarting containers..."
        if [ -n "$ALL_CONTAINERS" ]; then
            docker start $ALL_CONTAINERS 2>/dev/null || true
        fi
        send_telegram "⚠️ WARNING: Backup took too long. Containers restarted after $MAX_DOWNTIME seconds."
    fi
) &
TIMEOUT_PID=$!

# Backup with better compression
echo "📦 Creating compressed backup..."
nice -n -20 ionice -c 1 -n 0 tar --mode='ugo=rwX' --owner=0 --group=0 \
    --exclude='./wordpress' \
    --exclude='./jellyfin/config/cache' \
    --exclude='./jellyfin/config/metadata' \
    --exclude='./jellyfin/cache/transcodes' \
    --exclude='./ipc-socket' \
    -I 'zstd -T4 -9' -cf "$TEMP_BACKUP" -C /mnt/dietpi_userdata/docker-files .
BACKUP_STATUS=$?

# Kill timeout
kill $TIMEOUT_PID 2>/dev/null || true

# Restart ALL Docker containers
if [ -n "$ALL_CONTAINERS" ]; then
    echo "🚀 Restarting all containers..."
    docker start $ALL_CONTAINERS 2>/dev/null || true
else
    echo "No containers to restart."
fi

# Permissions & move
chmod 644 "$TEMP_BACKUP"
mv "$TEMP_BACKUP" "$FINAL_BACKUP"

# Calculate backup size using portable approach
if command -v stat >/dev/null 2>&1; then
    # Try BSD stat first, then Linux stat
    BACKUP_SIZE=$(stat -f%z "$FINAL_BACKUP" 2>/dev/null || stat -c%s "$FINAL_BACKUP" 2>/dev/null || echo "0")
else
    # Fallback to wc if stat is not available
    BACKUP_SIZE=$(wc -c < "$FINAL_BACKUP" 2>/dev/null || echo "0")
fi
BACKUP_SIZE_MB=$((BACKUP_SIZE / 1024 / 1024))

# Duration
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
DURATION_FORMATTED=$(printf "%02d:%02d:%02d" $((DURATION/3600)) $(((DURATION%3600)/60)) $((DURATION%60)))

# Notify Telegram
if [ $BACKUP_STATUS -ne 0 ]; then
    send_telegram "❌ Backup FAILED on $(hostname) at $(date)\n⏳ Duration: $DURATION_FORMATTED"
else
    send_telegram "✅ Backup SUCCESS on $(hostname) at $(date)\n⏳ Duration: $DURATION_FORMATTED\n📦 Size: ${BACKUP_SIZE_MB}MB\n📤 OneDrive sync will start automatically"
fi

# Rotation: keep 5 newest
BACKUP_FILES=($(ls -1t "$DEST_DIR"/docker-files-*.tar.zst 2>/dev/null || true))
if [ "${#BACKUP_FILES[@]}" -gt 5 ]; then
    for f in "${BACKUP_FILES[@]:5}"; do
        echo "🧹 Deleting old backup: $f"
        rm -f "$f"
    done
fi