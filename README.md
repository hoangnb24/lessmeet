# LessMeet

A native Swift macOS app for local microphone + system-audio recordings, with
Gemini transcription and transcript chat through an owner-isolated Convex backend.

This checkout contains the cloud-backed app. Production provisioning is recorded,
but public-release acceptance is incomplete. Source code, deployed versions and
live verification have different checkpoints. Start with these references:

- [Current work and acceptance](docs/STATUS.md).
- [Configuration and secret locations](docs/CONFIGURATION.md).
- [HTTP and deletion contracts](docs/BACKEND.md).
- [Internal batch transcription and chat](docs/BATCH_CONTRACT.md).
- [Sandbox billing checks](docs/STORE_SANDBOX.md).
- [Approved visual direction](docs/DESIGN.md).

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
An isolated signed `sandbox-dev` app was accepted for internal testing. Store
distribution signing and installer tooling exist but real Store packaging/upload
remain unverified. Sign In with Apple was enabled on the App ID on Sep 24;
provisioning profiles must be regenerated before future signing. See
[packaging inputs](Tests/packaging/STORE_INPUTS.md).

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

Synthetic 30/60/120-minute exports exceeded the legacy single-upload limit of
18 MiB. The current transcript action prepares bounded chunks instead; its internal
backend gates can still block uploads. Neither route establishes real-device sound
quality or drift. See the [export measurements](Tests/LessMeetTests/LONG_CAPTURE_HANDOFF.md)
and [batch limits](docs/BATCH_CONTRACT.md).

## Account and cloud

Clerk handles hosted sign-in. Login sessions may use Keychain; Gemini keys never
enter the app. Convex holds the owner-funded Gemini key and checks each request's
owner. Missing `GEMINI_BILLABLE_ENABLED` disables new AI work. Billing and internal
batch gates impose additional checks.

Cloud audio, transcripts and chat remain stored indefinitely unless the deletion
workflow removes them. Account deletion preserves local files and does not cancel
Apple renewal. Provider workers exist, but a local implementation is not proof of
live fulfillment. See the [deletion runbook](docs/legal/DELETION_RUNBOOK.md) for the
accepted scope, seven-calendar-day operating policy and remaining evidence.

