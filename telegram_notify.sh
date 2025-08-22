#!/bin/bash
set -euo pipefail

source /root/scripts/common_functions.sh
load_env /root/.env

BOT_TOKEN="${BOT_TOKEN:?Telegram bot token not set}"
CHAT_ID="${CHAT_ID:?Telegram chat ID not set}"

if [ $# -eq 0 ]; then
    echo "Usage: $0 \"message to send\"" >&2
    exit 1
fi

MESSAGE="$1"
MAX_RETRIES=3
RETRY_DELAY=2
for i in $(seq 1 $MAX_RETRIES); do
    if curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d text="$MESSAGE" \
        -d parse_mode="HTML" \
        --connect-timeout 10 \
        --max-time 30; then
        exit 0
    fi
    [ $i -lt $MAX_RETRIES ] && sleep $RETRY_DELAY
done
echo "Failed to send Telegram message after $MAX_RETRIES attempts" >&2
exit 1
