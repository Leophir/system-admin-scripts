#!/bin/bash
set -euo pipefail

LIST="/root/playlist.txt"                # plain text list of Spotify track URLs
PARTDIR="/root/spotdl_parts"
ARCHIVE="/root/spotdl.archive"           # tracks already downloaded are logged here
ERRORS="/root/spotdl_errors.log"
OUTDIR="/mnt/nas/music/lists"
SPOTDL="/root/.local/bin/spotdl"
THREADS="${THREADS:-4}"

mkdir -p "$PARTDIR" "$OUTDIR"

# split into 150 lines each; remove old parts so we don't reprocess stale files
find "$PARTDIR" -type f -name 'part_*' -delete || true
split -d -l 150 "$LIST" "$PARTDIR/part_"

# optional cookies: put a cookies file at /root/youtube.cookies.txt if needed
COOKIE_ARGS=()
[ -f /root/youtube.cookies.txt ] && COOKIE_ARGS=(--cookie-file /root/youtube.cookies.txt)

# loop chunks; force YouTube, be verbose, and skip things already in archive
for f in "$PARTDIR"/part_*; do
  echo "=== Processing $f ==="
  if [ ! -s "$f" ]; then
    echo "[skip] empty file: $f"
    rm -f "$f"
    continue
  fi

  # up to 3 tries per chunk
  for try in 1 2 3; do
    set +e
    "$SPOTDL" download "$f" \
      --audio youtube \
      --threads "$THREADS" \
      --dont-filter-results \
      --add-unavailable \
      --print-errors \
      --save-errors "$ERRORS" \
      --archive "$ARCHIVE" \
      --log-level INFO \
      --output "$OUTDIR" \
      "${COOKIE_ARGS[@]}"
    rc=$?
    set -e
    if [ $rc -eq 0 ]; then
      echo "[ok] $f"
      rm -f "$f"              # cleanup chunk after success
      break
    else
      echo "[warn] retry $try for $f"
      sleep 5
    fi
  done
done

echo "=== Done. Summary ==="
echo "Queued: $(wc -l < "$LIST")"
echo "Downloaded (unique): $(wc -l < "$ARCHIVE" 2>/dev/null || echo 0)"
echo "Errors (lines): $(wc -l < "$ERRORS" 2>/dev/null || echo 0)"
