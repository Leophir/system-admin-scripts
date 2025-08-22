#!/bin/bash

# Common functions library for DietPi scripts

# Load environment variables
load_env() {
    local env_file="${1:-$HOME/.env}"
    if [ -f "$env_file" ]; then
        set -a
        source "$env_file"
        set +a
    fi
}

# Send telegram message with retry
send_telegram() {
    local message="$1"
    local max_retries="${2:-3}"
    local retry_delay="${3:-2}"
    
    # Ensure we have credentials
    if [ -z "${BOT_TOKEN:-}" ] || [ -z "${CHAT_ID:-}" ]; then
        echo "Error: BOT_TOKEN or CHAT_ID not set" >&2
        return 1
    fi
    
    for i in $(seq 1 $max_retries); do
        if curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d chat_id="${CHAT_ID}" \
            -d text="$message" \
            -d parse_mode="HTML" \
            --connect-timeout 10 \
            --max-time 30 >/dev/null 2>&1; then
            return 0
        fi
        
        [ $i -lt $max_retries ] && sleep $retry_delay
    done
    
    echo "Failed to send Telegram message after $max_retries attempts" >&2
    return 1
}

# Log with timestamp
log_message() {
    local message="$1"
    local log_file="${2:-/var/log/script.log}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$log_file"
}

# Rotate log file if too large
rotate_log() {
    local log_file="$1"
    local max_size="${2:-10485760}"  # 10MB default
    
    if [ -f "$log_file" ]; then
        # Get file size using portable approach
        local file_size
        if command -v stat >/dev/null 2>&1; then
            # Try Linux stat first, then BSD stat
            file_size=$(stat -c%s "$log_file" 2>/dev/null || stat -f%z "$log_file" 2>/dev/null || echo 0)
        else
            # Fallback to wc if stat is not available
            file_size=$(wc -c < "$log_file" 2>/dev/null || echo 0)
        fi
        
        if [ "$file_size" -gt "$max_size" ]; then
            mv "$log_file" "${log_file}.old"
            gzip -f "${log_file}.old"
            return 0
        fi
    fi
    return 1
}

# Check if process is running
is_process_running() {
    local process_name="$1"
    pgrep -f "$process_name" >/dev/null 2>&1
}

# Get system load percentage
get_system_load() {
    local cores=$(nproc)
    local load=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    echo "scale=2; ($load / $cores) * 100" | bc
}

# Format bytes to human readable
format_bytes() {
    local bytes=$1
    if [ $bytes -gt 1073741824 ]; then
        echo "$(echo "scale=2; $bytes/1073741824" | bc)GB"
    elif [ $bytes -gt 1048576 ]; then
        echo "$(echo "scale=2; $bytes/1048576" | bc)MB"
    elif [ $bytes -gt 1024 ]; then
        echo "$(echo "scale=2; $bytes/1024" | bc)KB"
    else
        echo "${bytes}B"
    fi
}

# Check disk space
check_disk_space() {
    local path="${1:-/}"
    local threshold="${2:-90}"
    
    local usage=$(df -h "$path" | awk 'NR==2 {print $5}' | sed 's/%//')
    if [ $usage -ge $threshold ]; then
        return 1
    fi
    return 0
}

# Export functions for use in subshells
export -f send_telegram log_message rotate_log is_process_running get_system_load format_bytes check_disk_space