#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-dev}"
action="${2:-build}"
if [[ $# -gt 2 || ! "$mode" =~ ^(dev|sandbox-dev|store|testflight)$ || ! "$action" =~ ^(build|--preflight)$ ]]; then
  printf 'Usage: bash scripts/build-app.sh [dev|sandbox-dev|store|testflight] [--preflight]\n' >&2
  exit 1
fi
output_dir="$PWD/dist"
if [[ "$mode" != dev ]]; then
  output_dir="$output_dir/$mode"
  node scripts/configure-app.mjs --check "$mode"
  if [[ "$mode" == store || "$mode" == testflight ]]; then
    python3 scripts/store-package.py inputs --mode "$mode"
  fi
  if [[ "$action" == --preflight ]]; then
    python3 scripts/packaging-signing.py "$mode"
    exit 0
  fi
elif [[ "$action" == --preflight ]]; then
  node scripts/configure-app.mjs --check dev
  exit 0
fi
mkdir -p "$output_dir"
staging_dir="$(mktemp -d "$output_dir/build.XXXXXX")"
signing_identity="${LESSMEET_SIGNING_IDENTITY:--}"
entitlements="Resources/LessMeet.entitlements"
if [[ "$mode" != dev ]]; then
  python3 scripts/packaging-signing.py "$mode" --output "$staging_dir/signing"
  signing_identity="$(<"$staging_dir/signing/identity.txt")"
  entitlements="$staging_dir/signing/entitlements.plist"
fi
swift build -c release --build-system swiftbuild
binary_dir="$(swift build -c release --build-system swiftbuild --show-bin-path)"
app_dir="$staging_dir/LessMeet.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/LessMeet" "$app_dir/Contents/MacOS/LessMeet"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
node scripts/configure-app.mjs "$app_dir/Contents/Info.plist" "$mode"
if [[ "$mode" == store || "$mode" == testflight ]]; then
  python3 scripts/store-package.py stamp "$app_dir" --mode "$mode"
fi
# Swift Build generates resource lookup through Bundle.main.resourceURL.
cp -R "$binary_dir/Clerk_ClerkKit.bundle" "$app_dir/Contents/Resources/"
cp -R "$binary_dir/RevenueCat_RevenueCat.bundle" "$app_dir/Contents/Resources/"
if [[ "$mode" != dev ]]; then
  cp "$staging_dir/signing/embedded.provisionprofile" "$app_dir/Contents/embedded.provisionprofile"
fi
codesign --force --sign "$signing_identity" --options runtime \
  --entitlements "$entitlements" "$app_dir"
codesign --verify --strict --verbose=2 "$app_dir"
if [[ -e "$output_dir/LessMeet.app" ]]; then
  mv "$output_dir/LessMeet.app" "$staging_dir/Previous-LessMeet.app"
fi
mv "$app_dir" "$output_dir/LessMeet.app"
printf 'Built %s\n' "$output_dir/LessMeet.app"
if [[ "$mode" == store || "$mode" == testflight ]]; then
  printf '%s artifact is an .app only; no installer .pkg was created or uploaded.\n' "$mode"
fi
