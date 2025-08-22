#!/bin/bash
set -euo pipefail

source /root/scripts/common_functions.sh
load_env /root/.env

BOT_TOKEN="${BOT_TOKEN:?Telegram bot token not set}"
CHAT_ID="${CHAT_ID:?Telegram chat ID not set}"
CPU_THRESHOLD="${CPU_THRESHOLD:-85}"
RAM_THRESHOLD="${RAM_THRESHOLD:-90}"
DISK_THRESHOLD="${DISK_THRESHOLD:-90}"

# Répertoire pour les données historiques
DATA_DIR="/var/log/system_stats"
mkdir -p "$DATA_DIR"
CPU_HISTORY="$DATA_DIR/cpu_history.log"
RAM_HISTORY="$DATA_DIR/ram_history.log"
DISK_HISTORY="$DATA_DIR/disk_history.log"
touch "$CPU_HISTORY" "$RAM_HISTORY" "$DISK_HISTORY"

# Fonction pour barres simples et propres
generate_bar() {
    local value=$1
    local width=15
    local filled=$((value * width / 100))
    local bar=""
    
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=filled; i<width; i++)); do bar+="░"; done
    echo "$bar"
}

# Fonction pour tendance simple
generate_trend() {
    local file=$1
    local current=$2
    
    if [[ ! -f "$file" ]]; then
        echo "—"
        return
    fi
    
    local previous=$(tail -n 2 "$file" 2>/dev/null | head -1 | cut -d',' -f2)
    
    if [[ -z "$previous" ]]; then
        echo "—"
    else
        # Use bash arithmetic instead of bc for better portability
        local diff=$(( ${current%.*} - ${previous%.*} ))
        if [[ $diff -gt 2 ]]; then
            echo "↗"
        elif [[ $diff -lt -2 ]]; then
            echo "↘"
        else
            echo "→"
        fi
    fi
}

format_size() {
    local size=$1
    if [ $size -gt 1024 ]; then
        # Use bash arithmetic for better portability
        echo "$((size * 10 / 1024)).$(((size * 10 / 1024) % 10))GB"
    else
        echo "${size}MB"
    fi
}

# === COLLECTE DES MÉTRIQUES ===

# CPU Usage
# More accurate CPU usage calculation
CPU_USAGE=$(top -bn2 -d0.5 | grep "Cpu(s)" | tail -1 | awk '{print 100-$8}' | cut -d'.' -f1)
echo "$(date +%s),$CPU_USAGE" >> "$CPU_HISTORY"

# RAM Usage
RAM_INFO=$(free -m)
RAM_TOTAL=$(echo "$RAM_INFO" | awk '/Mem:/ {print $2}')
RAM_AVAILABLE=$(echo "$RAM_INFO" | awk '/Mem:/ {print $7}')
RAM_USED_REAL=$((RAM_TOTAL - RAM_AVAILABLE))
RAM_PERCENT=$((RAM_USED_REAL * 100 / RAM_TOTAL))
echo "$(date +%s),$RAM_PERCENT" >> "$RAM_HISTORY"

# Load Average
LOAD_1=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//' | xargs)
LOAD_5=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $2}' | sed 's/,//' | xargs)
LOAD_15=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $3}' | xargs)

# Température CPU (méthode GPT - plus précise)
if command -v sensors &> /dev/null; then
    CPU_TEMP=$(sensors | grep "Package id 0" | awk '{print $4}' | sed 's/+//')
