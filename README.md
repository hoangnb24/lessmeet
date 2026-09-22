# LessMeet

A native Swift macOS app for local microphone + system-audio recordings, with
Gemini transcription and transcript chat planned through a multi-user Convex backend.

## Run locally

Requires macOS 15+ and Xcode/Swift toolchain.

```sh
swift test
bash scripts/build-app.sh
open dist/LessMeet.app
```

Open `Package.swift` in Xcode to browse/debug. For recording permission checks, use
the packaged `.app`, not `swift run`: the bundle contains the usage descriptions
and hardened-runtime audio-input entitlement. Development builds are ad-hoc signed;
set `LESSMEET_SIGNING_IDENTITY` to your own identity for stable signed builds.
Distribution signing/notarization and App Store sandboxing are not configured.

## Recording

Click **Start Recording** and grant Microphone and Screen & System Audio Recording
access. If macOS asks for a relaunch, reopen the app and start a new recording.
Click **Stop Recording**, wait for saving, then play or reveal the recording files.
Use headphones to avoid the microphone picking up your speaker output.

System audio means the whole system, excluding LessMeet playback—not a selected
meeting app. No video track is saved. Obtain participants' consent before recording.

Recordings live at `~/Library/Application Support/LessMeet/Recordings/<UUID>/`:

- `recording.json`: title, date, duration, status, transcript and chat.
- `microphone.caf`, `system.caf`: separate source audio when received.
- `capture-timeline.json`: source offsets for the common timeline.
- `combined.m4a`: derived audio for playback/transcription.

Original audio is retained if combining fails. A recording interrupted by app
termination is marked interrupted when the library is reopened. Automatic repair,
device switching, pause/resume and cloud sync are outside the first version.

## Cloud work is not configured yet

This is a multi-user product. Gemini keys will **not** be saved in Keychain or
bundled in Swift. Convex is the required backend; Vercel AI SDK can run in its
TypeScript actions. The product owner funds one shared key in Convex env. Login
setup remains pending before implementation of billable endpoints. Transcript/chat
presentation exists, but no AI requests or login are wired yet.

### Convex development setup

Project: [hoang-bang/lessmeet](https://dashboard.convex.dev/t/hoang-bang/lessmeet).
Dev deployment: `zany-octopus-315` (US East); no production deployment yet.

```sh
npm ci
npx convex deployment select hoang-bang:lessmeet:dev/lessmeet
npx convex env set GEMINI_API_KEY
npx convex env list --names-only
```

Enter the key through the CLI prompt or the deployment dashboard's Environment
Variables page. Do not put it in Swift, source files, shell arguments or chat.
Environment variables are deployment-specific. Local Convex selection is kept in
ignored `.env.local`. No Gemini key has been set by the setup work.

Research: [Vercel AI SDK](https://ai-sdk.dev/docs/getting-started/nodejs),
[Google provider](https://github.com/vercel/ai/blob/main/packages/google/src/google-provider.ts),
[Convex Swift](https://docs.convex.dev/client/swift/overview),
[Gemini model catalog](https://ai.google.dev/gemini-api/docs/models),
[Interactions API](https://ai.google.dev/gemini-api/docs/interactions-overview).
`gemini-3.8-flash` is the documented default selected on 2026-09-22; actual project
access and response quality have not been tested.

## Verification and next checks

`swift test` exercises persistence/reopen and synthetic sample buffers through the
real CAF/M4A writer/exporter. These do not prove live capture, acoustic quality,
long-session synchronization, TCC behavior, or macOS 15 runtime compatibility.

Before considering the recorder verified, record a short known conversation with
mic-only, system-only and overlapping speech, including a long pause in playback.
Stop, quit, reopen and listen to the beginning/end and both source files. Repeat
with denied permissions. Test on the intended microphone/headphones.

Current decisions, ownership and acceptance: [docs/STATUS.md](docs/STATUS.md).
