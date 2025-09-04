# 📜 Cache Management Scripts Documentation

## Overview
This document provides detailed documentation for all cache management scripts used in the Jellyfin Cache System.

---

## Script Inventory

| Script | Purpose | Schedule | Dependencies |
|--------|---------|----------|--------------|
| cache-control.sh | Master control script | Manual/API | All other scripts |
| overseerr-cache-sync.sh | Sync Overseerr requests | Every 2 hours | Overseerr API |
| track-recent-media.sh | Cache recent additions | Daily 10 AM | find, stat |
| monitor-cache.sh | Real-time monitoring | Manual | watch, du |
| clear-cache.sh | Safe cache cleanup | Manual | find, rm |
| dashboard.sh | Terminal dashboard | Manual | All scripts |

---

## Detailed Script Documentation

### 1. cache-control.sh

**Purpose**: Central management interface for all cache operations

**Location**: `/root/script-repo/media-cache/cache-control.sh`

**Usage**:
```bash
./cache-control.sh [command]
```

**Commands**:
- `status` - Display current cache statistics
- `monitor` - Start real-time monitoring
- `clear-all` - Remove all cache entries
- `clear-movies` - Clear movie cache only
- `clear-tv` - Clear TV show cache only
- `clear-doc` - Clear documentary cache only
- `sync` - Run Overseerr sync
- `track` - Update recent media cache
- `help` - Display help message

**Code Structure**:
```bash
#!/bin/bash

# Configuration
CACHE_BASE="/mnt/ssd500/jellyfin-cache"
NAS_BASE="/mnt/nas"
LOG_DIR="/var/log/media-cache"

# Functions
show_status() {
    echo "=== Jellyfin Cache Status ==="
    echo "Cache Location: $CACHE_BASE"
    
    # Check Jellyfin status (FIXED VERSION)
    if docker ps --format "{{.Names}}" | grep -q "^jellyfin$"; then
        echo "Jellyfin Status: Running"
    else
        echo "Jellyfin Status: Stopped"
    fi
    
    # Show cache statistics
    for category in movies tv doc; do
        count=$(find "$CACHE_BASE/$category" -type l 2>/dev/null | wc -l)
        size=$(du -sh "$CACHE_BASE/$category" 2>/dev/null | cut -f1)
        echo "$category: $count items, $size"
    done
}

clear_cache() {
    local category=$1
    if [ "$category" = "all" ]; then
        find "$CACHE_BASE" -type l -delete
    else
        find "$CACHE_BASE/$category" -type l -delete
    fi
    echo "Cache cleared: $category"
}

# Main execution
case "$1" in
    status) show_status ;;
    clear-all) clear_cache all ;;
    clear-movies) clear_cache movies ;;
    clear-tv) clear_cache tv ;;
    clear-doc) clear_cache doc ;;
    sync) /root/script-repo/media-cache/overseerr-cache-sync.sh ;;
    track) /root/script-repo/media-cache/track-recent-media.sh ;;
    monitor) watch -n 5 "$0 status" ;;
    *) echo "Usage: $0 {status|monitor|clear-all|clear-movies|clear-tv|clear-doc|sync|track}" ;;
esac
```

**Error Handling**:
- Checks if directories exist before operations
- Validates Docker availability
- Logs all operations to syslog

**Performance Notes**:
- `find` operations can be slow with many files
- Consider using `parallel` for large operations
- Cache statistics are calculated on-demand

---

### 2. overseerr-cache-sync.sh

**Purpose**: Synchronize cache with Overseerr media requests

**Location**: `/root/script-repo/media-cache/overseerr-cache-sync.sh`

**Schedule**: Every 2 hours via cron

**Configuration**:
```bash
OVERSEERR_URL="http://localhost:5055"
OVERSEERR_API_KEY="your-api-key-here"
CACHE_DAYS=30
MAX_CACHE_SIZE_GB=400
```

**Algorithm**:
1. Query Overseerr API for recent requests
2. Filter requests by date (last 30 days)
3. Map request to file path on NAS
4. Create symlink in cache directory
5. Remove expired entries
6. Check cache size limit

