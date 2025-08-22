#!/bin/bash
set -euo pipefail
: "${SPOTIPY_CLIENT_ID:?missing}"; : "${SPOTIPY_CLIENT_SECRET:?missing}"
PL="1G4Uua9Mbhnu4iEwahscX6"
OUT="/root/playlist_titles.txt"

TOKEN="$(curl -s -u "$SPOTIPY_CLIENT_ID:$SPOTIPY_CLIENT_SECRET" \
  -d grant_type=client_credentials https://accounts.spotify.com/api/token | jq -r .access_token)"

api () { curl -sfS -H "Authorization: Bearer $TOKEN" "$1"; }

# get total
TOTAL="$(api "https://api.spotify.com/v1/playlists/$PL/tracks?limit=1&additional_types=track" | jq -r '.total')"
echo "[info] total = $TOTAL" 1>&2

: > "$OUT"
OFFSET=0
LOOP_COUNT=0
MAX_LOOPS=$((TOTAL / 50 + 10))  # Safety limit based on total with buffer

while [ "$OFFSET" -lt "$TOTAL" ]; do
  # Safety check to prevent infinite loops
  LOOP_COUNT=$((LOOP_COUNT + 1))
  if [ "$LOOP_COUNT" -gt "$MAX_LOOPS" ]; then
    echo "[err] Too many loops, aborting to prevent infinite loop" >&2
    exit 1
  fi
  
  URL="https://api.spotify.com/v1/playlists/$PL/tracks?limit=100&offset=$OFFSET&additional_types=track"
  # retry on 429/5xx
  for try in 1 2 3 4; do
    if page="$(api "$URL")"; then break; fi
    sleep $((try*2))
  done
  
  # Check if we got valid data
  if [ -z "$page" ] || [ "$page" = "null" ]; then
    echo "[err] got empty response; aborting" >&2
    exit 1
  fi
  
  echo "$page" | jq -r '.items[].track | select(.id!=null) | "\(.artists[0].name) - \(.name)"' >> "$OUT"
  
  # Calculate new offset and validate progress
  ITEMS_COUNT=$(echo "$page" | jq '.items | length')
  [ "$ITEMS_COUNT" -eq 0 ] && { echo "[err] got zero items; aborting" >&2; exit 1; }
  
  OLD_OFFSET=$OFFSET
  OFFSET=$((OFFSET + ITEMS_COUNT))
  
  # Ensure we're making progress
  [ "$OFFSET" -le "$OLD_OFFSET" ] && { echo "[err] no progress made; aborting" >&2; exit 1; }
  
  echo "[info] fetched $OFFSET / $TOTAL" >&2
  sleep 0.2
done
echo "[ok] wrote $(wc -l < "$OUT") lines to $OUT" >&2
