# LessMeet delivery

## Product decisions

Native macOS Swift app. Start/Stop records microphone and system audio separately;
preserve both and create one time-aligned combined audio file. Local recording
library and details, explicit Gemini transcription, readable Markdown, transcript
chat beside/below it. Store recordings in Application Support. No automatic cloud
upload, video storage, account/backend, meeting bot, or speculative features.
API credentials belong in Keychain. User asked for latest Gemini, Vercel AI SDK
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
- Capture research Peer 3649b51a: read-only native/TCC/timeline recommendation.
- Gemini research ACCEPTED: direct URLSession, BYOK Keychain, gemini-3.8-flash,
  Interactions store:false. Official model/catalog and Interactions docs inspected.
  Vercel TypeScript would require a backend; omitted to preserve native simplicity.
- Gemini Peer 2f9139f4 owns Sources/LessMeet/Gemini and Tests/LessMeetTests/Gemini*.
  Contract: GeminiClient(apiKey:model:session: default URLSession.shared), async
  transcribe(audioURL:) -> TranscriptionResult(text:String, warning:String?),
  reply(transcript:messages:) -> String; messages are accepted ChatMessage values.
  Each reply sends transcript and labeled chat as a fresh text context (not a
  reconstructed Interactions step history). No tools or hidden state required.
  APIKeyStore static load() throws -> String?, save(_ key:String) throws.

## Milestones

1. Foundation, local library and launchable app bundle.
2. Dual capture and aligned combined playback.
3. Gemini transcript and chat, integrated native UI.
4. Focused verification, independent candidate inspection, usable handoff.

## Verification

Environment: macOS arm64, Xcode 26.6, Swift 6.3.3. Project initially empty.
Foundation: swift test passed 2 storage/reopen tests; bash scripts/build-app.sh
built release bundle and codesign --verify --strict passed. No capture, UI, or live Gemini behavior verified yet. TCC and paid live API
checks require human participation; never equate fixture tests with real capture.
