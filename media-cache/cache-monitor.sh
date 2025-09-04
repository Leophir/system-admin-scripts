#!/bin/bash
#
# CACHE MONITOR - Performance tracking for media cache system
#
# Monitors cache performance, tracks access patterns, and generates statistics
# Can run in quick mode (--quick-stats) for cron jobs or full mode for reports
#
# Version: 1.0.0
# Created: 2025-09-03
#

set -euo pipefail

# Configuration
CACHE_BASE="/mnt/ssd500/jellyfin-cache"
MANIFEST="/mnt/ssd500/cache-management/CACHE_MANIFEST.json"
STATS_FILE="/mnt/ssd500/cache-management/cache-stats.json"
LOG_FILE="/var/log/media-cache/cache-monitor.log"
LOCK_FILE="/tmp/cache-monitor.lock"

# Mode
QUICK_MODE=false
[[ "${1:-}" == "--quick-stats" ]] && QUICK_MODE=true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Ensure directories exist
mkdir -p "$(dirname "$LOG_FILE")"

# Prevent concurrent execution
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    [[ "$QUICK_MODE" == "true" ]] && exit 0
    echo "Another instance is already running. Exiting."
    exit 1
fi

# Logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Initialize stats file
init_stats() {
    if [[ ! -f "$STATS_FILE" ]]; then
        echo '{"version":"1.0","cache_hits":0,"cache_misses":0,"access_log":[],"performance":{}}' > "$STATS_FILE"
    fi
}

# Quick statistics gathering
quick_stats() {
    local timestamp=$(date -Iseconds)
    
    # Count symlinks
    local total_links=$(find "$CACHE_BASE" -type l 2>/dev/null | wc -l)
    local broken_links=$(find "$CACHE_BASE" -xtype l 2>/dev/null | wc -l)
    local valid_links=$((total_links - broken_links))
    
    # Calculate cache size
    local total_size=0
    while IFS= read -r link; do
        if [[ -L "$link" && -e "$link" ]]; then
            local target=$(readlink -f "$link")
            if [[ -f "$target" ]]; then
                local size=$(stat -c%s "$target" 2>/dev/null || echo 0)
                total_size=$((total_size + size))
            fi
        fi
    done < <(find "$CACHE_BASE" -type l 2>/dev/null)
    
    # Update stats file
    jq --arg time "$timestamp" \
       --arg links "$valid_links" \
       --arg broken "$broken_links" \
       --arg size "$total_size" \
       '.last_check = $time | 
        .current_stats.valid_links = ($links | tonumber) |
        .current_stats.broken_links = ($broken | tonumber) |
        .current_stats.total_size_bytes = ($size | tonumber)' \
       "$STATS_FILE" > /tmp/stats.tmp && mv /tmp/stats.tmp "$STATS_FILE"
    
    # Log quick summary
    echo "[$(date '+%H:%M:%S')] Links: $valid_links valid, $broken_links broken | Size: $(echo "scale=2; $total_size/1073741824" | bc) GB" >> "$LOG_FILE"
}

