#!/bin/bash
#
# OVERSEERR CACHE SYNC
# Monitors Overseerr requests and ensures requested content gets cached
#
# This script:
# - Checks Overseerr database for recent requests
# - Monitors Radarr/Sonarr for completed downloads
# - Immediately caches new content from downloads folder
# - Focuses on user-requested content rather than "popular"
#
# Version: 1.0.0
# Created: 2025-09-03
#

set -euo pipefail

# Configuration
CACHE_BASE="/mnt/ssd500/jellyfin-cache"
OVERSEERR_DB="/mnt/dietpi_userdata/docker-files/overseerr/config/db/db.sqlite3"
RADARR_URL="http://localhost:7878"
SONARR_URL="http://localhost:8989"
DOWNLOADS_DIR="/mnt/nas/downloads"
NAS_MOVIES="/mnt/nas/movies"
NAS_TV="/mnt/nas/tv"
NAS_DOC="/mnt/nas/doc"
LOG_FILE="/var/log/media-cache/overseerr-cache-sync.log"
LOCK_FILE="/tmp/overseerr-cache-sync.lock"
MANIFEST="/mnt/ssd500/cache-management/CACHE_MANIFEST.json"

# Cache settings
MAX_CACHE_SIZE_GB=300  # Total cache size limit
RECENT_DAYS=7  # Days to keep downloads cached
MOVIE_RETENTION_DAYS=60  # Keep movies longer
TV_RETENTION_DAYS=30  # TV episodes shorter

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Ensure directories exist
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$CACHE_BASE"/{movies,tv,doc,downloads}

# Prevent concurrent execution
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "Another instance is already running. Exiting."
    exit 1
fi

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Convert bytes to GB
bytes_to_gb() {
    echo "scale=2; $1/1073741824" | bc
}

# Get current cache size
get_cache_size() {
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
    echo "$total_size"
}

# Check if SQLite is installed
check_sqlite() {
    if ! command -v sqlite3 &> /dev/null; then
        log "${YELLOW}Installing sqlite3...${NC}"
        apt-get update && apt-get install -y sqlite3
    fi
}

# Get recent Overseerr requests
get_overseerr_requests() {
    log "Checking Overseerr requests..."
    
    if [[ ! -f "$OVERSEERR_DB" ]]; then
        log "${YELLOW}Overseerr database not found${NC}"
        return
    fi
    
    # Query for recent approved requests (last 7 days)
    # This is a simplified query - actual schema may vary
    sqlite3 "$OVERSEERR_DB" <<EOF 2>/dev/null || true
.mode list
.separator "|"
SELECT 
    CASE 
        WHEN media_type = 'movie' THEN 'movie'
        WHEN media_type = 'tv' THEN 'tv'
        ELSE 'unknown'
    END as type,
    media_id,
    status,
    created_at
FROM media_request
WHERE status = 3  -- Approved/Available
    AND created_at > datetime('now', '-7 days')
ORDER BY created_at DESC
LIMIT 100;
EOF
}

# Check recent downloads folder
cache_recent_downloads() {
    log "Checking downloads folder for new content..."
    
    local cached_count=0
    local cache_size=$(get_cache_size)
    local max_size=$((MAX_CACHE_SIZE_GB * 1073741824))
    
    # Find recent downloads (movies)
    while IFS= read -r -d '' file; do
        if [[ $cache_size -ge $max_size ]]; then
            log "  Cache size limit reached"
            break
        fi
        
        local basename_file=$(basename "$file")
        local cache_path="$CACHE_BASE/downloads/movie_${basename_file}"
        
        # Skip if already cached
        if [[ -L "$cache_path" ]]; then
            continue
        fi
        
        # Create symlink
        if ln -sf "$file" "$cache_path" 2>/dev/null; then
            ((cached_count++))
            local file_size=$(stat -c%s "$file" 2>/dev/null || echo 0)
            cache_size=$((cache_size + file_size))
            log "  Cached: $basename_file"
        fi
    done < <(find "$DOWNLOADS_DIR/movies" -type f \( -name "*.mkv" -o -name "*.mp4" \) -mtime -${RECENT_DAYS} -print0 2>/dev/null)
    
    # Find recent downloads (TV)
    while IFS= read -r -d '' file; do
        if [[ $cache_size -ge $max_size ]]; then
            log "  Cache size limit reached"
            break
        fi
        
        local basename_file=$(basename "$file")
        local cache_path="$CACHE_BASE/downloads/tv_${basename_file}"
        
        # Skip if already cached
        if [[ -L "$cache_path" ]]; then
            continue
        fi
        
        # Create symlink
        if ln -sf "$file" "$cache_path" 2>/dev/null; then
            ((cached_count++))
            local file_size=$(stat -c%s "$file" 2>/dev/null || echo 0)
            cache_size=$((cache_size + file_size))
            log "  Cached: $basename_file"
        fi
    done < <(find "$DOWNLOADS_DIR/tv" -type f \( -name "*.mkv" -o -name "*.mp4" \) -mtime -${RECENT_DAYS} -print0 2>/dev/null)
    
    # Find recent downloads (documentaries)
    while IFS= read -r -d '' file; do
        if [[ $cache_size -ge $max_size ]]; then
            log "  Cache size limit reached"
            break
        fi
        
        local basename_file=$(basename "$file")
        local cache_path="$CACHE_BASE/downloads/doc_${basename_file}"
        
        # Skip if already cached
        if [[ -L "$cache_path" ]]; then
            continue
        fi
        
        # Create symlink
        if ln -sf "$file" "$cache_path" 2>/dev/null; then
            ((cached_count++))
            local file_size=$(stat -c%s "$file" 2>/dev/null || echo 0)
            cache_size=$((cache_size + file_size))
            log "  Cached: $basename_file"
        fi
    done < <(find "$DOWNLOADS_DIR/doc" -type f \( -name "*.mkv" -o -name "*.mp4" \) -mtime -${RECENT_DAYS} -print0 2>/dev/null)
    
    log "  Cached $cached_count new downloads"
}