**API Integration**:
```bash
# Get recent movie requests
curl -s -H "X-Api-Key: $OVERSEERR_API_KEY" \
    "$OVERSEERR_URL/api/v1/request?filter=approved&take=100" | \
    jq -r '.results[] | select(.media.mediaType=="movie") | .media.tmdbId'

# Get recent TV requests  
curl -s -H "X-Api-Key: $OVERSEERR_API_KEY" \
    "$OVERSEERR_URL/api/v1/request?filter=approved&take=100" | \
    jq -r '.results[] | select(.media.mediaType=="tv") | .media.tvdbId'
```

**File Path Resolution**:
```bash
find_media_file() {
    local media_name=$1
    local media_type=$2
    local search_path="$NAS_BASE/$media_type"
    
    # Search for media file (handles various naming conventions)
    find "$search_path" -type f \
        \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" \) \
        -path "*$media_name*" 2>/dev/null | head -1
}
```

**Cache Creation**:
```bash
create_cache_link() {
    local source_file=$1
    local cache_category=$2
    local filename=$(basename "$source_file")
    local cache_link="$CACHE_BASE/$cache_category/$filename"
    
    # Create symlink if not exists
    if [ ! -L "$cache_link" ]; then
        ln -s "$source_file" "$cache_link"
        echo "Cached: $filename"
    fi
}
```

**Size Management**:
```bash
check_cache_size() {
    local current_size_gb=$(du -s "$CACHE_BASE" | awk '{print int($1/1024/1024)}')
    
    if [ $current_size_gb -gt $MAX_CACHE_SIZE_GB ]; then
        echo "Cache size exceeded limit ($current_size_gb GB > $MAX_CACHE_SIZE_GB GB)"
        # Remove oldest entries
        find "$CACHE_BASE" -type l -printf '%T@ %p\n' | \
            sort -n | head -20 | cut -d' ' -f2- | xargs rm -f
    fi
}
```

---

### 3. track-recent-media.sh

**Purpose**: Cache recently added media files

**Location**: `/root/script-repo/media-cache/track-recent-media.sh`

**Schedule**: Daily at 10:00 AM via cron

**Algorithm**:
```bash
#!/bin/bash

CACHE_BASE="/mnt/ssd500/jellyfin-cache"
NAS_BASE="/mnt/nas"
RECENT_DAYS=30

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting recent media tracker"

# Find recent movies
find "$NAS_BASE/movies" -type f \
    \( -name "*.mkv" -o -name "*.mp4" \) \
    -mtime -$RECENT_DAYS -print0 | \
while IFS= read -r -d '' file; do
    filename=$(basename "$file")
    cache_link="$CACHE_BASE/movies/$filename"
    
    # Handle special characters in filename
    if [ ! -L "$cache_link" ]; then
        ln -s "$file" "$cache_link" 2>/dev/null && \
            echo "Cached recent movie: $filename"
    fi
done

# Find recent TV episodes
find "$NAS_BASE/tv" -type f \
    \( -name "*.mkv" -o -name "*.mp4" \) \
    -mtime -$RECENT_DAYS -print0 | \
while IFS= read -r -d '' file; do
    filename=$(basename "$file")
    cache_link="$CACHE_BASE/tv/$filename"
    
    if [ ! -L "$cache_link" ]; then
        ln -s "$file" "$cache_link" 2>/dev/null && \
            echo "Cached recent TV episode: $filename"
    fi
done

# Find recent documentaries
find "$NAS_BASE/doc" -type f \
    \( -name "*.mkv" -o -name "*.mp4" \) \
    -mtime -$RECENT_DAYS -print0 | \
while IFS= read -r -d '' file; do
    filename=$(basename "$file")
    cache_link="$CACHE_BASE/doc/$filename"
    
    if [ ! -L "$cache_link" ]; then
        ln -s "$file" "$cache_link" 2>/dev/null && \
            echo "Cached recent documentary: $filename"
    fi
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Recent media tracker completed"
```

**Special Character Handling**:
- Uses `-print0` and `read -d ''` for null-terminated strings
- Handles spaces and special characters in filenames
- Escapes quotes properly in symlink creation

---

### 4. monitor-cache.sh

**Purpose**: Real-time cache monitoring

**Location**: `/root/script-repo/media-cache/monitor-cache.sh`

**Usage**:
```bash
./monitor-cache.sh [interval_seconds]
```