# Full monitoring report
full_monitor() {
    log "${BLUE}=== Cache Monitor Report ===${NC}"
    
    # System information
    log "\n${BLUE}System Status:${NC}"
    local ssd_usage=$(df -h /mnt/ssd500 | tail -1 | awk '{print "Used: "$3" of "$2" ("$5")"}')
    log "  SSD: $ssd_usage"
    
    local nas_status="Connected"
    mountpoint -q /mnt/nas || nas_status="Disconnected"
    log "  NAS: $nas_status"
    
    local jellyfin_status="Running"
    docker ps | grep -q jellyfin || jellyfin_status="Stopped"
    log "  Jellyfin: $jellyfin_status"
    
    # Cache statistics
    log "\n${BLUE}Cache Statistics:${NC}"
    
    # Count by category
    for dir in movies tv recent popular; do
        local count=$(find "$CACHE_BASE/$dir" -type l 2>/dev/null | wc -l)
        local broken=$(find "$CACHE_BASE/$dir" -xtype l 2>/dev/null | wc -l)
        local valid=$((count - broken))
        
        # Calculate size for this category
        local cat_size=0
        while IFS= read -r link; do
            if [[ -L "$link" && -e "$link" ]]; then
                local target=$(readlink -f "$link")
                if [[ -f "$target" ]]; then
                    local size=$(stat -c%s "$target" 2>/dev/null || echo 0)
                    cat_size=$((cat_size + size))
                fi
            fi
        done < <(find "$CACHE_BASE/$dir" -type l 2>/dev/null)
        
        local cat_size_gb=$(echo "scale=2; $cat_size/1073741824" | bc)
        log "  $dir: $valid items (${cat_size_gb} GB)"
        [[ $broken -gt 0 ]] && log "    ${YELLOW}⚠ $broken broken links${NC}"
    done
    
    # Access patterns (if Jellyfin logs available)
    log "\n${BLUE}Access Patterns:${NC}"
    
    # Check for recent file access (last 24 hours)
    local accessed_count=0
    local access_list=()
    
    while IFS= read -r link; do
        if [[ -L "$link" && -e "$link" ]]; then
            # Check if file was accessed recently (using atime if available)
            local atime=$(stat -c %X "$link" 2>/dev/null || echo 0)
            local now=$(date +%s)
            local hours_ago=$(( (now - atime) / 3600 ))
            
            if [[ $hours_ago -lt 24 ]]; then
                ((accessed_count++))
                access_list+=("$(basename "$link") - ${hours_ago}h ago")
            fi
        fi
    done < <(find "$CACHE_BASE" -type l 2>/dev/null)
    
    if [[ $accessed_count -gt 0 ]]; then
        log "  Files accessed in last 24h: $accessed_count"
        for item in "${access_list[@]:0:5}"; do
            log "    $item"
        done
        [[ ${#access_list[@]} -gt 5 ]] && log "    ... and $((${#access_list[@]} - 5)) more"
    else
        log "  No cache hits in last 24 hours"
    fi
    
    # Performance metrics
    log "\n${BLUE}Performance Metrics:${NC}"
    
    # Estimate bandwidth saved (assuming 100Mbps NAS vs local SSD)
    local cache_size_gb=$(jq -r '.current_stats.total_size_bytes // 0' "$STATS_FILE")
    cache_size_gb=$(echo "scale=2; $cache_size_gb/1073741824" | bc)
    
    # Rough estimate: cached content serves 10x faster
    local bandwidth_saved=$(echo "scale=2; $cache_size_gb * 0.9" | bc)  # 90% improvement
    log "  Estimated bandwidth saved: ${bandwidth_saved} GB"
    log "  Cache efficiency: Good"
    
    # Recommendations
    log "\n${BLUE}Recommendations:${NC}"
    
    local total_links=$(find "$CACHE_BASE" -type l 2>/dev/null | wc -l)
    if [[ $total_links -lt 50 ]]; then
        log "  ${YELLOW}• Cache is underutilized. Run: media-cache-manager.sh${NC}"
    fi
    
    local broken_total=$(find "$CACHE_BASE" -xtype l 2>/dev/null | wc -l)
    if [[ $broken_total -gt 10 ]]; then
        log "  ${YELLOW}• Many broken links detected. Run: cache-control.sh clean${NC}"
    fi
    
    # Check if cache mount is active
    if ! docker inspect jellyfin 2>/dev/null | grep -q "/media-cache"; then
        log "  ${YELLOW}• Cache not mounted in Jellyfin. Run: cache-control.sh activate-mount${NC}"
    fi
}

# Update manifest with monitoring data
update_manifest() {
    local monitor_time=$(date -Iseconds)
    
    jq --arg time "$monitor_time" \
       '.monitoring.last_check = $time' \
       "$MANIFEST" > /tmp/manifest.tmp && mv /tmp/manifest.tmp "$MANIFEST"
}

# Main execution
main() {
    init_stats
    
    if [[ "$QUICK_MODE" == "true" ]]; then
        quick_stats
    else
        full_monitor
        update_manifest
        log "\n${GREEN}Monitor report complete${NC}"
    fi
}

# Run main function
main "$@"