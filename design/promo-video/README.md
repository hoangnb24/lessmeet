# LessMeet promo video

`out/LessMeet-ad-30s-1080p60.mp4` is a 30 s ad at 1920×1080 and 60 fps, with H.264 video and AAC audio.
The poster frame is `out/poster-ad.png`.

Every app frame comes from the real LessMeet app (`library-ui-check` fixture build) running on a Mac.
The app's own window is captured in-process at 60 fps by `DemoWindowRecorder`
(`Sources/LessMeet/Presentation/DemoCapture.swift`).
An XCUITest driver (`driver/`) clicks and types into the real controls and logs each action.
`app/ad.py` draws the titles, cursor and zooms with Pillow. It synthesizes music and SFX in Python,
synced to the logged actions, and assembles the result with FFmpeg.

| Time | Scene |
| --- | --- |
| 0–3 s | Hook: "A 47-minute meeting. One question: What did we decide?" |
| 3–5 s | Icon and the line "LessMeet remembers so you don't have to." |
| 5–23 s | Real app: record, stop, transcript, ask, streamed answer with decisions and owners |
| 23–30 s | Wordmark, tagline, "Coming soon for Mac" |

Reproduce from the saved take (deterministic):

```sh
cd design/promo-video && python3 app/ad.py capture out/LessMeet-ad-30s-1080p60.mp4
```

To record a new take, run `bash scripts/build-app.sh library-ui-check`, then
`bash design/promo-video/app/record.sh`. This needs Xcode UI-automation access.

Limits:
- The app runs as an offline demo build with a sample meeting. The chat answer is a local fixture,
  not a ChatGPT reply.
- Some shots are sped up 1.6–2×.
- The video notes these limits on screen.

Assets:
- The icon is original to this project.
- Captions use macOS system fonts.
- All audio is synthesized in code.
- ChatGPT is a trademark of OpenAI. LessMeet is not endorsed by OpenAI.