elif [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    CPU_TEMP="$(awk '{print $1/1000}' /sys/class/thermal/thermal_zone0/temp)°C"
else
    CPU_TEMP="N/A"
fi

# Uptime
UPTIME=$(uptime -p | sed 's/up //')

# Réseau
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
[[ -z "$INTERFACE" ]] && INTERFACE="eth0"

if [[ -f "/sys/class/net/$INTERFACE/statistics/rx_bytes" ]]; then
    RX_GB=$(awk '{printf "%.1f", $1/1024/1024/1024}' "/sys/class/net/$INTERFACE/statistics/rx_bytes")
    TX_GB=$(awk '{printf "%.1f", $1/1024/1024/1024}' "/sys/class/net/$INTERFACE/statistics/tx_bytes")
else
    RX_GB="0.0"
    TX_GB="0.0"
fi

# Bandwidth actuel
BANDWIDTH="N/A"
if command -v vnstat >/dev/null 2>&1; then
    BANDWIDTH=$(vnstat -i "$INTERFACE" -tr 5 2>/dev/null | grep -E "rx|tx" | head -2 | awk '{print $2" "$3}' | paste -sd' / ' | sed 's/kbit\/s/kb\/s/g; s/Mbit\/s/Mb\/s/g')
elif command -v ifstat >/dev/null 2>&1; then
    BANDWIDTH=$(timeout 3 ifstat -i "$INTERFACE" 1 1 2>/dev/null | tail -1 | awk '{printf "%.1f/%.1f MB/s", $1/1024, $2/1024}')
fi
[[ -z "$BANDWIDTH" || "$BANDWIDTH" == "0.0/0.0 MB/s" ]] && BANDWIDTH="Idle"

# Improve process collection efficiency
TOP_PROCESSES=$(ps -eo pcpu,pmem,comm --sort=-pcpu --no-headers | head -5 | \
    awk '$1 > 0.5 || $2 > 1.0 {printf "• %s: %.1f%% CPU, %.1f%% RAM\n", $3, $1, $2}')
[[ -z "$TOP_PROCESSES" ]] && TOP_PROCESSES="• System idle"

# Usage disque (exclut /boot/efi)
DISK_INFO=""
MAX_DISK_USAGE=0

while read -r filesystem size used avail percent mountpoint; do
    [[ "$percent" =~ ^[0-9]+% ]] || continue
    
    # Exclure les partitions inutiles
    case "$mountpoint" in
        "/dev"|"/run"|"/boot/efi"|"/sys"*|"/proc"*|"/tmp") continue ;;
    esac
    
    usage_num=${percent%\%}
    [[ $usage_num -gt $MAX_DISK_USAGE ]] && MAX_DISK_USAGE=$usage_num
    
    # Nom plus lisible
    display_name="$mountpoint"
    [[ "$mountpoint" == "/" ]] && display_name="Root"
    [[ "$mountpoint" =~ ^/mnt/ ]] && display_name=$(basename "$mountpoint")
    
    DISK_INFO+="• <b>$display_name:</b> $used/$size ($percent)\n"
done <<< "$(df -h | grep -E '^/dev/' | grep -v '/boot/efi')"

echo "$(date +%s),$MAX_DISK_USAGE" >> "$DISK_HISTORY"

# Nettoyage historique
for file in "$CPU_HISTORY" "$RAM_HISTORY" "$DISK_HISTORY"; do
    [[ $(wc -l < "$file" 2>/dev/null || echo 0) -gt 1440 ]] && {
        tail -n 1440 "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    }
done

# Génération des tendances
CPU_TREND=$(generate_trend "$CPU_HISTORY" "$CPU_USAGE")
RAM_TREND=$(generate_trend "$RAM_HISTORY" "$RAM_PERCENT")
DISK_TREND=$(generate_trend "$DISK_HISTORY" "$MAX_DISK_USAGE")

# === CONSTRUCTION DU MESSAGE ===

MESSAGE="🖥️ <b>$(hostname) Status</b>

<b>⚡ CPU:</b> ${CPU_USAGE}% ${CPU_TREND}
<code>$(generate_bar ${CPU_USAGE%.*})</code>

<b>📀 RAM:</b> ${RAM_PERCENT}% ${RAM_TREND} (${RAM_USED_REAL}MB/${RAM_TOTAL}MB)
<code>$(generate_bar ${RAM_PERCENT%.*})</code>

<b>📊 Load:</b> ${LOAD_1}, ${LOAD_5}, ${LOAD_15}
<b>🌡️ Temp:</b> ${CPU_TEMP}
<b>⏰ Uptime:</b> ${UPTIME}

<b>🌐 Network:</b> ⬇️${RX_GB}GB ⬆️${TX_GB}GB
<b>📡 Current:</b> ${BANDWIDTH}

<b>💾 Storage:</b> ${DISK_TREND}
$DISK_INFO

<b>🔝 Top Processes:</b>
$TOP_PROCESSES

<i>$(date '+%d/%m/%Y %H:%M')</i>"

# === ENVOI DU RAPPORT ===

send_telegram "$MESSAGE" &

# === GESTION DES ALERTES ===

ALERT_MESSAGE="🚨 <b>ALERT: $(hostname)</b>"
ALERT_TRIGGERED=false

if [[ ${CPU_USAGE%.*} -gt $CPU_THRESHOLD ]]; then
    ALERT_MESSAGE+="\n⚡ High CPU: ${CPU_USAGE}%"
    ALERT_TRIGGERED=true
fi

if [[ ${RAM_PERCENT%.*} -gt $RAM_THRESHOLD ]]; then
    ALERT_MESSAGE+="\n📀 High RAM: ${RAM_PERCENT}%"
    ALERT_TRIGGERED=true
fi

if [[ $MAX_DISK_USAGE -ge $DISK_THRESHOLD ]]; then
    ALERT_MESSAGE+="\n💾 Low disk space: ${MAX_DISK_USAGE}%"
    ALERT_TRIGGERED=true
fi

if [[ "$ALERT_TRIGGERED" == "true" ]]; then
    send_telegram "$ALERT_MESSAGE" &
fi

wait
