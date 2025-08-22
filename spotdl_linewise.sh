#!/bin/bash
set -euo pipefail

# === Defaults ===
LIST="/root/playlist_titles.txt"        # one "Artist - Title" per line
OUTDIR="/mnt/nas/music/lists"
ARCHIVE="/root/spotdl.archive"          # skip items already downloaded
ERRORS="/root/spotdl_errors.log"
SPOTDL="/root/.local/bin/spotdl"
THREADS=4                                # spotdl internal threads per process
JOBS=4                                   # how many spotdl processes in parallel
START_LINE=1                             # resume from a given line number
COOKIE_FILE=""                           # path to youtube cookies.txt (optional)
LOGFILE="/var/log/spotdl_linewise.log"

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --list FILE           Input lines to download (default: $LIST)
  --outdir DIR          Output directory (default: $OUTDIR)
  --archive FILE        Archive file (default: $ARCHIVE)
  --errors FILE         Errors log (default: $ERRORS)
  --jobs N              Parallel spotdl processes (default: $JOBS)
  --threads N           spotdl --threads per process (default: $THREADS)
  --start N             Start from line N (1-based) (default: $START_LINE)
  --cookies FILE        YouTube cookies.txt (optional)
  --log FILE            Script log file (default: $LOGFILE)
  -h|--help             Show this help
USAGE
}

# === Parse args ===
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) LIST="$2"; shift 2;;
    --outdir) OUTDIR="$2"; shift 2;;
    --archive) ARCHIVE="$2"; shift 2;;
    --errors) ERRORS="$2"; shift 2;;
    --jobs) JOBS="$2"; shift 2;;
    --threads) THREADS="$2"; shift 2;;
    --start) START_LINE="$2"; shift 2;;
    --cookies) COOKIE_FILE="$2"; shift 2;;
    --log) LOGFILE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

# === Preflight ===
echo "=== $(date '+%F %T') start ===" | tee -a "$LOGFILE"
echo "[cfg] LIST=$LIST OUTDIR=$OUTDIR ARCHIVE=$ARCHIVE ERRORS=$ERRORS JOBS=$JOBS THREADS=$THREADS START_LINE=$START_LINE" | tee -a "$LOGFILE"

[[ -x "$SPOTDL" ]] || { echo "[err] spotdl not found at $SPOTDL" | tee -a "$LOGFILE"; exit 1; }
[[ -f "$LIST" ]] || { echo "[err] list file not found: $LIST" | tee -a "$LOGFILE"; exit 1; }

mkdir -p "$(dirname "$ARCHIVE")" "$(dirname "$ERRORS")" "$OUTDIR"

# Force YouTube + MP3 320k
mkdir -p /root/.config/spotdl
cat >/root/.config/spotdl/config.json <<JSON
{"audio_providers":["youtube"],"output_format":"mp3","bitrate":"320k","ytm_data":false}
JSON

# Build xargs cookie arg
COOKIE_ARG=()
[[ -n "$COOKIE_FILE" && -f "$COOKIE_FILE" ]] && COOKIE_ARG=(--cookie-file "$COOKIE_FILE")

# Export creds so child spotdl sees them
export SPOTIPY_CLIENT_ID="${SPOTIPY_CLIENT_ID:-}"
export SPOTIPY_CLIENT_SECRET="${SPOTIPY_CLIENT_SECRET:-}"
export SPOTIPY_REDIRECT_URI="${SPOTIPY_REDIRECT_URI:-http://localhost:8765/callback}"

# Filter lines: drop blanks, trim, skip to START_LINE
TOTAL=$(grep -v '^[[:space:]]*$' "$LIST" | wc -l || echo 0)
echo "[info] total lines (non-empty) in list: $TOTAL" | tee -a "$LOGFILE"

# Tail from START_LINE safely
TMP_INPUT="$(mktemp)"
grep -v '^[[:space:]]*$' "$LIST" | tail -n +"$START_LINE" > "$TMP_INPUT"

# Run downloads in parallel (JOBS spotdl processes)
# Each line is one query; archive ensures idempotency across re-runs
# shellcheck disable=SC2016
xargs -P "$JOBS" -I {} -- bash -c '
  q="$1"
  if [[ -z "$q" ]]; then exit 0; fi
  echo "[dl] $q"
  '"$SPOTDL"' download "$q" \
    --audio youtube \
    --threads '"$THREADS"' \
    --dont-filter-results \
    --add-unavailable \
    --print-errors \
    --save-errors "'"$ERRORS"'" \
    --archive "'"$ARCHIVE"'" \
    --client-id "'"$SPOTIPY_CLIENT_ID"'" \
    --client-secret "'"$SPOTIPY_CLIENT_SECRET"'" \
    --output "'"$OUTDIR"'" '"${COOKIE_ARG[@]+"${COOKIE_ARG[@]}"}"'
' _ {} < "$TMP_INPUT" | tee -a "$LOGFILE"

rm -f "$TMP_INPUT"

# Summary
DONE=0; [[ -f "$ARCHIVE" ]] && DONE=$(wc -l < "$ARCHIVE")
ERRC=0; [[ -f "$ERRORS" ]] && ERRC=$(wc -l < "$ERRORS")
echo "=== $(date '+%F %T') end ===" | tee -a "$LOGFILE"
echo "[sum] queued=$TOTAL downloaded_unique=$DONE errors_lines=$ERRC outdir=$OUTDIR" | tee -a "$LOGFILE"
