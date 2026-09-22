#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$PWD/dist/LessMeet.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/LessMeet" "$app_dir/Contents/MacOS/LessMeet"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
codesign --force --sign "${LESSMEET_SIGNING_IDENTITY:--}" --options runtime \
  --entitlements Resources/LessMeet.entitlements "$app_dir"
codesign --verify --strict "$app_dir"
printf 'Built %s\n' "$app_dir"
