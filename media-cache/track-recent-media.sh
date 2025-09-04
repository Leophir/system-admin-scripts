#!/bin/bash
#
# TRACK RECENT MEDIA - Cache recently added content
#
# This script finds media files added in the last 30 days and creates
# symlinks for faster access. Older content is automatically removed
# from the cache to maintain freshness.
#
# Features:
#   - Finds media added in last 30 days
#   - Prioritizes smaller files to cache more titles
#   - Auto-expires content older than 30 days
#   - Maintains separate recent cache
#
# Version: 1.0.0
# Created: 2025-09-03
#

set -euo pipefail

# Configuration
CACHE_BASE="/mnt/ssd500/jellyfin-cache"
CACHE_RECENT="$CACHE_BASE/recent"
MANIFEST="/mnt/ssd500/cache-management/CACHE_MANIFEST.json"
RECENT_CACHE_JSON="/mnt/ssd500/cache-management/recent-cache.json"
NAS_BASE="/mnt/nas"
LOG_FILE="/var/log/media-cache/track-recent-media.log"
LOCK_FILE="/tmp/track-recent-media.lock"

# Cache settings
RECENT_DAYS=30  # How many days to consider "recent"
MAX_RECENT_CACHE_GB=150
MAX_FILE_SIZE_GB=20  # Skip files larger than this

# Dry run mode
DRY_RUN=${DRY_RUN:-false}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Ensure directories exist
mkdir -p "$(dirname "$LOG_FILE")" "$CACHE_RECENT"

# Prevent concurrent execution
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "Another instance is already running. Exiting."
    exit 1
fi

# Logging
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
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root"
    fi
    
    if ! mountpoint -q "$NAS_BASE"; then
        error_exit "NAS is not mounted at $NAS_BASE"
    fi
    
    # Check cache status
    local status=$(jq -r '.status' "$MANIFEST" 2>/dev/null || echo "unknown")
    if [[ "$status" == "disabled" ]]; then
        log "${YELLOW}Cache system is disabled${NC}"
        exit 0
    fi
}

# Convert bytes to GB
bytes_to_gb() {
    echo "scale=2; $1/1073741824" | bc
}

# Get file age in days
get_file_age_days() {
    local file="$1"
    local now=$(date +%s)
    local file_time=$(stat -c %Y "$file" 2>/dev/null || echo 0)
    echo $(( (now - file_time) / 86400 ))
}

# Initialize or load recent cache JSON
init_recent_cache_json() {
    if [[ ! -f "$RECENT_CACHE_JSON" ]]; then
        echo '{"version":"1.0","entries":{},"last_cleanup":"'$(date -Iseconds)'"}' > "$RECENT_CACHE_JSON"
    fi
}

# Add entry to recent cache JSON
add_to_recent_cache() {
    local file="$1"
    local link="$2"
    local size="$3"
    local added_date=$(date -Iseconds)
    
    if [[ "$DRY_RUN" == "true" ]]; then
        return
    fi
    
    # Add entry to JSON
    jq --arg file "$file" \
       --arg link "$link" \
       --arg size "$size" \
       --arg date "$added_date" \
       '.entries[$file] = {link: $link, size: ($size | tonumber), added: $date}' \
       "$RECENT_CACHE_JSON" > /tmp/recent.tmp && mv /tmp/recent.tmp "$RECENT_CACHE_JSON"
}

# Remove expired entries from cache
cleanup_expired() {
    log "Removing expired cache entries..."
    
    local removed_count=0
    local current_date=$(date +%s)
    
    # Check all symlinks in recent cache
    while IFS= read -r link; do
        if [[ -L "$link" ]]; then
            local target=$(readlink -f "$link" 2>/dev/null || true)
            
            # Check if file still exists and age
            if [[ ! -e "$target" ]] || [[ $(get_file_age_days "$target") -gt $RECENT_DAYS ]]; then
                if [[ "$DRY_RUN" == "true" ]]; then
                    log "  [DRY RUN] Would remove expired: $(basename "$link")"
                else
                    rm -f "$link"
                    ((removed_count++))
                fi
            fi
        fi
    done < <(find "$CACHE_RECENT" -type l 2>/dev/null)
    
    [[ $removed_count -gt 0 ]] && log "  Removed $removed_count expired entries"
    
    # Update JSON to remove expired entries
    if [[ "$DRY_RUN" != "true" ]]; then
        jq --arg date "$(date -Iseconds)" '.last_cleanup = $date' "$RECENT_CACHE_JSON" > /tmp/recent.tmp && mv /tmp/recent.tmp "$RECENT_CACHE_JSON"
    fi
}

