#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-dev}"
action="${2:-build}"
if [[ $# -gt 2 || ! "$mode" =~ ^(dev|local|signed-local|offline-check|chat-ui-check|library-ui-check|auth-check|sandbox-dev|store|testflight)$ || ! "$action" =~ ^(build|--preflight)$ ]]; then
  printf 'Usage: bash scripts/build-app.sh [dev|local|signed-local|offline-check|chat-ui-check|library-ui-check|auth-check|sandbox-dev|store|testflight] [--preflight]\n' >&2
  exit 1
fi
if [[ "$mode" == signed-local ]]; then
  if [[ "$action" == --preflight ]]; then
    exec python3 scripts/packaging-signing.py signed-local
  fi
  # The wrapper compiles without signing inputs, then signs a separate copy.
  exec python3 scripts/sign-local-app.py --build --output dist/signed-local/LessMeet.app
fi
output_dir="$PWD/dist"
profile_mode=false
if [[ "$mode" =~ ^(sandbox-dev|store|testflight)$ ]]; then
  profile_mode=true
fi
signing_identity="${LESSMEET_SIGNING_IDENTITY:--}"
if [[ "$mode" == offline-check || "$mode" == chat-ui-check || "$mode" == library-ui-check ]]; then
  # Offline checks must not unlock a signing key inherited from the shell.
  signing_identity="-"
fi
if [[ "$mode" == auth-check ]]; then
  identity_text="${signing_identity//[[:space:]]/}"
  if [[ -z "$identity_text" || "$identity_text" == - ]]; then
    printf 'auth-check requires explicit non-ad-hoc LESSMEET_SIGNING_IDENTITY.\n' >&2
    exit 1
  fi
fi
if [[ "$mode" != dev ]]; then
  output_dir="$output_dir/$mode"
  node scripts/configure-app.mjs --check "$mode"
  if [[ "$mode" == store || "$mode" == testflight ]]; then
    python3 scripts/store-package.py inputs --mode "$mode"
  fi
  if [[ "$action" == --preflight ]]; then
    if [[ "$profile_mode" == true ]]; then
      python3 scripts/packaging-signing.py "$mode"
    fi
    exit 0
  fi
elif [[ "$action" == --preflight ]]; then
  node scripts/configure-app.mjs --check dev
  exit 0
fi
# Check the required shader compiler before resolving or compiling the app.
xcrun -sdk macosx metal --version >/dev/null
mkdir -p "$output_dir"
staging_dir="$(mktemp -d "$output_dir/build.XXXXXX")"
entitlements="Resources/LessMeet.entitlements"
if [[ "$profile_mode" == true ]]; then
  python3 scripts/packaging-signing.py "$mode" --output "$staging_dir/signing"
  signing_identity="$(<"$staging_dir/signing/identity.txt")"
  entitlements="$staging_dir/signing/entitlements.plist"
fi
scratch_dir="$output_dir/swift-build"
# The pinned SpeechVAD dependency requires Apple Silicon (including Float16).
build_args=(-c release --build-system swiftbuild --arch arm64 --disable-keychain --disable-netrc --scratch-path "$scratch_dir")
if [[ "$mode" == offline-check ]]; then
  build_args+=(-Xswiftc -DLESSMEET_OFFLINE_CHECK)
elif [[ "$mode" == chat-ui-check ]]; then
  build_args+=(-Xswiftc -DLESSMEET_CHAT_UI_CHECK)
elif [[ "$mode" == library-ui-check ]]; then
  build_args+=(-Xswiftc -DLESSMEET_LIBRARY_UI_CHECK)
fi
swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
app_dir="$staging_dir/LessMeet.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/LessMeet" "$app_dir/Contents/MacOS/LessMeet"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
node scripts/configure-app.mjs "$app_dir/Contents/Info.plist" "$mode"
# Store/TestFlight stamping below replaces this with the separately approved icon.
cp Resources/Artwork/lessmeet-v2/LessMeet.icns "$app_dir/Contents/Resources/LessMeet.icns"
if [[ "$mode" == store || "$mode" == testflight ]]; then
  python3 scripts/store-package.py stamp "$app_dir" --mode "$mode"
fi
# Swift Build generates resource lookup through Bundle.main.resourceURL.
for resource_bundle in Clerk_ClerkKit.bundle LessMeet_LessMeet.bundle \
  swift-transformers_Hub.bundle swift-crypto_Crypto.bundle; do
  test -d "$binary_dir/$resource_bundle"
  cp -R "$binary_dir/$resource_bundle" "$app_dir/Contents/Resources/"
  diff -qr "$binary_dir/$resource_bundle" "$app_dir/Contents/Resources/$resource_bundle"
done
# MLX loads its Metal library beside the statically linked executable.
checkouts_dir="$scratch_dir/checkouts"
for dependency in speech-swift mlx-swift; do
  expected_revision="$(node -e 'const fs = require("node:fs"); const pins = JSON.parse(fs.readFileSync("Package.resolved", "utf8")).pins; const pin = pins.find(p => p.identity === process.argv[1]); if (!pin?.state.revision) process.exit(1); process.stdout.write(pin.state.revision)' "$dependency")"
  test "$(git -C "$checkouts_dir/$dependency" rev-parse HEAD)" = "$expected_revision"
  test -z "$(git -C "$checkouts_dir/$dependency" status --porcelain)"
done
metal_build="$staging_dir/mlx-build"
mkdir -p "$metal_build/release"
ln -s "$checkouts_dir" "$metal_build/checkouts"
BUILD_DIR="$metal_build" MACOSX_DEPLOYMENT_TARGET=15.0 MLX_METAL_LANGUAGE_VERSION=3.2 \
  bash "$checkouts_dir/speech-swift/scripts/build_mlx_metallib.sh" release
test -s "$metal_build/release/mlx.metallib"
cp "$metal_build/release/mlx.metallib" "$app_dir/Contents/Resources/"
# Keep shader bytes out of the nested-code directory while preserving MLX lookup.
ln -s ../Resources/mlx.metallib "$app_dir/Contents/MacOS/mlx.metallib"
cmp "$metal_build/release/mlx.metallib" "$app_dir/Contents/MacOS/mlx.metallib"
# Model notices must be present and unchanged before signing.
model_notices=(Nemotron-LICENSE.txt Nemotron-NOTICE.txt OpenAI-Whisper-LICENSE.txt
  SOURCES.md WhisperKit-LICENSE.txt WhisperKit-NOTICES.txt speech-swift-LICENSE.txt)
for notice_name in "${model_notices[@]}"; do
  test -f "Resources/ModelLicenses/$notice_name"
done
cp -R Resources/ModelLicenses "$app_dir/Contents/Resources/ModelLicenses"
diff -qr Resources/ModelLicenses "$app_dir/Contents/Resources/ModelLicenses"
if [[ "$profile_mode" == true ]]; then
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