**Features**:
```bash
#!/bin/bash

CACHE_BASE="/mnt/ssd500/jellyfin-cache"
INTERVAL=${1:-5}

monitor_loop() {
    while true; do
        clear
        echo "=== Jellyfin Cache Monitor ==="
        echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Refresh: ${INTERVAL}s"
        echo ""
        
        # Storage statistics
        df -h "$CACHE_BASE" | tail -1
        echo ""
        
        # Cache statistics
        for category in movies tv doc; do
            count=$(find "$CACHE_BASE/$category" -type l | wc -l)
            size=$(du -sh "$CACHE_BASE/$category" | cut -f1)
            recent=$(find "$CACHE_BASE/$category" -type l -mmin -60 | wc -l)
            echo "$category: $count items ($size) - $recent new in last hour"
        done
        
        echo ""
        echo "=== Recent Activity ==="
        find "$CACHE_BASE" -type l -mmin -60 -printf "%TY-%Tm-%Td %TH:%TM - %f\n" | \
            sort -r | head -10
        
        echo ""
        echo "Press Ctrl+C to exit"
        sleep $INTERVAL
    done
}

trap "echo 'Monitor stopped'; exit 0" INT TERM
monitor_loop
```

---

### 5. clear-cache.sh

**Purpose**: Safely clear cache entries

**Location**: `/root/script-repo/media-cache/clear-cache.sh`

**Safety Features**:
```bash
#!/bin/bash

CACHE_BASE="/mnt/ssd500/jellyfin-cache"
LOG_FILE="/var/log/media-cache/clear-cache.log"

# Safety check function
confirm_action() {
    local action=$1
    echo -n "Are you sure you want to $action? (yes/no): "
    read response
    [ "$response" = "yes" ]
}

# Clear broken symlinks
clear_broken() {
    echo "Finding broken symlinks..."
    local broken_count=$(find "$CACHE_BASE" -type l ! -exec test -e {} \; -print | wc -l)
    
    if [ $broken_count -gt 0 ]; then
        echo "Found $broken_count broken symlinks"
        if confirm_action "remove broken symlinks"; then
            find "$CACHE_BASE" -type l ! -exec test -e {} \; -delete
            echo "$(date): Removed $broken_count broken symlinks" >> "$LOG_FILE"
        fi
    else
        echo "No broken symlinks found"
    fi
}

# Clear by age
clear_old() {
    local days=${1:-30}
    echo "Finding cache entries older than $days days..."
    local old_count=$(find "$CACHE_BASE" -type l -mtime +$days | wc -l)
    
    if [ $old_count -gt 0 ]; then
        echo "Found $old_count old entries"
        if confirm_action "remove entries older than $days days"; then
            find "$CACHE_BASE" -type l -mtime +$days -delete
            echo "$(date): Removed $old_count old entries" >> "$LOG_FILE"
        fi
    else
        echo "No old entries found"
    fi
}

# Clear by size
clear_large() {
    local size_mb=${1:-5000}
    echo "Finding files larger than ${size_mb}MB..."
    
    find "$CACHE_BASE" -type l -exec stat -c '%s %n' {} \; | \
    while read size file; do
        size_mb_file=$((size / 1048576))
        if [ $size_mb_file -gt $size_mb ]; then
            echo "Large file: $(basename "$file") (${size_mb_file}MB)"
            rm -f "$file"
        fi
    done
}

# Main menu
case "$1" in
    broken) clear_broken ;;
    old) clear_old ${2:-30} ;;
    large) clear_large ${2:-5000} ;;
    all) 
        if confirm_action "clear ALL cache entries"; then
            find "$CACHE_BASE" -type l -delete
            echo "$(date): Cleared all cache" >> "$LOG_FILE"
        fi
        ;;
    *) 
        echo "Usage: $0 {broken|old [days]|large [MB]|all}"
        echo "  broken - Remove broken symlinks"
        echo "  old [days] - Remove entries older than days (default: 30)"
        echo "  large [MB] - Remove files larger than MB (default: 5000)"
        echo "  all - Clear entire cache"
        ;;
esac
```

---

### 6. dashboard.sh

**Purpose**: Terminal-based cache dashboard

**Location**: `/root/script-repo/media-cache/dashboard.sh`

**Features**:
- ASCII art dashboard
- Color-coded status indicators
- Real-time updates
- System resource monitoring