# Find and cache recent movies
cache_recent_movies() {
    log "\nCaching recent movies (last $RECENT_DAYS days)..."
    
    local cached_count=0
    local skipped_count=0
    local total_size=0
    local max_size=$((MAX_RECENT_CACHE_GB * 1073741824 / 2))  # Half for movies
    
    # Find recent movie files, prioritize by size (smaller first)
    while IFS= read -r movie_path; do
        # Check total size limit
        if [[ $total_size -ge $max_size ]]; then
            log "  Movie cache size limit reached ($(bytes_to_gb $total_size) GB)"
            break
        fi
        
        # Get file size
        local file_size=$(stat -c%s "$movie_path" 2>/dev/null || echo 0)
        local file_size_gb=$(bytes_to_gb $file_size)
        
        # Skip very large files
        if (( $(echo "$file_size_gb > $MAX_FILE_SIZE_GB" | bc -l) )); then
            log "  Skipping large file (${file_size_gb}GB): $(basename "$movie_path")"
            ((skipped_count++))
            continue
        fi
        
        # Create symlink
        local dest_name=$(basename "$movie_path")
        local dest="$CACHE_RECENT/movie_${dest_name}"
        
        if [[ -L "$dest" ]] && [[ "$(readlink -f "$dest")" == "$movie_path" ]]; then
            # Already cached
            total_size=$((total_size + file_size))
            continue
        fi
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log "  [DRY RUN] Would cache: $dest_name (${file_size_gb}GB)"
        else
            ln -sf "$movie_path" "$dest" 2>/dev/null && {
                ((cached_count++))
                total_size=$((total_size + file_size))
                add_to_recent_cache "$movie_path" "$dest" "$file_size"
                log "  Cached: $dest_name (${file_size_gb}GB)"
            }
        fi
    done < <(find "$NAS_BASE/movies" -type f \( -name "*.mkv" -o -name "*.mp4" \) -mtime -$RECENT_DAYS -size +100M 2>/dev/null | xargs -I {} sh -c 'echo "$(stat -c%s "{}") {}"' | sort -n | cut -d' ' -f2-)
    
    log "  Cached $cached_count recent movies ($(bytes_to_gb $total_size) GB)"
    [[ $skipped_count -gt 0 ]] && log "  Skipped $skipped_count large movies"
}

# Find and cache recent TV episodes
cache_recent_tv() {
    log "\nCaching recent TV episodes (last $RECENT_DAYS days)..."
    
    local cached_count=0
    local skipped_count=0
    local total_size=0
    local max_size=$((MAX_RECENT_CACHE_GB * 1073741824 / 2))  # Half for TV
    
    # Find recent TV files - focus on complete seasons if possible
    while IFS= read -r tv_path; do
        # Check total size limit
        if [[ $total_size -ge $max_size ]]; then
            log "  TV cache size limit reached ($(bytes_to_gb $total_size) GB)"
            break
        fi
        
        # Get file size
        local file_size=$(stat -c%s "$tv_path" 2>/dev/null || echo 0)
        local file_size_gb=$(bytes_to_gb $file_size)
        
        # TV episodes are usually smaller, so higher limit
        if (( $(echo "$file_size_gb > 10" | bc -l) )); then
            ((skipped_count++))
            continue
        fi
        
        # Extract show and episode info for better naming
        local dest_name=$(basename "$tv_path")
        local show_dir=$(basename "$(dirname "$tv_path")")
        local dest="$CACHE_RECENT/tv_${show_dir}_${dest_name}"
        
        if [[ -L "$dest" ]] && [[ "$(readlink -f "$dest")" == "$tv_path" ]]; then
            # Already cached
            total_size=$((total_size + file_size))
            continue
        fi
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log "  [DRY RUN] Would cache: $show_dir - $dest_name"
        else
            ln -sf "$tv_path" "$dest" 2>/dev/null && {
                ((cached_count++))
                total_size=$((total_size + file_size))
                add_to_recent_cache "$tv_path" "$dest" "$file_size"
            }
        fi
    done < <(find "$NAS_BASE/tv" -type f \( -name "*.mkv" -o -name "*.mp4" \) -mtime -$RECENT_DAYS 2>/dev/null | xargs -I {} sh -c 'echo "$(stat -c%s "{}") {}"' | sort -n | cut -d' ' -f2-)
    
    log "  Cached $cached_count recent TV episodes ($(bytes_to_gb $total_size) GB)"
    [[ $skipped_count -gt 0 ]] && log "  Skipped $skipped_count large episodes"
}

