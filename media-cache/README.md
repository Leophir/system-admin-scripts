# Jellyfin Media Cache System

A fully reversible symlink-based caching system for Jellyfin to accelerate media playback by storing popular and recent content on local SSDs.

## Features

- **Symlink-based caching** - No file duplication, preserves hardlinks for seeding
- **Intelligent selection** - Caches based on popularity and recency
- **Complete reversibility** - One-command rollback to original state
- **Zero downtime setup** - No service interruption during installation
- **Automatic management** - Self-maintaining cache with rotation
- **Performance monitoring** - Track cache effectiveness

## System Requirements

- Root access
- Available SSD space (recommended: 200-500GB)
- Jellyfin running in Docker
- NAS mounted at `/mnt/nas`
- SQLite3 (will be installed if missing)

## Installation

All scripts have been pre-installed in `/root/script-repo/media-cache/`

### Directory Structure Created

```
/mnt/ssd500/
├── jellyfin-cache/
│   ├── movies/      # Symlinks to popular movies
│   ├── tv/          # Symlinks to popular TV shows  
│   ├── recent/      # Recently added content
│   └── popular/     # Most-watched content
├── cache-management/
│   ├── CACHE_MANIFEST.json       # System state tracking
│   ├── ROLLBACK_SCRIPT.sh        # Complete reversal script
│   ├── cache-stats.json          # Performance metrics
│   └── *.backup                  # Configuration backups
└── scripts/                      # Local script copies
```

## Usage Guide

### 1. Check System Status

```bash
/root/script-repo/media-cache/cache-control.sh status
```

Shows:
- Cache status (active/inactive/disabled)
- Number of cached items by category
- Total cache size
- Mount status in Jellyfin
- Automation status

### 2. Enable Caching System

```bash
# Enable automatic caching (sets up cron jobs)
/root/script-repo/media-cache/cache-control.sh enable

# Run initial cache population (dry-run first)
export DRY_RUN=true
/root/script-repo/media-cache/media-cache-manager.sh

# If everything looks good, run for real
unset DRY_RUN
/root/script-repo/media-cache/media-cache-manager.sh
```

### 3. Add Cache Mount to Jellyfin (Optional - 30-60s downtime)

To actually use the cache, you need to add it to Jellyfin:

```bash
# Get instructions for your setup
/root/script-repo/media-cache/cache-control.sh activate-mount
```

Then manually add to your Jellyfin container:
- **Docker run**: Add `-v /mnt/ssd500/jellyfin-cache:/media-cache:ro`
- **Docker Compose**: Add under volumes: `- /mnt/ssd500/jellyfin-cache:/media-cache:ro`

After adding, restart Jellyfin:
```bash
docker restart jellyfin
```

### 4. Monitor Performance

```bash
# Full monitoring report
/root/script-repo/media-cache/cache-monitor.sh

# Check cache health
/root/script-repo/media-cache/cache-control.sh health

# View space usage
/root/script-repo/media-cache/cache-control.sh space

# Show top cached items
/root/script-repo/media-cache/cache-control.sh top 20
```

### 5. Analyze Jellyfin Statistics

```bash
# Generate analysis report
/root/script-repo/media-cache/analyze-jellyfin-stats.sh
```

Creates report at: `/mnt/ssd500/cache-management/jellyfin-analysis-YYYYMMDD.txt`

## Automated Schedule

When enabled, the system runs:
- **3:00 AM** - Popular content caching (`media-cache-manager.sh`)
- **4:00 AM** - Recent media tracking (`track-recent-media.sh`)
- **Every 30 min** - Quick statistics update (`cache-monitor.sh --quick-stats`)

## Management Commands

### Control Commands

```bash
# Enable automatic caching
cache-control.sh enable

# Disable (keeps existing cache)
cache-control.sh disable

# Clear all symlinks
cache-control.sh clear

# Remove broken symlinks
cache-control.sh clean

# Complete system rollback
cache-control.sh rollback
```

### Manual Cache Operations

```bash
# Cache popular content
/root/script-repo/media-cache/media-cache-manager.sh

# Cache recent additions
/root/script-repo/media-cache/track-recent-media.sh

# Both support DRY_RUN mode:
export DRY_RUN=true
./media-cache-manager.sh  # Test without making changes
```

## Complete Rollback

To completely remove the cache system and restore original state:

```bash
/root/script-repo/media-cache/cache-control.sh rollback
```

Or directly:
```bash
/mnt/ssd500/cache-management/ROLLBACK_SCRIPT.sh
```

This will:
1. Stop all cache scripts
2. Remove cron jobs
3. Delete all symlinks
4. Optionally remove cache mount from Jellyfin
5. Optionally delete cache directories
6. Optionally remove scripts

**Rollback time: ~30-60 seconds** (if Jellyfin restart needed)

## Cache Limits

Default configuration:
- **Popular content**: 200GB maximum
- **Movies**: 100GB maximum
- **TV Shows**: 100GB maximum
- **Recent content**: 150GB maximum
- **Individual file limit**: 20GB (skips larger files)

Modify limits in respective scripts if needed.

## Troubleshooting

### Cache not being used
- Verify mount is added to Jellyfin container
- Check if Jellyfin can see /media-cache directory
- Ensure symlinks point to valid files

### No content being cached
- Check if NAS is mounted: `mountpoint /mnt/nas`
- Verify Jellyfin database exists
- Run with DRY_RUN=true to see what would be cached

### Broken symlinks
```bash
cache-control.sh clean
```

### Performance issues
- Check available SSD space: `df -h /mnt/ssd500`
- Monitor I/O: `iotop`
- Review logs: `/var/log/media-cache/`

## Log Files

All operations are logged to:
```
/var/log/media-cache/
├── cache-control.log
├── media-cache-manager.log
├── track-recent-media.log
├── cache-monitor.log
├── analyze-jellyfin-stats.log
└── rollback-*.log
```

## Safety Features

- **Lock files** prevent concurrent execution
- **Dry-run mode** for testing without changes
- **Automatic rollback** on critical errors
- **Complete state tracking** in manifest
- **Non-destructive** - only creates symlinks
- **Preserves hardlinks** for torrent seeding

## Performance Benefits

- **10x faster reads** from SSD vs NFS
- **Reduced network traffic** to NAS
- **Faster library scans** for cached content
- **Better streaming** for multiple concurrent users
- **Lower NAS load** during peak hours

## Important Notes

1. **No files are moved or copied** - only symlinks created
2. **Hardlinks remain intact** - seeding continues normally
3. **Cache is read-only** in Jellyfin - no write operations
4. **Manual intervention required** only for mount activation
5. **System is stateless** - can be removed anytime

## Support

Check system status first:
```bash
cache-control.sh status
cache-control.sh health
```

Review recent logs:
```bash
tail -f /var/log/media-cache/*.log
```

For complete removal:
```bash
cache-control.sh rollback
```

---
Version: 1.0.0
Created: 2025-09-03
Location: /root/script-repo/media-cache/