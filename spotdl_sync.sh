#!/bin/bash
set -euo pipefail

# Check for required commands
for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd not found! Please install it."; exit 1; }
done

export SPOTIPY_CLIENT_ID="2b85313e3ad4488babbe247081a1788e"
export SPOTIPY_CLIENT_SECRET="7c99cb43ca68400b9b54008753a56f93"
export SPOTIPY_REDIRECT_URI="http://localhost:8765/callback"

PL_URL="https://open.spotify.com/playlist/1G4Uua9Mbhnu4iEwahscX6"
PL_ID="$(basename "$PL_URL" | cut -d'?' -f1)"
SYNCFILE="/root/playlist.spotdl"
OUTDIR="/mnt/nas/music/lists"
LOGFILE="/var/log/spotdl.log"
SPOTDL="/root/.local/bin/spotdl"

mkdir -p /root/.config/spotdl
cat >/root/.config/spotdl/config.json <<'JSON'
{"audio_providers":["youtube"],"output_format":"mp3","bitrate":"320k"}
JSON

# get token
TOKEN="$(curl -s -u "$SPOTIPY_CLIENT_ID:$SPOTIPY_CLIENT_SECRET" \
  -d grant_type=client_credentials https://accounts.spotify.com/api/token | jq -r .access_token)"

# build spotdl file in chunks of 100
: > "$SYNCFILE"
OFFSET=0
TOTAL="$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.spotify.com/v1/playlists/$PL_ID/tracks?limit=1" | jq -r .total)"
while [ "$OFFSET" -lt "$TOTAL" ]; do
  curl -s -H "Authorization: Bearer $TOKEN" \
    "https://api.spotify.com/v1/playlists/$PL_ID/tracks?limit=100&offset=$OFFSET&additional_types=track" \
    | jq -r '.items[].track.external_urls.spotify' >> "$SYNCFILE"
  OFFSET=$((OFFSET+100))
  sleep 0.5
done

# sanity checks
wc -l "$SYNCFILE"
head -n 3 "$SYNCFILE"

# sync download from youtube
mkdir -p "$OUTDIR"
echo "=== $(date '+%F %T') start ===" | tee -a "$LOGFILE"
spotdl download "$SYNCFILE" --output "$OUTDIR" --threads 4 --max-retries 3 --yt-dlp-args "--no-playlist-random"
echo "=== $(date '+%F %T') end ===" | tee -a "$LOGFILE"
tail -n 80 "$LOGFILE"
