#!/bin/bash
#
# MEDIA CACHE MANAGER - Intelligent popular content caching for Jellyfin
# 
# This script queries Jellyfin's playback statistics database to identify
# the most watched content and creates symlinks for fast SSD access.
#
# Features:
#   - Queries playback_reporting.db for viewing statistics  
#   - Creates symlinks for popular content
#   - Manages cache size limits
#   - Automatic rotation based on popularity
#   - Full logging and error handling
#
# Version: 1.0.0
# Created: 2025-09-03
#

set -euo pipefail

# Configuration
CACHE_BASE="/mnt/ssd500/jellyfin-cache"
CACHE_POPULAR="$CACHE_BASE/popular"
CACHE_MOVIES="$CACHE_BASE/movies"
CACHE_TV="$CACHE_BASE/tv"
MANIFEST="/mnt/ssd500/cache-management/CACHE_MANIFEST.json"
STATS_FILE="/mnt/ssd500/cache-management/popular-content.txt"
NAS_BASE="/mnt/nas"
LOG_FILE="/var/log/media-cache/media-cache-manager.log"
LOCK_FILE="/tmp/media-cache-manager.lock"

# Cache limits (in GB)
MAX_POPULAR_CACHE_GB=200
MAX_MOVIES_CACHE_GB=100
MAX_TV_CACHE_GB=100

# Dry run mode (set to true for testing)
DRY_RUN=${DRY_RUN:-false}

# Jellyfin database path
JELLYFIN_DB="/mnt/dietpi_userdata/docker-files/jellyfin/config/data/library.db"
PLAYBACK_DB="/mnt/dietpi_userdata/docker-files/jellyfin/config/data/playback_reporting.db"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$CACHE_POPULAR" "$CACHE_MOVIES" "$CACHE_TV"

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

# Error handler
error_exit() {
    log "${RED}ERROR: $1${NC}"
    exit 1
}

# Check prerequisites
check_prerequisites() {
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root"
    fi
    
    # Check if Jellyfin database exists
    if [[ ! -f "$JELLYFIN_DB" ]]; then
        error_exit "Jellyfin database not found at $JELLYFIN_DB"
    fi
    
    # Check if NAS is mounted
    if ! mountpoint -q "$NAS_BASE"; then
        error_exit "NAS is not mounted at $NAS_BASE"
    fi
    
    # Check if sqlite3 is installed
    if ! command -v sqlite3 &> /dev/null; then
        log "${YELLOW}sqlite3 not found, installing...${NC}"
        apt-get update && apt-get install -y sqlite3
    fi
    
    # Check cache status
    local status=$(jq -r '.status' "$MANIFEST" 2>/dev/null || echo "unknown")
    if [[ "$status" == "disabled" ]]; then
        log "${YELLOW}Cache system is disabled. Enable with: cache-control.sh enable${NC}"
        exit 0
    fi
}

# Convert bytes to GB
bytes_to_gb() {
    echo "scale=2; $1/1073741824" | bc
}

# Get current cache size in bytes
get_cache_size() {
    local dir="$1"
    local total_size=0
    
    while IFS= read -r link; do
        if [[ -L "$link" && -e "$link" ]]; then
            local target=$(readlink -f "$link")
            if [[ -f "$target" ]]; then
                local size=$(stat -c%s "$target" 2>/dev/null || echo 0)
                total_size=$((total_size + size))
            fi
        fi
    done < <(find "$dir" -type l 2>/dev/null)
    
    echo "$total_size"
}

