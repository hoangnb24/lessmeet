#!/bin/bash
# Record a fresh 60 fps take of the real LessMeet Library fixture and compose it.
# Usage: bash design/promo-video/app/record.sh [take-dir]
# Needs: dist/library-ui-check/LessMeet.app (bash scripts/build-app.sh library-ui-check),
# Xcode with UI-automation access, ffmpeg and Python 3 with Pillow.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
take="${1:-$root/.artifacts/promo-capture/take-$(date +%Y%m%d-%H%M%S)}"
app="$root/dist/library-ui-check/LessMeet.app"
mkdir -p "$take"
[[ -e "$take/frames.rgba" ]] || mkfifo "$take/frames.rgba"
# The app writes raw RGBA frames into the FIFO; ffmpeg stores them near-losslessly.
ffmpeg -y -loglevel error -f rawvideo -pix_fmt rgba -s 1920x1080 -r 60 -i "$take/frames.rgba" \
  -c:v libx264 -preset ultrafast -crf 8 -pix_fmt yuv444p "$take/app-raw.mp4" &
encoder=$!
bash "$root/design/promo-video/driver/run.sh" "$app" "$take" testRecordDemo
wait "$encoder"
python3 "$root/design/promo-video/app/ad.py" "$take" "$take/LessMeet-ad-30s-1080p60.mp4"