**Code**:
```bash
#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

show_dashboard() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║          Jellyfin Cache Management Dashboard            ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # System Status
    echo -e "${GREEN}▶ System Status${NC}"
    echo "├─ Hostname: $(hostname)"
    echo "├─ Uptime: $(uptime -p)"
    echo "├─ Load: $(uptime | awk -F'load average:' '{print $2}')"
    echo ""
    
    # Jellyfin Status
    echo -e "${GREEN}▶ Jellyfin Status${NC}"
    if docker ps --format "{{.Names}}" | grep -q "^jellyfin$"; then
        echo -e "├─ Status: ${GREEN}● Running${NC}"
        jellyfin_uptime=$(docker ps --filter name=jellyfin --format "{{.Status}}")
        echo "├─ Uptime: $jellyfin_uptime"
    else
        echo -e "├─ Status: ${RED}● Stopped${NC}"
    fi
    echo ""
    
    # Storage Status
    echo -e "${GREEN}▶ Storage Status${NC}"
    df -h /mnt/ssd500 | tail -1 | awk '{
        printf "├─ Cache SSD: %s / %s (%s used)\n", $3, $2, $5
    }'
    df -h /mnt/nas | tail -1 | awk '{
        printf "├─ NAS: %s / %s (%s used)\n", $3, $2, $5
    }'
    echo ""
    
    # Cache Statistics
    echo -e "${GREEN}▶ Cache Statistics${NC}"
    for category in movies tv doc; do
        count=$(find "/mnt/ssd500/jellyfin-cache/$category" -type l 2>/dev/null | wc -l)
        size=$(du -sh "/mnt/ssd500/jellyfin-cache/$category" 2>/dev/null | cut -f1)
        
        # Color code based on count
        if [ $count -gt 100 ]; then
            color=$GREEN
        elif [ $count -gt 50 ]; then
            color=$YELLOW
        else
            color=$RED
        fi
        
        printf "├─ %-12s: %s%-5d%s items (%s)\n" \
            "${category^}" "$color" "$count" "$NC" "$size"
    done
    echo ""
    
    # Recent Activity
    echo -e "${GREEN}▶ Recent Activity (Last Hour)${NC}"
    recent=$(find "/mnt/ssd500/jellyfin-cache" -type l -mmin -60 2>/dev/null | wc -l)
    echo "├─ New cached items: $recent"
    echo ""
    
    # Quick Actions
    echo -e "${BLUE}▶ Quick Actions${NC}"
    echo "├─ [1] View detailed status"
    echo "├─ [2] Run cache sync"
    echo "├─ [3] Clear cache"
    echo "├─ [4] Monitor real-time"
    echo "├─ [5] View logs"
    echo "├─ [q] Quit"
    echo ""
    echo -n "Select action: "
}

# Main loop
while true; do
    show_dashboard
    read -n 1 action
    echo ""
    
    case $action in
        1) /root/script-repo/media-cache/cache-control.sh status; read -p "Press enter to continue..." ;;
        2) /root/script-repo/media-cache/cache-control.sh sync; read -p "Press enter to continue..." ;;
        3) /root/script-repo/media-cache/cache-control.sh clear-all; read -p "Press enter to continue..." ;;
        4) /root/script-repo/media-cache/monitor-cache.sh ;;
        5) tail -50 /var/log/media-cache/*.log; read -p "Press enter to continue..." ;;
        q|Q) echo "Goodbye!"; exit 0 ;;
        *) echo "Invalid option"; sleep 1 ;;
    esac
done
```

---

## Script Dependencies

### System Commands
- `docker`: Container management
- `find`: File searching
- `du`: Disk usage
- `df`: Filesystem usage
- `ln`: Symlink creation
- `curl`: API requests
- `jq`: JSON parsing
- `stat`: File statistics
- `grep`: Pattern matching
- `awk`: Text processing
- `sort`: Sorting
- `head/tail`: File viewing
- `xargs`: Command building
- `watch`: Real-time monitoring

### Directory Structure
```
/root/script-repo/media-cache/
├── cache-control.sh          # Master control
├── overseerr-cache-sync.sh   # Overseerr integration
├── track-recent-media.sh     # Recent media tracker
├── monitor-cache.sh          # Real-time monitor
├── clear-cache.sh           # Cache cleanup
├── dashboard.sh             # Terminal dashboard
└── SCRIPTS_DOCUMENTATION.md # This file

/var/log/media-cache/
├── overseerr-sync.log       # Overseerr sync logs
├── track-recent-media.log   # Recent media logs
└── clear-cache.log         # Cleanup logs
```

---

## Cron Configuration