# Check for recently moved content (from downloads to library)
cache_recent_imports() {
    log "Checking for recently imported media..."
    
    local cached_count=0
    
    # Movies imported in last 7 days
    while IFS= read -r -d '' file; do
        local basename_file=$(basename "$file")
        local cache_path="$CACHE_BASE/movies/${basename_file}"
        
        if [[ ! -L "$cache_path" ]]; then
            if ln -sf "$file" "$cache_path" 2>/dev/null; then
                ((cached_count++))
                log "  Cached movie: $basename_file"
            fi
        fi
    done < <(find "$NAS_MOVIES" -type f \( -name "*.mkv" -o -name "*.mp4" \) -mtime -7 -print0 2>/dev/null | head -z -20)
    
    # TV episodes imported in last 3 days
    while IFS= read -r -d '' file; do
        local basename_file=$(basename "$file")
        local cache_path="$CACHE_BASE/tv/${basename_file}"
        
        if [[ ! -L "$cache_path" ]]; then
            if ln -sf "$file" "$cache_path" 2>/dev/null; then
                ((cached_count++))
                log "  Cached TV: $basename_file"
            fi
        fi
    done < <(find "$NAS_TV" -type f \( -name "*.mkv" -o -name "*.mp4" \) -mtime -3 -print0 2>/dev/null | head -z -30)
    
    # Documentaries imported in last 7 days
    while IFS= read -r -d '' file; do
        local basename_file=$(basename "$file")
        local cache_path="$CACHE_BASE/doc/${basename_file}"
        
        if [[ ! -L "$cache_path" ]]; then
            if ln -sf "$file" "$cache_path" 2>/dev/null; then
                ((cached_count++))
                log "  Cached Doc: $basename_file"
            fi
        fi
    done < <(find "$NAS_DOC" -type f \( -name "*.mkv" -o -name "*.mp4" \) -mtime -7 -print0 2>/dev/null | head -z -20)
    
    log "  Cached $cached_count imported items"
}

# Clean expired cache entries
cleanup_old_cache() {
    log "Cleaning expired cache entries..."
    
    local removed_count=0
    local now=$(date +%s)
    
    # Check downloads folder cache
    while IFS= read -r link; do
        if [[ -L "$link" ]]; then
            local target=$(readlink -f "$link" 2>/dev/null || true)
            
            # Remove if target doesn't exist or is too old
            if [[ ! -e "$target" ]]; then
                rm -f "$link"
                ((removed_count++))
            else
                local age_days=$(( (now - $(stat -c %Y "$target" 2>/dev/null || echo 0)) / 86400 ))
                
                # Different retention for movies vs TV
                if [[ "$link" =~ movie_ ]] && [[ $age_days -gt $MOVIE_RETENTION_DAYS ]]; then
                    rm -f "$link"
                    ((removed_count++))
                elif [[ "$link" =~ tv_ ]] && [[ $age_days -gt $TV_RETENTION_DAYS ]]; then
                    rm -f "$link"
                    ((removed_count++))
                elif [[ $age_days -gt $RECENT_DAYS ]]; then
                    rm -f "$link"
                    ((removed_count++))
                fi
            fi
        fi
    done < <(find "$CACHE_BASE/downloads" -type l 2>/dev/null)
    
    # Clean broken symlinks in all directories
    find "$CACHE_BASE" -xtype l -delete 2>/dev/null
    
    log "  Removed $removed_count expired/broken entries"
}

# Update manifest
update_manifest() {
    local cache_count=$(find "$CACHE_BASE" -type l 2>/dev/null | wc -l)
    local cache_size=$(get_cache_size)
    
    if [[ -f "$MANIFEST" ]]; then
        jq --arg date "$(date -Iseconds)" \
           --arg count "$cache_count" \
           --arg size "$cache_size" \
           '.overseerr_sync.last_run = $date | 
            .overseerr_sync.items_cached = ($count | tonumber) |
            .overseerr_sync.cache_size = ($size | tonumber)' \
           "$MANIFEST" > /tmp/manifest.tmp && mv /tmp/manifest.tmp "$MANIFEST"
    fi
}

# Show cache statistics
show_stats() {
    local total_links=$(find "$CACHE_BASE" -type l 2>/dev/null | wc -l)
    local downloads=$(find "$CACHE_BASE/downloads" -type l 2>/dev/null | wc -l)
    local movies=$(find "$CACHE_BASE/movies" -type l 2>/dev/null | wc -l)
    local tv=$(find "$CACHE_BASE/tv" -type l 2>/dev/null | wc -l)
    local cache_size=$(get_cache_size)
    
    log "\n${GREEN}=== Cache Statistics ===${NC}"
    log "  Downloads: $downloads items"
    log "  Movies: $movies items"
    log "  TV: $tv items"
    log "  Total: $total_links items ($(bytes_to_gb $cache_size) GB)"
}

# Main execution
main() {
    log "${GREEN}=== Overseerr Cache Sync Started ===${NC}"
    
    # Check prerequisites
    check_sqlite
    
    # Check Overseerr requests (for future API integration)
    # get_overseerr_requests
    
    # Clean old cache first to make room
    cleanup_old_cache
    
    # Cache recent downloads
    cache_recent_downloads
    
    # Cache recently imported media
    cache_recent_imports
    
    # Update manifest
    update_manifest
    
    # Show statistics
    show_stats
    
    log "${GREEN}=== Sync Complete ===${NC}"
}

# Run main function
main "$@"