# Find and cache recent documentaries
cache_recent_doc() {
    log "\nCaching recent documentaries (last $RECENT_DAYS days)..."
    
    local cached_count=0
    local skipped_count=0
    local total_size=0
    local max_size=$((MAX_RECENT_CACHE_GB * 1073741824 / 3))  # Third for docs
    
    # Find recent doc files
    while IFS= read -r doc_path; do
        # Check total size limit
        if [[ $total_size -ge $max_size ]]; then
            log "  Reached cache size limit for documentaries"
            break
        fi
        
        # Get file size
        local file_size=$(stat -c%s "$doc_path" 2>/dev/null || echo 0)
        local file_size_gb=$(bytes_to_gb $file_size)
        
        # Skip files larger than threshold
        if (( $(echo "$file_size_gb > $MAX_FILE_SIZE_GB" | bc -l) )); then
            ((skipped_count++))
            continue
        fi
        
        # Extract doc info for better naming
        local dest_name=$(basename "$doc_path")
        local doc_dir=$(basename "$(dirname "$doc_path")")
        local dest="$CACHE_RECENT/doc_${doc_dir}_${dest_name}"
        
        if [[ -L "$dest" ]] && [[ "$(readlink -f "$dest")" == "$doc_path" ]]; then
            # Already cached
            total_size=$((total_size + file_size))
            continue
        fi
        
        # Create symlink
        if [[ "$DRY_RUN" == "true" ]]; then
            log "  [DRY RUN] Would cache: $doc_dir - $dest_name"
        else
            ln -sf "$doc_path" "$dest" 2>/dev/null && {
                ((cached_count++))
                total_size=$((total_size + file_size))
                add_to_recent_cache "$doc_path" "$dest" "$file_size"
            }
        fi
    done < <(find "$NAS_BASE/doc" -type f \( -name "*.mkv" -o -name "*.mp4" \) -mtime -$RECENT_DAYS 2>/dev/null | xargs -I {} sh -c 'echo "$(stat -c%s "{}") {}"' | sort -n | cut -d' ' -f2-)
    
    log "  Cached $cached_count recent documentaries ($(bytes_to_gb $total_size) GB)"
    [[ $skipped_count -gt 0 ]] && log "  Skipped $skipped_count large documentaries"
}

# Calculate and show statistics
show_statistics() {
    log "\n${GREEN}Cache Statistics:${NC}"
    
    # Count items by type
    local movie_count=$(find "$CACHE_RECENT" -name "movie_*" -type l 2>/dev/null | wc -l)
    local tv_count=$(find "$CACHE_RECENT" -name "tv_*" -type l 2>/dev/null | wc -l)
    local doc_count=$(find "$CACHE_RECENT" -name "doc_*" -type l 2>/dev/null | wc -l)
    local total_count=$((movie_count + tv_count + doc_count))
    
    # Calculate total size
    local total_size=0
    while IFS= read -r link; do
        if [[ -L "$link" && -e "$link" ]]; then
            local target=$(readlink -f "$link")
            if [[ -f "$target" ]]; then
                local size=$(stat -c%s "$target" 2>/dev/null || echo 0)
                total_size=$((total_size + size))
            fi
        fi
    done < <(find "$CACHE_RECENT" -type l 2>/dev/null)
    
    log "  Recent movies: $movie_count"
    log "  Recent TV episodes: $tv_count"
    log "  Recent documentaries: $doc_count"
    log "  Total items: $total_count"
    log "  Total size: $(bytes_to_gb $total_size) GB"
}

# Main execution
main() {
    log "${GREEN}=== Recent Media Tracker Started ===${NC}"
    
    # Check prerequisites
    check_prerequisites
    
    # Initialize cache JSON
    init_recent_cache_json
    
    # Clean up expired entries first
    cleanup_expired
    
    # Cache recent content
    cache_recent_movies
    cache_recent_tv
    cache_recent_doc
    
    # Show statistics
    show_statistics
    
    # Update manifest
    if [[ "$DRY_RUN" != "true" ]]; then
        jq --arg date "$(date -Iseconds)" '.last_recent_update = $date' "$MANIFEST" > /tmp/manifest.tmp && mv /tmp/manifest.tmp "$MANIFEST"
    fi
    
    log "${GREEN}Done!${NC}"
}

# Run main function
main "$@"