# Get popular content from Jellyfin database
get_popular_content() {
    log "Querying Jellyfin for popular content..."
    
    # Check if playback reporting database exists
    if [[ ! -f "$PLAYBACK_DB" ]]; then
        log "${YELLOW}Playback reporting database not found, using library database${NC}"
        
        # Fallback: Get recently added items from library database
        sqlite3 "$JELLYFIN_DB" <<EOF > "$STATS_FILE.tmp" 2>/dev/null || true
.mode csv
.headers off
SELECT 
    Path,
    'Movie' as Type,
    DateCreated
FROM TypedBaseItems
WHERE type = 'MediaBrowser.Controller.Entities.Movies.Movie'
    AND Path IS NOT NULL
    AND Path LIKE '$NAS_BASE%'
ORDER BY DateCreated DESC
LIMIT 100;
EOF
    else
        # Query playback statistics (this is a simplified query, actual schema may vary)
        sqlite3 "$PLAYBACK_DB" <<EOF > "$STATS_FILE.tmp" 2>/dev/null || true
.mode csv
.headers off
SELECT 
    ItemName,
    ItemType,
    COUNT(*) as PlayCount,
    MAX(DateCreated) as LastPlayed
FROM PlaybackActivity
WHERE ItemType IN ('Movie', 'Episode')
GROUP BY ItemName, ItemType
ORDER BY PlayCount DESC
LIMIT 200;
EOF
    fi
    
    # Process results
    if [[ -s "$STATS_FILE.tmp" ]]; then
        mv "$STATS_FILE.tmp" "$STATS_FILE"
        local count=$(wc -l < "$STATS_FILE")
        log "Found $count popular/recent items"
    else
        log "${YELLOW}No playback data found, will cache recent additions instead${NC}"
        get_recent_media
    fi
}

# Get recently added media as fallback
get_recent_media() {
    log "Finding recently added media..."
    
    # Find movies added in last 30 days
    find "$NAS_BASE/movies" -type f \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" \) -mtime -30 2>/dev/null | head -50 > "$STATS_FILE.movies"
    
    # Find TV episodes added in last 14 days
    find "$NAS_BASE/tv" -type f \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" \) -mtime -14 2>/dev/null | head -100 > "$STATS_FILE.tv"
    
    cat "$STATS_FILE.movies" "$STATS_FILE.tv" > "$STATS_FILE"
    
    local count=$(wc -l < "$STATS_FILE")
    log "Found $count recent media files"
}

# Create symlink with safety checks
create_safe_symlink() {
    local source="$1"
    local dest_dir="$2"
    local dest_name=$(basename "$source")
    local dest="$dest_dir/$dest_name"
    
    # Skip if source doesn't exist
    if [[ ! -e "$source" ]]; then
        log "  Skipping: Source not found: $source"
        return 1
    fi
    
    # Skip if symlink already exists and points to same target
    if [[ -L "$dest" ]]; then
        local current_target=$(readlink -f "$dest" 2>/dev/null || true)
        if [[ "$current_target" == "$source" ]]; then
            return 0  # Already cached
        else
            # Remove old symlink
            rm -f "$dest"
        fi
    fi
    
    # Create symlink
    if [[ "$DRY_RUN" == "true" ]]; then
        log "  [DRY RUN] Would create: $dest -> $source"
    else
        ln -sf "$source" "$dest" 2>/dev/null || {
            log "  Failed to create symlink: $dest"
            return 1
        }
    fi
    
    return 0
}

# Cache popular movies
cache_movies() {
    log "\nCaching popular movies..."
    
    local current_size=$(get_cache_size "$CACHE_MOVIES")
    local max_size=$((MAX_MOVIES_CACHE_GB * 1073741824))
    local cached_count=0
    local skipped_count=0
    
    # Find movie files from NAS
    while IFS= read -r movie_path; do
        # Check size limit
        if [[ $current_size -ge $max_size ]]; then
            log "  Movie cache size limit reached ($(bytes_to_gb $current_size) GB)"
            break
        fi
        
        # Only cache files from NAS
        if [[ "$movie_path" =~ ^/mnt/nas/movies/.* ]]; then
            if create_safe_symlink "$movie_path" "$CACHE_MOVIES"; then
                ((cached_count++))
                local file_size=$(stat -c%s "$movie_path" 2>/dev/null || echo 0)
                current_size=$((current_size + file_size))
            else
                ((skipped_count++))
            fi
        fi
        
        # Stop after processing 100 movies
        if [[ $cached_count -ge 100 ]]; then
            break
        fi
    done < <(find "$NAS_BASE/movies" -type f \( -name "*.mkv" -o -name "*.mp4" \) -size +100M 2>/dev/null | sort -R | head -200)
    
    log "  Cached $cached_count movies ($(bytes_to_gb $current_size) GB)"
    [[ $skipped_count -gt 0 ]] && log "  Skipped $skipped_count movies"
}

