#!/bin/bash
# Quick script to populate cache with some content

echo "Populating cache with recent movies..."
count=0
while IFS= read -r -d '' file; do
    if [[ -f "$file" ]]; then
        basename_file=$(basename "$file")
        ln -sf "$file" "/mnt/ssd500/jellyfin-cache/movies/${basename_file}" 2>/dev/null && ((count++))
    fi
    [[ $count -ge 20 ]] && break
done < <(find /mnt/nas/movies -type f \( -name "*.mkv" -o -name "*.mp4" \) -mtime -30 -print0 2>/dev/null)

echo "Added $count movies to cache"

echo "Populating cache with recent TV episodes..."
count=0
while IFS= read -r -d '' file; do
    if [[ -f "$file" ]]; then
        basename_file=$(basename "$file")
        ln -sf "$file" "/mnt/ssd500/jellyfin-cache/tv/${basename_file}" 2>/dev/null && ((count++))
    fi
    [[ $count -ge 30 ]] && break
done < <(find /mnt/nas/tv -type f \( -name "*.mkv" -o -name "*.mp4" \) -mtime -14 -print0 2>/dev/null)

echo "Added $count TV episodes to cache"

/root/script-repo/media-cache/cache-control.sh status