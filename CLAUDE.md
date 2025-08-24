# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a system administration and DevOps automation scripts collection written in Bash, designed specifically for DietPi/Linux systems. The focus is on server management, monitoring, backup, and media management automation.

## Core Architecture

**Shared Infrastructure Pattern**: All scripts use the central `common_functions.sh` library which provides:
- Unified logging with rotation (`log_message`, `log_error`, `log_info`)
- Telegram notification system (`send_telegram_message`)
- Environment loading (`load_environment`)
- System utility checks (`check_command`)

**Configuration Management**: Environment variables are loaded from `/root/.env` (not in repo) with fallbacks to defaults. Use `.env.example` as template. All scripts source the common functions and load environment at startup.

## Development Standards

**Error Handling**: All scripts use `set -euo pipefail` and implement proper error checking with retry mechanisms for network operations.

**Security**: Never hardcode credentials - use environment variables. All user inputs should be quoted to prevent command injection. Scripts include validation for required tools and environment variables.

**Logging**: Use the shared logging functions from `common_functions.sh`. Logs rotate automatically and include timestamps.

## Key Components

**System Management**:
- `server_health_check.sh` - Comprehensive monitoring with Telegram alerts
- `backup-OS.sh` - System-wide backups with compression
- `monitor_containers.sh` - Docker health monitoring

**Media Management**:
- `build_spotify_titles_full.sh` - Spotify API integration for playlist extraction  
- `spotdl_*.sh` and `ytdlp_*.sh` - Music downloading with multiple strategies

**Backup Systems**:
- `optimized_docker_backup_to_onedrive.sh` - Docker volume backups with OneDrive sync

## Common Development Tasks

**Testing Scripts**: No formal test framework. Test manually in development environment before production deployment.

**Adding New Scripts**: 
1. Source `common_functions.sh` at the top
2. Use `set -euo pipefail` for strict error handling
3. Load environment with `load_environment`
4. Check required commands with `check_command`
5. Use shared logging functions

**Environment Setup**: Copy `.env.example` to `/root/.env` and configure required variables for the scripts you're working with.

## Dependencies

System packages: `curl`, `jq`, `tar`, `zstd`, `bc`
Python packages: `pip install spotdl yt-dlp` (for media scripts)
Optional monitoring: `vnstat`, `sensors-utils`

## Configuration

Scripts expect configuration in `/root/.env`. Critical variables include Telegram bot credentials for notifications, Spotify API credentials for media scripts, and various service-specific settings documented in `.env.example`.

## Log Locations

Most scripts log to `/var/log/` with automatic rotation. Check individual scripts for specific log paths. The shared logging system handles rotation and cleanup automatically.