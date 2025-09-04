#!/bin/bash
#
# CACHE CONTROL - Master control script for Jellyfin media cache system
# 
# Commands:
#   status      - Show cache status and statistics
#   enable      - Enable caching system (starts creating symlinks)
#   disable     - Disable caching (keeps existing cache)
#   clear       - Remove all cache symlinks
#   space       - Show space usage
#   health      - Check cache health
#   top [n]     - Show top N cached items (default: 10)
#   rollback    - Complete system rollback
#   activate-mount - Add cache mount to Jellyfin (requires restart)
#
# Version: 1.0.0
# Created: 2025-09-03
#

set -euo pipefail

# Configuration
CACHE_BASE="/mnt/ssd500/jellyfin-cache"
MANIFEST="/mnt/ssd500/cache-management/CACHE_MANIFEST.json"
ROLLBACK_SCRIPT="/mnt/ssd500/cache-management/ROLLBACK_SCRIPT.sh"
LOG_DIR="/var/log/media-cache"
LOG_FILE="$LOG_DIR/cache-control.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
    echo -e "$*"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "${RED}Error: This script must be run as root${NC}"
        exit 1
    fi
}

# Get cache status from manifest
get_status() {
    if [[ -f "$MANIFEST" ]]; then
        jq -r '.status' "$MANIFEST" 2>/dev/null || echo "unknown"
    else
        echo "not_initialized"
    fi
}

# Update status in manifest
set_status() {
    local new_status="$1"
    if [[ -f "$MANIFEST" ]]; then
        jq --arg status "$new_status" '.status = $status' "$MANIFEST" > /tmp/manifest.tmp && mv /tmp/manifest.tmp "$MANIFEST"
        log "Status changed to: $new_status"
    fi
}

# Show cache status
show_status() {
    log "${BLUE}=== Jellyfin Media Cache Status ===${NC}"
    
    local status=$(get_status)
    case "$status" in
        active)
            log "${GREEN}● Cache Status: ACTIVE${NC}"
            ;;
        inactive)
            log "${YELLOW}● Cache Status: INACTIVE${NC}"
            ;;
        disabled)
            log "${RED}● Cache Status: DISABLED${NC}"
            ;;
        *)
            log "${RED}● Cache Status: UNKNOWN${NC}"
            ;;
    esac
    
    # Count symlinks
    local total_links=0
    local movies_links=$(find "$CACHE_BASE/movies" -type l 2>/dev/null | wc -l)
    local tv_links=$(find "$CACHE_BASE/tv" -type l 2>/dev/null | wc -l)
    local recent_links=$(find "$CACHE_BASE/recent" -type l 2>/dev/null | wc -l)
    local popular_links=$(find "$CACHE_BASE/popular" -type l 2>/dev/null | wc -l)
    total_links=$((movies_links + tv_links + recent_links + popular_links))
    
    log "\n${BLUE}Cache Contents:${NC}"
    log "  Movies:  $movies_links items"
    log "  TV:      $tv_links items"
    log "  Recent:  $recent_links items"
    log "  Popular: $popular_links items"
    log "  ${GREEN}Total:   $total_links cached items${NC}"
    
    # Check if mount is active
    local mount_status=$(docker inspect jellyfin 2>/dev/null | grep -c "/media-cache" || echo "0")
    if [[ $mount_status -gt 0 ]]; then
        log "\n${GREEN}✓ Cache mount is active in Jellyfin${NC}"
    else
        log "\n${YELLOW}⚠ Cache mount not active in Jellyfin${NC}"
        log "  Run: $0 activate-mount"
    fi
    
    # Check for cron jobs
    if crontab -l 2>/dev/null | grep -q "media-cache-manager"; then
        log "\n${GREEN}✓ Automated caching is scheduled${NC}"
    else
        log "\n${YELLOW}⚠ No automated caching scheduled${NC}"
    fi
}

