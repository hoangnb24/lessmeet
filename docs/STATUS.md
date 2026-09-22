# LessMeet delivery

## Product decisions

Native macOS Swift app. Start/Stop records microphone and system audio separately;
preserve both and create one time-aligned combined audio file. Local recording
library and details, explicit Gemini transcription, readable Markdown, transcript
chat beside/below it. Store recordings in Application Support. No automatic cloud
upload, video storage, account/backend, meeting bot, or speculative features.
Human explicitly forbids Keychain and clarified this product supports many users.
Backend must be Convex. Direct native BYOK architecture is REOPENED: Swift owns
recording/UI, authenticated backend owns Gemini calls. Human decision pending:
shared app-funded Gemini key vs per-user keys; auth/project provisioning.
No deployment, shared-key billing exposure or credential persistence authorized.
User asked for latest Gemini, Vercel AI SDK
feasibility research, Uncle Bob references, Peers, feature commits and push.
Repository: hoangnb24/lessmeet, private default announced to Human.

## Architecture

Separate capture, persistence, Gemini transport and presentation because OS APIs,
storage format, provider protocol and layout change independently. Plain Codable
records cross these boundaries. Prefer concrete types; no generic DI framework.
References read: unclebob core rules, development workflow, change-driven boundaries
and project structure. Verify storage separately without UI or network; remove
boundaries if they only forward calls without isolating change.

## Ownership and frontier

- Lead: foundation, contracts, persistence, build packaging, integration/status.
- Capture research ACCEPTED: macOS 15 ScreenCaptureKit dual output, shared PTS,
  no video persistence. Use small bounded buffers; no wait for both sources.
- Capture Peer 3649b51a returned ownership. Lead ACCEPTS implementation snapshot
  CaptureAudioRecorder ae88bea38136, CaptureService b70d58deb5f7,
  CaptureAudioTests cb1a04b87f1d after inspection/hash matching and 12 passing tests.
  This is not hardware/runtime-quality acceptance. Contract @MainActor CaptureService,
  init(), onFailure: ((String)->Void)?, start(directory: URL) async throws,
  stop() async throws -> CaptureResult(duration: TimeInterval, warning: String?).
  Output microphone/system source files and combined.m4a. Original tracks survive
  combine failure. Lead owns lifecycle UI/persistence.
- Gemini model/API research accepted; direct Swift transport STOPPED; handback
  confirmed no files created, write ownership relinquished. Old client/storage
  contracts revoked, not implementation prerequisites. Vercel SDK is now a viable
  backend option because Human established multi-user Convex architecture.
- Gemini Peer read-only followup ACCEPTED for research, not runtime: published
  @ai-sdk/google 4.0.76 has google.interactions; Convex authenticated HTTP actions
  are a plausible native boundary. Upload/auth/cost policy remains undecided;
  proposed endpoint list is NOT an accepted implementation contract.
  No backend writes until shared-cost/auth decisions are resolved.
  Reference dependency resolved: /Users/tubakhuym/projects/unclebob/references.

## Milestones

1. Foundation, local library and launchable app bundle.
2. Dual capture and aligned combined playback.
3. Gemini transcript and chat, integrated native UI.
4. Focused verification, independent candidate inspection, usable handoff.

Local UI work by Lead: library/detail, rename, playback, Markdown presentation,
recording lifecycle. Cloud actions are explicitly unavailable pending backend;
placeholder presentation is not acceptance of transcript/chat features.
Read-only Peer 9e349c18 completed UI/store inspection; no ownership outstanding.
Review disposition: ACCEPT two findings, REJECT initial UI/store snapshot. Lead
fixed initial playback loading (onChange initial:true) and per-folder load isolation
with visible warning. Added one storage regression. Lead ACCEPTS revised code
(AppModel 6a053d45a3a5, LibraryView dc4b900fb6ae, Store 9cf82028f38e,
StoreTests 3e38d5447f56); 12 total tests pass. Runtime UI/reopen still unverified.

## Verification

Environment: macOS arm64, Xcode 26.6, Swift 6.3.3. Project initially empty.
Foundation: swift test passed 2 storage/reopen tests; bash scripts/build-app.sh
built release bundle and codesign --verify --strict passed. No capture, UI, or live Gemini behavior verified yet. TCC and paid live API
checks require human participation; never equate fixture tests with real capture.
Integration check: swift test passed 7 tests on initial capture candidate; release
bundle launched with observed 1180x760 window. Window-only screenshot FAILED
(screencapture: could not create image from window); rendered UI not visually verified.
Final corrected candidate: swift test passes 12 (9 capture, 3 storage),
bash scripts/build-app.sh passes release build and codesign --verify --strict.
git diff --check passes. Source/test hashes above identify inspected bytes.
Silence >5s is preserved; startup failure propagates through cleanup. The 30s
clock sanity check, live device timing, TCC and audible quality require real use.

## Handoff / next frontier

Local recorder implementation and library can be tried via dist/LessMeet.app;
README has build/run and manual checks. No personal audio captured or cloud API
called. No active writable Peer remains. Cloud transcript/chat/login are NOT
implemented; Human must choose shared-funded vs per-user Gemini keys and auth/
Convex project setup. Lead recommendation: server-held key and authenticated
Convex actions using Vercel AI SDK, with explicit allowed-user/budget limits before
deployment. Reopen backend implementation at that decision, not by guessing.