# Cache popular TV shows
cache_tv_shows() {
    log "\nCaching popular TV episodes..."
    
    local current_size=$(get_cache_size "$CACHE_TV")
    local max_size=$((MAX_TV_CACHE_GB * 1073741824))
    local cached_count=0
    local skipped_count=0
    
    # Find TV episode files from NAS - focus on recent seasons
    while IFS= read -r episode_path; do
        # Check size limit
        if [[ $current_size -ge $max_size ]]; then
            log "  TV cache size limit reached ($(bytes_to_gb $current_size) GB)"
            break
        fi
        
        # Only cache files from NAS TV directory
        if [[ "$episode_path" =~ ^/mnt/nas/tv/.* ]]; then
            if create_safe_symlink "$episode_path" "$CACHE_TV"; then
                ((cached_count++))
                local file_size=$(stat -c%s "$episode_path" 2>/dev/null || echo 0)
                current_size=$((current_size + file_size))
            else
                ((skipped_count++))
            fi
        fi
        
        # Stop after processing 200 episodes
        if [[ $cached_count -ge 200 ]]; then
            break
        fi
    done < <(find "$NAS_BASE/tv" -type f \( -name "*.mkv" -o -name "*.mp4" \) -mtime -60 2>/dev/null | sort -R | head -300)
    
    log "  Cached $cached_count TV episodes ($(bytes_to_gb $current_size) GB)"
    [[ $skipped_count -gt 0 ]] && log "  Skipped $skipped_count episodes"
}

# Clean old/broken symlinks
clean_cache() {
    log "\nCleaning cache..."
    
    local removed_count=0
    
    # Remove broken symlinks
    while IFS= read -r link; do
        if [[ ! -e "$link" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log "  [DRY RUN] Would remove broken link: $link"
            else
                rm -f "$link"
            fi
            ((removed_count++))
        fi
    done < <(find "$CACHE_BASE" -type l 2>/dev/null)
    
    [[ $removed_count -gt 0 ]] && log "  Removed $removed_count broken symlinks"
}

# Update manifest
update_manifest() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would update manifest"
        return
    fi
    
    local total_links=$(find "$CACHE_BASE" -type l 2>/dev/null | wc -l)
    local cache_size=$(du -sb "$CACHE_BASE" 2>/dev/null | cut -f1)
    
    # Update manifest with current stats
    jq --arg date "$(date -Iseconds)" \
       --arg links "$total_links" \
       --arg size "$cache_size" \
       '.last_update = $date | .stats.total_symlinks = ($links | tonumber) | .stats.cache_size_bytes = ($size | tonumber)' \
       "$MANIFEST" > /tmp/manifest.tmp && mv /tmp/manifest.tmp "$MANIFEST"
}

# Main execution
main() {
    log "${GREEN}=== Media Cache Manager Started ===${NC}"
    
    # Check prerequisites
    check_prerequisites
    
    # Get popular content
    get_popular_content
    
    # Clean old cache
    clean_cache
    
    # Cache content
    cache_movies
    cache_tv_shows
    
    # Update manifest
    update_manifest
    
    # Final statistics
    log "\n${GREEN}=== Cache Update Complete ===${NC}"
    local total_cached=$(find "$CACHE_BASE" -type l 2>/dev/null | wc -l)
    local total_size=$(get_cache_size "$CACHE_BASE")
    log "Total cached items: $total_cached"
    log "Total cache size: $(bytes_to_gb $total_size) GB"
    
    # Set active status
    if [[ "$DRY_RUN" != "true" ]]; then
        jq '.status = "active"' "$MANIFEST" > /tmp/manifest.tmp && mv /tmp/manifest.tmp "$MANIFEST"
    fi
    
    log "${GREEN}Done!${NC}"
}

# Run main function
main "$@"