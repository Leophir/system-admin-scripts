#!/bin/bash
set -euo pipefail

LIST="/root/playlist_titles.txt"          # one "Artist - Title" per line
OUT="/mnt/nas/music/lists"
ARCH="/root/ytdlp.archive"                # tracks logged here to avoid re-downloads
ERRS="/root/ytdlp_errors.log"
JOBS="${JOBS:-4}"                         # parallel yt-dlp processes
COOKIE_FILE="/root/youtube.cookies.txt"   # optional cookies for age/region blocks

mkdir -p "$OUT"
touch "$ARCH" "$ERRS"

COOKIE=()
[ -f "$COOKIE_FILE" ] && COOKIE=(--cookies "$COOKIE_FILE")

# Clean input (drop empty lines)
TMP="$(mktemp)"
grep -v '^[[:space:]]*$' "$LIST" > "$TMP"

# Run N jobs in parallel; best match per line (ytsearch1)
xargs -P "$JOBS" -I {} -- yt-dlp \
  "ytsearch1:{}" \
  --ignore-errors --no-abort-on-error \
  --no-continue --no-overwrites \
  --extract-audio --audio-format mp3 --audio-quality 320K \
  --embed-thumbnail --add-metadata \
  --output "$OUT/%(title)s [%(id)s].%(ext)s" \
  --download-archive "$ARCH" \
  --concurrent-fragments 5 --retries 10 --fragment-retries 10 \
  --sleep-interval 1 --max-sleep-interval 3 \
  "${COOKIE[@]}" \
  2>>"$ERRS" < "$TMP"

rm -f "$TMP"

# Summary (robust even if files are empty)
queued=$(wc -l < "$LIST"); downloaded=$(wc -l < "$ARCH"); errors=$(wc -l < "$ERRS")
echo "Queued: $queued"
echo "Downloaded (unique): $downloaded"
echo "Errors lines: $errors"