Add to root's crontab:
```bash
# Jellyfin Cache Management
# Track recent media daily at 10 AM
0 10 * * * /root/script-repo/media-cache/track-recent-media.sh >> /var/log/media-cache/track-recent-media.log 2>&1

# Sync with Overseerr every 2 hours
0 */2 * * * /root/script-repo/media-cache/overseerr-cache-sync.sh >> /var/log/media-cache/overseerr-sync.log 2>&1

# Clean broken symlinks weekly on Sunday at 3 AM
0 3 * * 0 /root/script-repo/media-cache/clear-cache.sh broken >> /var/log/media-cache/clear-cache.log 2>&1

# Optional: Clear old cache monthly on the 1st at 2 AM
0 2 1 * * /root/script-repo/media-cache/clear-cache.sh old 60 >> /var/log/media-cache/clear-cache.log 2>&1
```

---

## Performance Optimization

### Parallel Processing
For large operations, use GNU parallel:
```bash
find "$CACHE_BASE" -type l | parallel -j 4 'process_file {}'
```

### Caching Results
Store frequently accessed data:
```bash
# Cache file list for 5 minutes
CACHE_FILE="/tmp/cache_list_$(date +%s)"
find "$CACHE_BASE" -type l > "$CACHE_FILE"
# Use within 5 minutes
if [ -f "$CACHE_FILE" ] && [ $(( $(date +%s) - $(stat -c %Y "$CACHE_FILE") )) -lt 300 ]; then
    cat "$CACHE_FILE"
fi
```

### Database Alternative
For large-scale deployments, consider SQLite:
```bash
sqlite3 /var/lib/cache.db "
CREATE TABLE IF NOT EXISTS cache_entries (
    filename TEXT PRIMARY KEY,
    source_path TEXT,
    cache_path TEXT,
    size INTEGER,
    created_at DATETIME,
    accessed_at DATETIME
);"
```

---

## Troubleshooting Scripts

### Debug Mode
Enable debug output:
```bash
#!/bin/bash
set -x  # Enable debug
set -e  # Exit on error
```

### Logging
Add comprehensive logging:
```bash
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "INFO: Starting cache sync"
log "ERROR: Failed to create symlink: $file"
```

### Error Recovery
Implement retry logic:
```bash
retry() {
    local max_attempts=3
    local attempt=1
    until "$@" || [ $attempt -eq $max_attempts ]; do
        log "WARNING: Command failed, attempt $attempt/$max_attempts"
        sleep 5
        ((attempt++))
    done
    [ $attempt -lt $max_attempts ]
}

retry curl -s "$OVERSEERR_URL/api/v1/request"
```

---

## Security Considerations

### Input Validation
```bash
validate_path() {
    local path=$1
    # Ensure path is within allowed directories
    case "$path" in
        /mnt/ssd500/jellyfin-cache/*|/mnt/nas/*) 
            return 0 ;;
        *) 
            echo "ERROR: Invalid path: $path"
            return 1 ;;
    esac
}
```

### Safe File Operations
```bash
# Use -- to prevent option injection
rm -f -- "$file"

# Quote all variables
ln -s "$source" "$target"

# Validate user input
read -r user_input
if [[ "$user_input" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    process "$user_input"
fi
```

---

## Testing Scripts

### Unit Tests
Create test script:
```bash
#!/bin/bash
# test_cache_scripts.sh

test_cache_creation() {
    local test_file="/tmp/test_movie.mkv"
    touch "$test_file"
    
    # Test symlink creation
    ./create_cache_link.sh "$test_file" "movies"
    
    # Verify symlink exists
    [ -L "/mnt/ssd500/jellyfin-cache/movies/test_movie.mkv" ]
    
    # Cleanup
    rm -f "$test_file"
    rm -f "/mnt/ssd500/jellyfin-cache/movies/test_movie.mkv"
}

test_cache_clearing() {
    # Create test symlinks
    mkdir -p /tmp/test_cache
    ln -s /tmp/test_file /tmp/test_cache/link1
    
    # Test clearing
    ./clear-cache.sh /tmp/test_cache
    
    # Verify cleared
    [ $(find /tmp/test_cache -type l | wc -l) -eq 0 ]
    
    # Cleanup
    rm -rf /tmp/test_cache
}

# Run tests
test_cache_creation && echo "✓ Cache creation test passed"
test_cache_clearing && echo "✓ Cache clearing test passed"
```

---

*Last Updated: 2024-09-04*
*Author: Nicolas Estrem*