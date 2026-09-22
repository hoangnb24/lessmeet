#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --build-system swiftbuild
binary_dir="$(swift build -c release --build-system swiftbuild --show-bin-path)"
mkdir -p "$PWD/dist"
staging_dir="$(mktemp -d "$PWD/dist/build.XXXXXX")"
app_dir="$staging_dir/LessMeet.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/LessMeet" "$app_dir/Contents/MacOS/LessMeet"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
node scripts/configure-app.mjs "$app_dir/Contents/Info.plist"
# Swift Build generates resource lookup through Bundle.main.resourceURL.
cp -R "$binary_dir/Clerk_ClerkKit.bundle" "$app_dir/Contents/Resources/"
codesign --force --sign "${LESSMEET_SIGNING_IDENTITY:--}" --options runtime \
  --entitlements Resources/LessMeet.entitlements "$app_dir"
codesign --verify --strict --verbose=2 "$app_dir"
if [[ -e "$PWD/dist/LessMeet.app" ]]; then
  mv "$PWD/dist/LessMeet.app" "$staging_dir/Previous-LessMeet.app"
fi
mv "$app_dir" "$PWD/dist/LessMeet.app"
printf 'Built %s\n' "$PWD/dist/LessMeet.app"
