#!/bin/bash
#
# ANALYZE JELLYFIN STATS - Analyze playback patterns from Jellyfin database
#
# Reads Jellyfin's database to identify popular content and viewing patterns
# Generates reports for cache optimization
#
# Version: 1.0.0
# Created: 2025-09-03
#

set -euo pipefail

# Configuration
JELLYFIN_DB="/mnt/dietpi_userdata/docker-files/jellyfin/config/data/library.db"
PLAYBACK_DB="/mnt/dietpi_userdata/docker-files/jellyfin/config/data/playback_reporting.db"
OUTPUT_DIR="/mnt/ssd500/cache-management"
REPORT_FILE="$OUTPUT_DIR/jellyfin-analysis-$(date +%Y%m%d).txt"
LOG_FILE="/var/log/media-cache/analyze-jellyfin-stats.log"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Ensure directories exist
mkdir -p "$(dirname "$LOG_FILE")" "$OUTPUT_DIR"

# Logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Check prerequisites
check_prerequisites() {
    if [[ ! -f "$JELLYFIN_DB" ]]; then
        log "${YELLOW}Warning: Jellyfin database not found at $JELLYFIN_DB${NC}"
        exit 1
    fi
    
    if ! command -v sqlite3 &> /dev/null; then
        log "Installing sqlite3..."
        apt-get update && apt-get install -y sqlite3
    fi
}

# Analyze library content
analyze_library() {
    log "${BLUE}Analyzing Jellyfin Library...${NC}"
    
    # Get media counts
    local movie_count=$(sqlite3 "$JELLYFIN_DB" "SELECT COUNT(*) FROM TypedBaseItems WHERE type = 'MediaBrowser.Controller.Entities.Movies.Movie';" 2>/dev/null || echo 0)
    local episode_count=$(sqlite3 "$JELLYFIN_DB" "SELECT COUNT(*) FROM TypedBaseItems WHERE type = 'MediaBrowser.Controller.Entities.TV.Episode';" 2>/dev/null || echo 0)
    
    {
        echo "=== Jellyfin Library Analysis ==="
        echo "Generated: $(date)"
        echo ""
        echo "Library Overview:"
        echo "  Movies: $movie_count"
        echo "  TV Episodes: $episode_count"
        echo ""
    } > "$REPORT_FILE"
    
    log "  Movies: $movie_count"
    log "  TV Episodes: $episode_count"
}

# Get recently added content
analyze_recent_additions() {
    log "${BLUE}Analyzing Recent Additions...${NC}"
    
    {
        echo "Recent Additions (Last 30 Days):"
        echo "================================"
        
        # Recent movies
        echo -e "\nRecent Movies:"
        sqlite3 "$JELLYFIN_DB" <<EOF 2>/dev/null || echo "  No data available"
.mode list
.separator " | "
SELECT 
    Name,
    datetime(DateCreated) as Added
FROM TypedBaseItems
WHERE type = 'MediaBrowser.Controller.Entities.Movies.Movie'
    AND DateCreated > datetime('now', '-30 days')
ORDER BY DateCreated DESC
LIMIT 20;
EOF
        
        # Recent TV episodes
        echo -e "\nRecent TV Episodes:"
        sqlite3 "$JELLYFIN_DB" <<EOF 2>/dev/null || echo "  No data available"
.mode list
.separator " | "
SELECT 
    SeriesName || ' - ' || Name as Episode,
    datetime(DateCreated) as Added
FROM TypedBaseItems
WHERE type = 'MediaBrowser.Controller.Entities.TV.Episode'
    AND DateCreated > datetime('now', '-14 days')
ORDER BY DateCreated DESC
LIMIT 20;
EOF
        
        echo ""
    } >> "$REPORT_FILE"
}

# Analyze playback statistics if available
analyze_playback() {
    log "${BLUE}Analyzing Playback Statistics...${NC}"
    
    if [[ ! -f "$PLAYBACK_DB" ]]; then
        log "${YELLOW}Playback reporting database not found${NC}"
        echo "Playback Statistics: Not available (plugin not installed)" >> "$REPORT_FILE"
        return
    fi
    
    {
        echo "Playback Statistics:"
        echo "===================="
        
        # Most played items
        echo -e "\nMost Played Content:"
        sqlite3 "$PLAYBACK_DB" <<EOF 2>/dev/null || echo "  No playback data available"
.mode column
.headers on
SELECT 
    ItemName,
    ItemType,
    COUNT(*) as PlayCount,
    date(MAX(DateCreated)) as LastPlayed
FROM PlaybackActivity
WHERE ItemType IN ('Movie', 'Episode')
GROUP BY ItemName
ORDER BY PlayCount DESC
LIMIT 25;
EOF
        
        echo ""
    } >> "$REPORT_FILE"
}

# Generate cache recommendations
generate_recommendations() {
    log "${BLUE}Generating Cache Recommendations...${NC}"
    
    {
        echo "Cache Optimization Recommendations:"
        echo "===================================="
        echo ""
        echo "1. Priority Caching:"
        echo "   - Cache all content played >3 times in last month"
        echo "   - Cache all content added in last 7 days"
        echo "   - Cache complete seasons of actively watched shows"
        echo ""
        echo "2. Space Management:"
        echo "   - Remove cache for content not played in 60+ days"
        echo "   - Prioritize 1080p over 4K for space efficiency"
        echo "   - Keep popular movies permanently cached"
        echo ""
        echo "3. Performance Tips:"
        echo "   - Run cache update during off-peak hours (3-5 AM)"
        echo "   - Monitor cache hit rate weekly"
        echo "   - Adjust cache size based on usage patterns"
        echo ""
    } >> "$REPORT_FILE"
}

# Create summary for cache manager
create_cache_list() {
    log "Creating optimized cache list..."
    
    local cache_list="$OUTPUT_DIR/cache-candidates.txt"
    
    # Get paths of frequently watched content
    sqlite3 "$JELLYFIN_DB" <<EOF 2>/dev/null > "$cache_list" || true
.mode list
SELECT DISTINCT Path
FROM TypedBaseItems
WHERE type IN ('MediaBrowser.Controller.Entities.Movies.Movie', 'MediaBrowser.Controller.Entities.TV.Episode')
    AND Path IS NOT NULL
    AND Path LIKE '/mnt/nas%'
    AND (
        DateCreated > datetime('now', '-30 days')
        OR DateLastSaved > datetime('now', '-30 days')
    )
ORDER BY DateCreated DESC
LIMIT 500;
EOF
    
    local count=$(wc -l < "$cache_list" 2>/dev/null || echo 0)
    log "  Generated cache list with $count candidates"
}

# Main execution
main() {
    log "${GREEN}=== Jellyfin Statistics Analysis Started ===${NC}"
    
    check_prerequisites
    
    analyze_library
    analyze_recent_additions
    analyze_playback
    generate_recommendations
    create_cache_list
    
    log "\n${GREEN}Analysis complete!${NC}"
    log "Report saved to: $REPORT_FILE"
    
    # Display summary
    echo -e "\n${BLUE}Summary:${NC}"
    head -20 "$REPORT_FILE"
    echo "..."
    echo -e "\n${GREEN}Full report: $REPORT_FILE${NC}"
}

# Run main function
main "$@"