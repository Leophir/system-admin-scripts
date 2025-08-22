#!/bin/bash
set -euo pipefail

# Smart matching yt-dlp script for downloading music with fuzzy search
# Searches for "Artist - Title" format and uses ytsearch with best match logic

LIST="/root/playlist_titles.txt"          # one "Artist - Title" per line
OUT="/mnt/nas/music/lists"
ARCH="/root/ytdlp.archive"                # tracks logged here to avoid re-downloads
ERRS="/root/ytdlp_errors.log"
JOBS="${JOBS:-2}"                         # parallel yt-dlp processes (reduced for smart matching)
COOKIE_FILE="/root/youtube.cookies.txt"   # optional cookies for age/region blocks
MAX_RESULTS="${MAX_RESULTS:-5}"           # how many results to consider per search

mkdir -p "$OUT"
touch "$ARCH" "$ERRS"

COOKIE=()
[ -f "$COOKIE_FILE" ] && COOKIE=(--cookies "$COOKIE_FILE")

# Clean input (drop empty lines)
TMP="$(mktemp)"
grep -v '^[[:space:]]*$' "$LIST" > "$TMP"

# Function to download with smart matching
download_with_smart_match() {
    local query="$1"
    local search_url="ytsearch${MAX_RESULTS}:${query}"
    
    # Use yt-dlp's playlist selection to get best match
    yt-dlp \
        "$search_url" \
        --ignore-errors --no-abort-on-error \
        --no-continue --no-overwrites \
        --extract-audio --audio-format mp3 --audio-quality 320K \
        --embed-thumbnail --add-metadata \
        --output "$OUT/%(uploader)s - %(title)s [%(id)s].%(ext)s" \
        --download-archive "$ARCH" \
        --playlist-items 1 \
        --concurrent-fragments 3 --retries 5 --fragment-retries 5 \
        --sleep-interval 1 --max-sleep-interval 2 \
        "${COOKIE[@]}" \
        2>>"$ERRS"
}

export -f download_with_smart_match
export OUT ARCH ERRS MAX_RESULTS COOKIE_FILE

# Run downloads with limited parallelism for better accuracy
xargs -P "$JOBS" -I {} bash -c 'download_with_smart_match "$@"' _ {} < "$TMP"

rm -f "$TMP"

# Summary
queued=$(wc -l < "$LIST"); downloaded=$(wc -l < "$ARCH"); errors=$(wc -l < "$ERRS")
echo "Queued: $queued"
echo "Downloaded (unique): $downloaded" 
echo "Errors lines: $errors"