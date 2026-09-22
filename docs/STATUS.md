# LessMeet delivery

## Product decisions

Native macOS Swift app. Start/Stop records microphone and system audio separately;
preserve both and create one time-aligned combined audio file. Local recording
library and details, explicit Gemini transcription, readable Markdown, transcript
chat beside/below it. Store recordings in Application Support. No automatic cloud
upload, video storage, meeting bot, or speculative features.
Layout correction: no vertical-only constraint. Preserve the established UI and
architecture; implement only necessary working behavior, not speculative abstractions.
Human explicitly forbids storing Gemini API keys in Keychain and clarified this product supports many users.
Backend must be Convex. Direct native BYOK architecture is REOPENED: Swift owns
recording/UI, authenticated backend owns Gemini calls. Human chose a shared Gemini
key funded by the product owner, stored only in Convex environment variables.
Convex setup authorized; CLI login verified in team hoang-bang. Created project
lessmeet and development deployment zany-octopus-315 (dev/lessmeet), US East.
No production deployment or paid Gemini test calls. Authenticated development
endpoints deployed as requested; no anonymous AI access.
Authentication choice ACCEPTED: Clerk with Google and Apple. Clerk application
configuration in progress through authenticated `npx clerk`, explicitly requested
by Human. Separate LessMeet development application created and linked:
app_3JggBoRulgsbt70ZFjgy9h7UjqQ, instance ins_3JggBsWybMahxou8G4rXVmM2Snu.
Human supplied Gemini key; names-only Convex CLI confirms GEMINI_API_KEY exists.
Never read or print its value. Login session storage is a separate concern from
the forbidden client-side Gemini key; inspect SDK behavior before integrating.
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
  are a plausible native boundary. Earlier proposed endpoint list is superseded
  by the active backend contract below.
  Shared-cost/auth provider decisions resolved: owner-funded key in Convex env,
  Clerk Google+Apple. Auth configuration remains a prerequisite for billable endpoints.
  CLI setup complete; development backend deployed (see verification below).
  Reference dependency resolved: /Users/tubakhuym/projects/unclebob/references.

## Milestones

1. Foundation, local library and launchable app bundle.
2. Dual capture and aligned combined playback.
3. Gemini transcript and chat, integrated native UI.
4. Focused verification, independent candidate inspection, usable handoff.

## Active backend contract (supersedes earlier proposed endpoint list)

Human requests implementing owner-isolated Gemini backend now; key is configured.
Peer 2f9139f4 returned backend candidate and relinquished all write ownership.
Lead ACCEPTS backend candidate after source inspection, rerun tests and independent
Peer 516c4047 inspection with unchanged hashes. ACCEPT bounded findings: no concrete
owner/privacy/SDK blocker; not complete security or runtime proof. All Peer scopes
closed; Lead owns development deployment and unauthenticated/invalid-token smoke.
Candidate over d039146: http 29240b0d809e, recordings e58c626a30e8,
jobs fddc939ec3e9, gemini 745d4b1995b3, schema 53bdedb2389d,
limits e6530d1c2322. Writer reports codegen/typecheck/13 tests/diff check passed.
Lead reran npm run typecheck:backend and npm run test:backend: PASS, 13 tests in
3 files; git diff --check PASS. Includes owner/other-user/anonymous HTTP+DB paths
and real pinned SDK request construction against mocked HTTP. No live API proof.
Development deploy via npx convex dev --once --typecheck enable --tail-logs disable
PASSED to zany-octopus-315. Initial live negative smoke: absent tokens returned401
on all four routes; invalid tokens returned500, not the promised401. No data/AI
access occurred. Lead traced getUserIdentity throwing for malformed JWT before
route error handling and added one shared safe auth wrapper returning401. This
supersedes http hash above. Lead ACCEPTS revised http 286b1ce62e65 after repeat
typecheck,13 tests,dev deployment and eight live negative-auth requests all PASS:
absent/invalid tokens on GET /account, GET/POST /recordings, POST /chat return401
with the safe sign-in error. Keep initial500 evidence separate from final pass.
No valid live JWT, personal audio upload or paid Gemini request was exercised.
Backend contract/retention/limits documented in docs/BACKEND.md. Next frontier:
connect native Swift cloud actions, then human-assisted valid login/audio trial.
Lead owns docs, acceptance and deployment; no live paid API tests.
Accepted MVP: authenticated HTTP POST /recordings with raw audio (max 18 MiB,
below Convex HTTP 20 MB limit) creates server-owned storage + record and schedules
internal transcription; returns 202 {recordingId}. GET /recordings?id=... returns
only owner's status/transcript/messages. POST /chat {recordingId,message} uses
owned server transcript/history, persists the exchange and returns {text}.
Keep GET /account. Identity is always derived from ctx.auth, never client owner IDs.
No public storage URLs or client-supplied storage IDs, no shared caches/history.
Internal helpers only, except HTTP routes. Gemini key only process.env.GEMINI_API_KEY;
Vercel AI SDK Google provider, default gemini-flash-latest (server env override).
Model availability remains live-unverified. No vector DB, tools, streaming, billing
framework, automatic retry or deletion feature. Bound inputs/output/history; preserve
local recording and expose actionable safe failures. Oversize audio is rejected,
not truncated. Before deployment, focused owner/other-user/unauthenticated tests
must pass and independent inspection must resolve concrete authorization risks.

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

