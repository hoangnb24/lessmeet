# LessMeet app icon v2 (local build icon)

Vector source: `LessMeet.svg` (editable). The mark is the website brand mark,
four bars slanted 17°, on a deep olive tile in the approved landing-page palette
(#4a6346 → #28362a, ivory #fbfbf5, accent #d4e3a5). No text and no third-party logo.
Tile follows the macOS 1024 grid (824 px tile at 100 px inset, 185 px radius).

Exports: `LessMeet-1024.png` (headless Chrome render of the SVG),
`LessMeet.iconset/` (16–512 @1x/@2x via `sips`), `LessMeet.icns` (`iconutil`).
`store-package.validate_icon` accepts the ICNS.

`scripts/build-app.sh` copies `LessMeet.icns` into every bundle and
`Resources/Info.plist` sets `CFBundleIconFile`. Store/TestFlight stamping still
replaces it with the separately approved icon (`LESSMEET_ICON_ICNS` plus approval
record); this icon is not a release/Store approval. `lessmeet-testflight-v1` is kept.

Regenerate:

    cd Resources/Artwork/lessmeet-v2
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
      --default-background-color=00000000 --window-size=1024,1024 \
      --screenshot="$PWD/LessMeet-1024.png" "file://$PWD/LessMeet.svg"
    for s in 16 32 128 256 512; do sips -z $s $s LessMeet-1024.png --out LessMeet.iconset/icon_${s}x${s}.png
      sips -z $((s*2)) $((s*2)) LessMeet-1024.png --out LessMeet.iconset/icon_${s}x${s}@2x.png; done
    iconutil -c icns -o LessMeet.icns LessMeet.iconset