# Show space usage
show_space() {
    log "${BLUE}=== Cache Space Usage ===${NC}\n"
    
    # Overall SSD usage
    local ssd_usage=$(df -h /mnt/ssd500 | tail -1)
    log "${BLUE}SSD Storage (/mnt/ssd500):${NC}"
    echo "$ssd_usage" | awk '{printf "  Total: %s  Used: %s  Available: %s  Usage: %s\n", $2, $3, $4, $5}'
    
    # Cache directory sizes
    log "\n${BLUE}Cache Directories:${NC}"
    du -sh "$CACHE_BASE"/* 2>/dev/null | while read size dir; do
        basename_dir=$(basename "$dir")
        printf "  %-10s %s\n" "$basename_dir:" "$size"
    done
    
    # Symlink statistics
    log "\n${BLUE}Symlink Statistics:${NC}"
    local total_size=0
    for link in $(find "$CACHE_BASE" -type l 2>/dev/null); do
        if [[ -e "$link" ]]; then
            target=$(readlink -f "$link")
            if [[ -f "$target" ]]; then
                size=$(stat -c%s "$target" 2>/dev/null || echo 0)
                total_size=$((total_size + size))
            fi
        fi
    done
    
    # Convert to human readable
    if [[ $total_size -gt 1073741824 ]]; then
        log "  Effective cache size: $(echo "scale=2; $total_size/1073741824" | bc) GB"
    elif [[ $total_size -gt 1048576 ]]; then
        log "  Effective cache size: $(echo "scale=2; $total_size/1048576" | bc) MB"
    else
        log "  Effective cache size: $(echo "scale=2; $total_size/1024" | bc) KB"
    fi
}

# Check cache health
check_health() {
    log "${BLUE}=== Cache Health Check ===${NC}\n"
    
    local broken_links=0
    local valid_links=0
    local issues=()
    
    # Check for broken symlinks
    while IFS= read -r link; do
        if [[ ! -e "$link" ]]; then
            ((broken_links++))
            issues+=("Broken link: $link")
        else
            ((valid_links++))
        fi
    done < <(find "$CACHE_BASE" -type l 2>/dev/null)
    
    if [[ $broken_links -eq 0 ]]; then
        log "${GREEN}✓ No broken symlinks found${NC}"
    else
        log "${RED}✗ Found $broken_links broken symlinks${NC}"
        for issue in "${issues[@]:0:10}"; do
            log "  $issue"
        done
        if [[ ${#issues[@]} -gt 10 ]]; then
            log "  ... and $((${#issues[@]} - 10)) more"
        fi
    fi
    
    log "Valid symlinks: $valid_links"
    
    # Check directory permissions
    if [[ -w "$CACHE_BASE" ]]; then
        log "${GREEN}✓ Cache directory is writable${NC}"
    else
        log "${RED}✗ Cache directory is not writable${NC}"
    fi
    
    # Check if NAS is mounted
    if mountpoint -q /mnt/nas; then
        log "${GREEN}✓ NAS is mounted${NC}"
    else
        log "${RED}✗ NAS is not mounted${NC}"
    fi
    
    # Check Jellyfin container
    if docker ps | grep -q jellyfin; then
        log "${GREEN}✓ Jellyfin container is running${NC}"
    else
        log "${RED}✗ Jellyfin container is not running${NC}"
    fi
    
    # Offer to clean broken links
    if [[ $broken_links -gt 0 ]]; then
        log "\n${YELLOW}Run '$0 clean' to remove broken symlinks${NC}"
    fi
}

# Show top cached items
show_top() {
    local count="${1:-10}"
    log "${BLUE}=== Top $count Cached Items (by size) ===${NC}\n"
    
    # Find all symlinks and get their target sizes
    {
        find "$CACHE_BASE" -type l 2>/dev/null | while read -r link; do
            if [[ -e "$link" ]]; then
                target=$(readlink -f "$link")
                if [[ -f "$target" ]]; then
                    size=$(stat -c%s "$target" 2>/dev/null || echo 0)
                    name=$(basename "$link")
                    echo "$size $name"
                fi
            fi
        done
    } | sort -rn | head -n "$count" | while read -r size name; do
        # Convert size to human readable
        if [[ $size -gt 1073741824 ]]; then
            human_size="$(echo "scale=2; $size/1073741824" | bc) GB"
        elif [[ $size -gt 1048576 ]]; then
            human_size="$(echo "scale=2; $size/1048576" | bc) MB"
        else
            human_size="$(echo "scale=2; $size/1024" | bc) KB"
        fi
        printf "  %-60s %10s\n" "$name" "$human_size"
    done
}

# Enable caching
enable_cache() {
    log "${YELLOW}Enabling cache system...${NC}"
    set_status "active"
    
    # Add cron jobs
    local cron_entry="0 3 * * * /root/script-repo/media-cache/media-cache-manager.sh >/dev/null 2>&1
0 4 * * * /root/script-repo/media-cache/track-recent-media.sh >/dev/null 2>&1
*/30 * * * * /root/script-repo/media-cache/cache-monitor.sh --quick-stats >/dev/null 2>&1"
    
    (crontab -l 2>/dev/null | grep -v "media-cache-manager\|track-recent-media\|cache-monitor"; echo "$cron_entry") | crontab -
    
    log "${GREEN}✓ Cache system enabled${NC}"
    log "Cron jobs scheduled for automatic caching"
}

