# LessMeet

Release-preparation checkpoint (2026-09-24): account-deletion/automation, notification
and preflight source, legal/listing drafts and Store packaging tooling are locally
accepted, not deployed or published. Resend DNS/domain and a vault-stored sending
key are configured separately; backend sending remains off.
Deletion intake defaults off; work-ledger retention and fulfillment timing/channel
need operator decisions before deployment. See [current acceptance and remaining
gates](docs/STATUS.md), [configuration inventory and secret locations](docs/CONFIGURATION.md)
and [deletion contract](docs/BACKEND.md#account-deletion--local-candidate-not-deployed).
Older development/runtime notes below do not supersede this checkpoint.

A native Swift macOS app for local microphone + system-audio recordings, with
Gemini transcription and transcript chat through an owner-isolated Convex backend.

## Run locally

Requires macOS 15+, Swift 6.3 with the Swift Build engine, and Node 22+.

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

## Account and cloud

**Development cloud access is enabled** (`GEMINI_BILLABLE_ENABLED=true`). The owner
approved access for all authenticated users without aggregate quotas for now, and
indefinite cloud retention. The reversible switch defaults off if missing; it does
not replace per-record authorization. Existing technical size limits still apply.

This is a multi-user product. Gemini keys will **not** be saved in Keychain or
bundled in Swift. The product owner funds one shared key in Convex env.
Clerk hosted login is wired into the sidebar; Google and Apple are enabled for the
development instance. Clerk may persist login sessions in Keychain; this never
stores the Gemini key. Real login and Convex token acceptance still need verification.
Transcript/chat backend is deployed to development and connected to the Swift UI.
See [the HTTP contract](docs/BACKEND.md).
Audio uploads are limited to 18 MiB. Uploaded audio/transcripts remain in Convex
indefinitely on the deployed version. Local source now includes guarded in-app
deletion initiation, not yet deployed or live-verified. Core development sandbox
billing was Human-tested; see status for remaining lifecycle/release checks.

**Plan & usage** in the sidebar shows server-verified allowances and offers
purchase/restore when configured. RevenueCat identifies the signed-in Clerk user;
it never authorizes cloud work by itself. Free includes one-time 120 minutes and
20 questions; Pro includes 1,200 minutes and 200 questions each month, also on
annual billing. Pricing targets are USD 9.99/month or 99.99/year; actual purchase
prices come from StoreKit. See [rollout prerequisites](docs/BACKEND.md#subscription-integration-local-rollout-pending).
Purchases stay disabled without legal links, store configuration and active server
enforcement. Existing development access and local recording remain unchanged.

Before building, set public `CLERK_PUBLISHABLE_KEY` and `CONVEX_SITE_URL` in ignored
`.env.local`. The packaging script copies only allowlisted public values into Info.plist.
Missing account configuration does not prevent local recording. Clerk requires
Native API enabled, `com.lessmeet.app://callback` registered, and session claim
`aud: convex`. Convex uses `CLERK_JWT_ISSUER_DOMAIN` for the Clerk issuer.
Production Google/Apple provider credentials and distribution signing are separate
setup; development shared OAuth credentials do not establish production readiness.

### Using transcript and chat

Sign in from the sidebar, select a saved recording and choose **Create Transcript**.
Confirm the upload/retention notice. The app uploads only `combined.m4a`, saves the
remote ID and waits for Markdown transcription. Use **Refresh** after reopening
or a connection failure; it reuses the saved ID instead of uploading again.
Once ready, type a question and choose **Send**. Results are saved with the local
recording, separately for each backend/Clerk account. Signing out hides cloud caches;
the local recording library remains available. Local caches are not encrypted by
this app; this is account-aware UI isolation, not protection from the macOS user.

**Meeting notes → Summarize / Action items** prepares a grounded question in the
composer; review and Send explicitly. Each successful request consumes one AI
question when quotas are enabled, with the result saved in the conversation.

**Stop Waiting** cancels local waiting, not work already accepted by the server.
If the connection is lost before an upload ID is saved, the app cannot recover that
remote recording automatically. Uploading again may incur another charge. There
are no automatic mutation retries. Failed/oversize files never replace local audio.

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
ignored `.env.local`. The owner has set `GEMINI_API_KEY`; only its existence was
checked, never its value.

Research: [Vercel AI SDK](https://ai-sdk.dev/docs/getting-started/nodejs),
[Google provider](https://github.com/vercel/ai/blob/main/packages/google/src/google-provider.ts),
[Convex Swift](https://docs.convex.dev/client/swift/overview),
[Gemini model catalog](https://ai.google.dev/gemini-api/docs/models),
[Interactions API](https://ai.google.dev/gemini-api/docs/interactions-overview).
The backend contract uses `gemini-flash-latest`, with a server-side `GEMINI_MODEL`
override. Actual project access and response quality have not been tested.

## Verification and next checks

Backend: run `npm run typecheck:backend` and `npm run test:backend`.
Tests cover anonymous/cross-user rejection, owner upload/transcript/chat with a
mocked provider, and the actual pinned SDK request format using mocked HTTP.
No live Gemini request was made; model access/quality and real Clerk-token
acceptance remain unverified. Development deployment is not production rollout.

`swift test` exercises persistence/reopen and synthetic sample buffers through the
real CAF/M4A writer/exporter. These do not prove live capture, acoustic quality,
long-session synchronization, TCC behavior, or macOS 15 runtime compatibility.
The native suite includes billing identity/cancellation fixtures, HTTP contract,
cloud lifecycle, persistence and local rendering checks. Exact current acceptance
results are in STATUS.md. No real OAuth or paid Gemini call was used for these tests.

Before considering the recorder verified, record a short known conversation with
mic-only, system-only and overlapping speech, including a long pause in playback.
Stop, quit, reopen and listen to the beginning/end and both source files. Repeat
with denied permissions. Test on the intended microphone/headphones.

Current decisions, ownership and acceptance: [docs/STATUS.md](docs/STATUS.md).