**Plan & usage** in the sidebar shows server-verified allowances and offers
purchase/restore when configured. RevenueCat identifies the signed-in Clerk user;
it never authorizes cloud work by itself. Free includes one-time 120 minutes and
20 questions; Pro includes 1,200 minutes and 200 questions each month, also on
annual billing. Pricing targets are USD 9.99/month or 99.99/year; actual purchase
prices come from StoreKit. See [rollout prerequisites](docs/BACKEND.md#subscription-integration-development-sandbox-production-pending).
Purchases stay disabled without legal links, store configuration and active server
enforcement. Internal `sandbox-dev` permits explicitly acknowledged unpublished
legal links; Store mode does not. Local recording remains available without billing.

Before building, set public `CLERK_PUBLISHABLE_KEY` and `CONVEX_SITE_URL` in ignored
`.env.local`. The packaging script copies only allowlisted public values into Info.plist.
Missing account configuration does not prevent local recording. Clerk requires
Native API enabled, `com.lessmeet.app://callback` registered, and session claim
`aud: convex`. Convex uses `CLERK_JWT_ISSUER_DOMAIN` for the Clerk issuer.
Production Google/Apple provider credentials and distribution signing are separate
setup; development shared OAuth credentials do not establish production readiness.

### Using transcript and chat

1. Connect your account from the sidebar and sign in if needed.
2. Select a saved recording and choose **Create Transcript**.
3. Review the upload notice, then choose **Upload and Create Transcript**.
4. After reopening or a connection failure, use **Refresh** before continuing.
5. When the batch is complete and chat is available, enter a question and choose **Send**.

The app derives chunks from `combined.m4a`: at most five minutes each, with
five-second overlap, a 120-minute source cap and an 18 MiB cap per chunk. Originals
stay on the Mac. It saves the batch identity and manifest before the first request.
The backend requires an enabled, exact-owner-allowlisted internal batch service;
chat has a separate gate and requires complete results that fit its context limit.
For example, a 600-second source produces three chunks starting at 0, 295 and
590 seconds. The five-second overlap accounts for the third, ten-second chunk.

Saved legacy single-upload transcripts and their chat remain separate. Results
are stored per backend and Clerk account. Signing out hides cloud caches but keeps
local recordings. These caches are not encrypted by the app and do not protect
data from the macOS user. See the [batch contract](docs/BATCH_CONTRACT.md) for
recovery, partial results and explicit retry rules.

**Meeting notes → Summarize / Action items** prepares a grounded question in the
composer; review and Send explicitly. Each successful request consumes one AI
question when quotas are enabled, with the result saved in the conversation.

**Stop Waiting** cancels local waiting, not work already accepted by the server.
Batch recovery uses the saved identity. Unknown generation is not automatically
retried. The legacy single-upload route cannot recover an upload whose response
was lost before its remote ID was saved. Resubmitting it may incur another charge.
Failed or oversized uploads never replace local audio.

### Convex development setup

Project: [hoang-bang/lessmeet](https://dashboard.convex.dev/t/hoang-bang/lessmeet).
Dev deployment: `zany-octopus-315` (US East). Production is a separate target;
see [accounts and environments](docs/CONFIGURATION.md#accounts-and-environments).

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

The backend uses the Vercel AI SDK Google provider. The default model is
`gemini-flash-latest`, with a server-side `GEMINI_MODEL` override. Native requests
use the [HTTP contract](docs/BACKEND.md), not a Convex Swift SDK integration.

## Verification and next checks

Backend: run `npm run typecheck:backend` and `npm run test:backend`.
Tests cover anonymous/cross-user rejection, owner upload/transcript/chat with a
mocked provider, and the actual pinned SDK request format using mocked HTTP.
These automated checks use no live Gemini request. Separately, Human reported one
successful end-to-end round and core sandbox billing checks; this does not establish
the current release binary's complete runtime matrix or production readiness.

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

### Agent native UI checks

Use Xcode and the repeatable offline UI suite to validate agent changes:

```sh
bash scripts/test-ui.sh
```

The runner saves an Xcode `.xcresult` report, screenshots, accessibility text and
build/test logs under ignored `.artifacts/verify-lessmeet/`. It checks account
refresh, failures, delayed responses, account switching and confirmation without
live accounts or paid calls. It requires a logged-in macOS desktop and UI automation
permissions. See [Xcode testing and debugging](Tests/UI/README.md) for the shared
Xcode scheme, model/component debugging and proof limits. These fixture tests do
not establish live recording, cloud or billing behavior.

Use the project skill [lessmeet-app-check](.agents/skills/lessmeet-app-check/SKILL.md)
for native UI diagnosis and verification. `AGENTS.md` defines when it is required.
The skill contains the Computer Use procedure, evidence requirements and limits.

#### Checks without Keychain

Build the isolated fixture app:

```sh
bash scripts/build-app.sh offline-check
open dist/offline-check/LessMeet.app
```

This build uses `LESSMEET_OFFLINE_CHECK` at compile time. Its entry point never
creates Clerk, a recording library, a cloud client or billing. It uses a separate
bundle ID, `com.lessmeet.app.offline-check`, and no OAuth callback. Packaging
ignores `.env.local` and service configuration from the environment. A runtime
environment variable cannot enable the fixture entry point in a normal build.
Offline packaging always uses ad-hoc signing. It ignores an inherited signing
identity so the build does not need to unlock a private signing key.

1. Select a synthetic response.
2. Click **Refresh deletion status**.
3. Check the applied response or synthetic error.
4. For **Wait for response**, click **Complete pending response** to finish it.
5. To check stale-response handling, select **Wait for response**, click Refresh,
   then click **Switch synthetic account**. The previous response must not apply.

The fixture shares the real deletion view/model. Delete and subscription links
are disabled or absent. These checks do not verify OAuth, Keychain permissions,
HTTP transport, billing, recording or production deletion.

#### Real account connection

Normal app startup stays local. Opening Account does not access Clerk. Click
**Connect Account** to restore the saved session, then sign in if needed.
This does not sign out or delete the saved session between launches.
Clerk 1.5.5 still reads Keychain synchronously on the main thread when connecting.
The connection can wait for a macOS prompt; it is not a background-safe SDK call.

For live auth checks, use `bash scripts/build-app.sh auth-check --preflight`
before building with `bash scripts/build-app.sh auth-check`. This mode requires
an explicit `LESSMEET_SIGNING_IDENTITY` other than `-` and explicit public
`CLERK_PUBLISHABLE_KEY` and `CONVEX_SITE_URL` values. It does not read `.env.local`.
Use the same approved signing identity across trial builds. A switch from an
ad-hoc signature can still require one new Keychain authorization. A valid
signature alone does not prove the item allows access. Do not change profiles,
Keychain access rules or production configuration to make a check pass.

If connection stalls:

1. Identify the exact running app path and signing requirement with
   `codesign -d -r- --verbose=4 /absolute/path/to/LessMeet.app`.
2. Inspect a short stack sample of that exact process. Distinguish a Keychain
   wait from an ordinary event loop or a Computer Use connection failure.
3. Inspect the current system prompt through Computer Use if available. Do not
   repeat timed-out clicks or infer permission denial from a timeout.
4. If authorization is needed, ask the operator to approve only the identified
   app/item. The operator enters any password directly; never request it in chat.
5. Read fresh app state after the operator action, then resume the bounded check.

Do not reset Keychain, delete cached sessions or grant blanket access. Continue
offline work while live auth is blocked. Record live results as UNVERIFIED until
the exact artifact and requested behavior have runtime evidence.