# Disable caching
disable_cache() {
    log "${YELLOW}Disabling cache system...${NC}"
    set_status "disabled"
    
    # Remove cron jobs
    crontab -l 2>/dev/null | grep -v "media-cache-manager\|track-recent-media\|cache-monitor" | crontab - || true
    
    log "${GREEN}✓ Cache system disabled${NC}"
    log "Existing cache preserved, automatic updates stopped"
}

# Clear cache
clear_cache() {
    log "${YELLOW}Clearing all cache symlinks...${NC}"
    
    local count=0
    for dir in movies tv recent popular; do
        if [[ -d "$CACHE_BASE/$dir" ]]; then
            local dir_count=$(find "$CACHE_BASE/$dir" -type l 2>/dev/null | wc -l)
            find "$CACHE_BASE/$dir" -type l -delete 2>/dev/null || true
            count=$((count + dir_count))
            log "  Removed $dir_count items from $dir/"
        fi
    done
    
    log "${GREEN}✓ Cleared $count cached items${NC}"
}

# Clean broken symlinks
clean_broken() {
    log "${YELLOW}Cleaning broken symlinks...${NC}"
    
    local count=$(find "$CACHE_BASE" -xtype l 2>/dev/null | wc -l)
    find "$CACHE_BASE" -xtype l -delete 2>/dev/null || true
    
    log "${GREEN}✓ Removed $count broken symlinks${NC}"
}

# Activate cache mount in Jellyfin
activate_mount() {
    log "${YELLOW}Activating cache mount in Jellyfin...${NC}"
    log "${RED}WARNING: This will restart Jellyfin (30-60 seconds downtime)${NC}"
    
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Cancelled"
        exit 0
    fi
    
    # Check if mount already exists
    if docker inspect jellyfin 2>/dev/null | grep -q "/media-cache"; then
        log "${GREEN}Cache mount already active${NC}"
        exit 0
    fi
    
    log "${YELLOW}Note: You need to manually add this volume to your Jellyfin container:${NC}"
    log "  ${BLUE}/mnt/ssd500/jellyfin-cache:/media-cache:ro${NC}"
    log "\nFor docker run:"
    log "  Add: -v /mnt/ssd500/jellyfin-cache:/media-cache:ro"
    log "\nFor docker-compose:"
    log "  Add under volumes:"
    log "    - /mnt/ssd500/jellyfin-cache:/media-cache:ro"
    log "\nThen restart Jellyfin with: docker restart jellyfin"
}

# Main command handler
main() {
    check_root
    
    case "${1:-status}" in
        status)
            show_status
            ;;
        enable)
            enable_cache
            ;;
        disable)
            disable_cache
            ;;
        clear)
            clear_cache
            ;;
        clean)
            clean_broken
            ;;
        space)
            show_space
            ;;
        health)
            check_health
            ;;
        top)
            show_top "${2:-10}"
            ;;
        activate-mount)
            activate_mount
            ;;
        rollback)
            log "${RED}Starting complete system rollback...${NC}"
            exec "$ROLLBACK_SCRIPT"
            ;;
        *)
            echo "Usage: $0 {status|enable|disable|clear|clean|space|health|top [n]|activate-mount|rollback}"
            echo ""
            echo "Commands:"
            echo "  status         - Show cache status and statistics"
            echo "  enable         - Enable caching system"
            echo "  disable        - Disable caching (keeps existing cache)"
            echo "  clear          - Remove all cache symlinks"
            echo "  clean          - Remove broken symlinks"
            echo "  space          - Show space usage"
            echo "  health         - Check cache health"
            echo "  top [n]        - Show top N cached items (default: 10)"
            echo "  activate-mount - Add cache mount to Jellyfin"
            echo "  rollback       - Complete system rollback"
            exit 1
            ;;
    esac
}

main "$@"