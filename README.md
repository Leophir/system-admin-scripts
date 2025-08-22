# System Administration Scripts Collection

A collection of bash scripts for system administration, monitoring, backup, and media management.

## Overview

This repository contains various utility scripts designed for DietPi/Linux system administration. All scripts have been reviewed, debugged, and standardized for better reliability and consistency.

## Scripts

### System Management
- **`backup-OS.sh`** - Creates compressed system backups excluding temporary directories
- **`server_health_check.sh`** - Comprehensive system health monitoring with Telegram notifications
- **`monitor_containers.sh`** - Docker container health monitoring and automatic restart
- **`onedrive-check.sh`** - OneDrive service monitoring and restart functionality
- **`track_processes.sh`** - Process monitoring and logging to CSV format

### Backup & Storage
- **`optimized_docker_backup_to_onedrive.sh`** - Optimized Docker volume backup with OneDrive sync
- **`common_functions.sh`** - Shared utility functions for logging, Telegram notifications, and system checks

### Media Management
- **`build_spotify_titles_full.sh`** - Extract track titles from Spotify playlists via API
- **`spotdl_chunked.sh`** - Download Spotify playlists using spotdl in chunks
- **`spotdl_linewise.sh`** - Line-by-line parallel Spotify track downloading
- **`spotdl_sync.sh`** - Spotify playlist synchronization script
- **`ytdlp_linewise.sh`** - YouTube track downloading with parallel processing
- **`ytdlp_smart_match.sh`** - Smart matching YouTube downloads with fuzzy search

### Utilities
- **`telegram_notify.sh`** - Standalone Telegram notification sender

## Setup

### Prerequisites

1. **Environment Variables**: Create `/root/.env` with required credentials:
```bash
# Telegram Bot Configuration
BOT_TOKEN=your_telegram_bot_token
CHAT_ID=your_telegram_chat_id

# Spotify API (for Spotify scripts)
SPOTIPY_CLIENT_ID=your_spotify_client_id
SPOTIPY_CLIENT_SECRET=your_spotify_client_secret
SPOTIPY_REDIRECT_URI=http://localhost:8765/callback

# Optional backup settings
BACKUP_RETENTION_DAYS=5
ZSTD_LEVEL=3
CPU_THRESHOLD=85
RAM_THRESHOLD=90
DISK_THRESHOLD=90
```

2. **Required System Packages**:
```bash
# Essential packages
apt update
apt install -y curl jq tar zstd bc

# For media scripts
pip install spotdl yt-dlp

# For monitoring (optional)
apt install -y vnstat sensors-utils
```

3. **Directory Structure**:
```bash
mkdir -p /mnt/nas/music/lists
mkdir -p /srv/OneDrive/PCBOX-Backup
mkdir -p /var/log/system_stats
```

### Installation

1. Clone or download the scripts:
```bash
git clone <repository_url> /root/scripts
cd /root/scripts
chmod +x *.sh
```

2. Set up environment file:
```bash
cp .env.example /root/.env
# Edit /root/.env with your credentials
```

3. Test the common functions:
```bash
source common_functions.sh
load_env /root/.env
# Test telegram notification
send_telegram "Test message from $(hostname)"
```

## Usage Examples

### System Monitoring
```bash
# Run health check
./server_health_check.sh

# Monitor containers
./monitor_containers.sh

# Create system backup
./backup-OS.sh
```

### Media Management
```bash
# Build Spotify playlist titles
./build_spotify_titles_full.sh

# Download with spotdl (chunked approach)
./spotdl_chunked.sh

# Download with yt-dlp (line-wise)
./ytdlp_linewise.sh --jobs 4 --list /path/to/titles.txt
```

### Backup Operations
```bash
# Docker backup to OneDrive
./optimized_docker_backup_to_onedrive.sh

# Check OneDrive service
./onedrive-check.sh
```

## Features

### Security Improvements
- ✅ Removed hard-coded credentials
- ✅ Proper environment variable validation
- ✅ Command injection prevention with quoted variables

### Reliability Enhancements
- ✅ Portable file size detection across different Unix systems
- ✅ Command availability checks before usage
- ✅ Infinite loop prevention in API pagination
- ✅ Consistent error handling and logging

### Standardization
- ✅ Unified environment file loading (`/root/.env`)
- ✅ Consistent Telegram notification functions
- ✅ Standardized logging patterns
- ✅ Proper script headers with `set -euo pipefail`

## Automation

### Cron Examples
```bash
# System health check every 30 minutes
*/30 * * * * /root/scripts/server_health_check.sh >/dev/null 2>&1

# Container monitoring every 5 minutes
*/5 * * * * /root/scripts/monitor_containers.sh >/dev/null 2>&1

# Daily OS backup at 2 AM
0 2 * * * /root/scripts/backup-OS.sh >/dev/null 2>&1

# OneDrive check every hour
0 * * * * /root/scripts/onedrive-check.sh >/dev/null 2>&1

# Process tracking every minute
* * * * * /root/scripts/track_processes.sh >/dev/null 2>&1
```

### Systemd Service Example
```ini
# /etc/systemd/system/container-monitor.service
[Unit]
Description=Docker Container Monitor
After=docker.service

[Service]
Type=oneshot
ExecStart=/root/scripts/monitor_containers.sh
User=root

# /etc/systemd/system/container-monitor.timer
[Unit]
Description=Run container monitor every 5 minutes
Requires=container-monitor.service

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
```

## Logging

### Log Locations
- System scripts: `/var/log/`
- Media scripts: `/root/` or user-specified
- Health monitoring: `/var/log/system_stats/`

### Log Rotation
All scripts implement automatic log rotation when files exceed configured size limits (default: 10MB).

## Troubleshooting

### Common Issues

1. **Telegram notifications not working**
   - Verify BOT_TOKEN and CHAT_ID in `/root/.env`
   - Test with: `./telegram_notify.sh "Test message"`

2. **Permission errors**
   - Ensure scripts are executable: `chmod +x *.sh`
   - Run as root for system-level operations

3. **Missing dependencies**
   - Check script requirements with command availability checks
   - Install missing packages as needed

4. **API rate limits**
   - Spotify/YouTube scripts include rate limiting delays
   - Adjust THREADS/JOBS parameters if needed

## Contributing

When modifying scripts:
1. Maintain `set -euo pipefail` for strict error handling
2. Use consistent logging via `common_functions.sh`
3. Quote all variables to prevent word splitting
4. Add command availability checks for external tools
5. Test thoroughly before deployment

## License

These scripts are provided as-is for system administration purposes. Use at your own risk and ensure you have proper backups before running system-level operations.