Local recorder and Clerk login UI can be tried via dist/LessMeet.app; README has
build/run and manual checks. No personal audio captured or paid cloud API called.
Clerk development configuration and Gemini env-key existence are verified; real
OAuth remains untested. Backend implementation is active under the contract above.
No production deployment authorized. Owner-funded authenticated development use
is the requested direction; no billing framework or public anonymous AI endpoint.
Lead ran swift test: 16 passed (existing synthetic capture XPC diagnostics persist).
Auth/package milestone committed and pushed as d039146; backend remains separate.

Current auth frontier: ACCEPT Peer release research; ClerkKit 1.5.5 compiled on
native macOS. Use core SDK hosted authentication + ordinary session JWT over
URLSession; no ClerkConvex bridge. Clerk stores login state in Keychain (distinct
from Gemini key). Lead owns package, config, scripts, main UI wiring and backend.
Lead ACCEPTS Peer account candidate after source inspection and SHA-256 matching:
AccountSession 142528b64960, AccountPanel 0cb6721cb44b, tests 238d030f1f32.
Optional configuration preserves local recording; active/current session checks
protect token retrieval. Peer reports 2 account tests and 16 total tests passing;
this does not establish real login, restoration or backend token acceptance.
Account write ownership returned. Current bounded dispatch:
- Peer 2f9139f4 integration ACCEPTED after exact hash and diff inspection:
  LessMeetApp f4d894a21af8, LibraryView 7150aa4d4535. One app-owned session
  and existing sidebar panel; recording controls/layout unchanged. Peer reports
  swift build and 2 AccountSessionTests passed, scoped diff check passed.
  Ownership returned to Lead. Rendered sizing and real login remain unverified.
  Lead packaging check: release compilation passed, but bash scripts/build-app.sh
  FAILED codesign with "unsealed contents present in the bundle root" after adding
  Clerk_ClerkKit.bundle at root. Generated SwiftPM accessor expects bundle root or
  its build-directory fallback. Do not claim distributable auth app yet; Lead owns
  resolving signed resource placement without relying on the development path.
  Peer packaging diagnosis ACCEPTED for experiment: Swift Build engine generates
  resourceURL lookup. Lead changed script to swiftbuild release and fresh staging,
  resources under Contents/Resources; previous app retained on replacement.
  Lead verification PASSED: bash scripts/build-app.sh release build and strict
  codesign; generated release accessor searches Bundle.main.resourceURL and contains
  no absolute checkout fallback. Packaged privacy metadata and compiled English
  localization exist. Final dist/LessMeet.app strict signature verification passes.
  ACCEPT build/sign fix; separate-machine offline resource access and live login
  remain unverified. Previous app retained at dist/build.pM5la2/Previous-LessMeet.app.
  No vendor edits, custom signing exclusions or runtime features added.
- Read-only Peer f2550af2 configuration contract ACCEPTED: artifact hashes matched,
  server dry-run validated expected changes. Native API already enabled; no toggle
  needed. Lead successfully created com.lessmeet.app://callback redirect and applied
  session.claims.aud=convex plus Apple enabled=true in development via npx clerk.
  No production change or live sign-in. Post-apply GET confirms exactly one callback;
  config pull and filtered assertions confirm aud=convex, Apple and Google enabled.
  Real OAuth callback and minted JWT acceptance still unverified. Peer has no further scope.
- Lead: configuration, packaging, backend, UI integration, status and final acceptance.
No Clerk account,
Google/Apple credentials or secret values scanned outside this project.

## Convex setup evidence (2026-09-22)

- CLI 1.45.0 authenticated using existing login; read-only team/project API confirmed
  hoang-bang and no preexisting lessmeet project. No tokens or secret values printed.
- `convex project create lessmeet --team hoang-bang` succeeded.
- First deployment attempt using reserved `dev` alias failed without provisioning.
  `deployment create hoang-bang:lessmeet:dev/lessmeet --type dev --region us --default
  --select` created zany-octopus-315, then local selection failed for missing package.json.
- Added pinned Convex CLI dependency; `npm install --ignore-scripts --no-audit --no-fund`
  succeeded. `npx convex deployment select hoang-bang:lessmeet:dev/lessmeet` completed
  local configuration. `.env.local` and node_modules are ignored.
- `npx convex env list --names-only` succeeded: no environment variables set.
- No app code changed in this setup step; Swift tests were not rerun.
