# Backend billing candidate — 2026-09-23

Original base: `b45f5c8fd70892e2dfb506899114aa68e4a1eafc`.
Uncommitted deterministic snapshot; no commit or deployment performed.
Writer relinquishes convex/**, Tests/backend/** and package.json/package-lock.json
ownership to Lead for independent inspection and acceptance. No other scope changed.
This evidence file is part of the handoff; its hash is supplied in the final response.

## Outcome and invariant snapshot

- GET /billing and bodyless POST /billing/sync authenticate with the existing
  Clerk auth boundary. Exact agreed DTO, no-store responses. Subject is the RC
  lookup key; tokenIdentifier remains the database ownership key. Client identity,
  plan, entitlement, and duration fields never authorize access or set charges.
- Unless BILLING_ENFORCEMENT_ENABLED is exactly true, no RC lookup or new quota
  reservation occurs. Status is development/enforcement=false with zero counts.
  Existing accepted media formats remain available in development mode.
- In enforced mode, every billing GET/sync and new billable request synchronously
  verifies RC. A queued transcription also verifies immediately before provider
  work. Missing/unavailable/malformed verification never falls back to cached Pro
  or guessed Free. A verification revision and monotonically nondecreasing RC
  request timestamp prevent older responses overwriting newer observations.
  Beginning verification invalidates prior freshness; failed refresh remains closed.
  Reservation requires matching revision, verification within 30s and unexpired Pro.
  Concurrent refreshes can deliberately return 409, requiring a user retry.
- Only lessmeet_pro and com.lessmeet.app.pro.monthly/yearly are recognized.
  App Store PURCHASED subscriptions only; lifetime, unknown products, promotional,
  family-shared and missing evidence are rejected. Sandbox rejected unless the
  separate REVENUECAT_ALLOW_SANDBOX=true server flag is explicitly set.
  Cancelled renewal retains access until expiry. Refund or expired subscription
  grants no Pro. Grace-period extension beyond verified expiry is not implemented.
- Free is 7200 transcription seconds plus 20 questions, lifetime. Pro is 72000
  seconds plus 200 questions per UTC monthly anniversary, including annual plans.
  Anniversary day clamps at month end without drifting after February.
  The FIRST verified subscription anniversary is pinned for that account: later
  product switches, refunds, repurchases and syncs do not reset a grant. This is
  intentionally conservative; a repurchase keeps the original allowance anniversary.
  periodEndsAt is the earlier of the allowance boundary and subscription expiry.
- Quota bucket updates and recording/chat lease acquisition are one transaction.
  Result persistence and charging are one transaction. Failures release reservations;
  matching leases/status and explicit deadlines prevent double settlement/late charge.
  Scheduler expiry releases abandoned reservations. Old-window reservations settle
  only into their original bucket, never the new month's grant. Free usage survives
  upgrades/downgrades. Summary/action-item requests use existing chat: one question.
- Existing GEMINI_BILLABLE_ENABLED kill switch and owner-isolated reads remain.
  Old development transcription jobs with no reservation fail closed if enforcement
  becomes enabled; users must upload again. No migration or historical backcharge.

## Mandatory rollout prerequisites — Lead/Human owns acceptance

1. Configure and VERIFY RevenueCat restore behavior "Keep with original App User ID".
   Only then set REVENUECAT_ORIGINAL_USER_POLICY_CONFIRMED=true server-side.
   Missing/false policy confirmation blocks billing status/sync and billable work
   with a safe setup error whenever enforcement is on.
2. Supply REVENUECAT_SECRET_API_KEY in the server environment (private sk_ key).
   No secret was inspected, printed, installed or changed during this work.
3. RC original_app_user_id MUST equal the authenticated Clerk subject, including
   Free status. Anonymous-origin aliases and different originals fail closed.
   Native must initialize identified sessions appropriately; not merely avoid
   anonymous purchases after creating an anonymous-origin customer.
4. Verify the actual project entitlement/products, production versus sandbox,
   original-user restore behavior across two Clerk accounts, and live v1 fields.
   The confirmation flag is an operator assertion, NOT a remote configuration audit.
   Transfer safety depends on the verified restore policy. No v2 transfer ledger or
   immutable subscription-chain identity was added. Do not activate without proof.

Official sources consulted:

- https://www.revenuecat.com/docs/api-v1
- https://www.revenuecat.com/docs/api-v1/customer-info-model
- https://www.revenuecat.com/docs/api-v1/customers
- https://www.revenuecat.com/docs/projects/restore-behavior
- https://github.com/gpac/mp4box.js

The official v1 example supplies subscriptions[product].original_purchase_date,
refunded_at and ownership_type. Code requires them; actual Lessmeet production
responses were NOT observed. Missing fields block access instead of granting Pro.
GET /subscribers/{subject} is documented Get or Create (200/201); verified empty
entitlements mean Free. A 404 is service failure, not evidence of a Free customer.
No SDK enrollment prerequisite is assumed beyond this documented endpoint behavior.

## Media validation and remaining risk

Pinned dependency mp4box 2.4.1 (BSD-3-Clause), no transitive packages added.
Enforced uploads accept non-fragmented, single-track AAC-LC M4A/MP4 only, mono or
stereo, enumerated 8–48kHz rates. MP4Box parses container/sample tables; code checks
complete box coverage, bounded sample expansion, sample payload ranges, monotonically
contiguous timelines, duration consistency, and simple rate-1 edits only.
Variable-size AAC sample tables are required. Limits are still 18MiB per upload,
plus at most 1,000,000 expanded samples and at most byteLength/4 samples.
Rounded charge is ceil(max(sample timing, AAC frame-count duration)). No duration
header is used. AAC padding can add a rounded second at an integer boundary.

This is STRUCTURAL validation, not AAC decoding or re-encoding. An attacker can
still forge mutually consistent container/codec metadata or compressed payloads
that decode differently or fail decoding. Frame-count checks reduce simple duration
header forgery; they do not prove decoder-equivalent duration or payload validity.
MP4Box parses inside the Convex action; malformed-container CPU/memory amplification,
deep nesting and full hostile-input fuzzing are NOT exhaustively validated. Input and
sample bounds do not prove deployed runtime resource safety. No production-load or
maximum-duration native export benchmark was performed. Lead must retain these
risks in activation review; a sandboxed full decoder is a possible later boundary,
not silently included in this implementation.

Actual native compatibility fixture: Tests/backend/nativeMediaFixture.ts stores
base64 of Lead's synthetic CapturedAudio.exportCombined/AVFoundation export.
Source PCM is 1.25s of sine tones/gaps; encoded AAC is 62464/48000s (~1.3013s).
Backend validation AND authenticated upload/job success fixtures charge 2 seconds.
Original binary SHA-256:
`3beb45db39003c2c3be14009a23c043948c21c67b636c81f5eb74413a8ee9bae`.
Lead supplied it from /tmp/lessmeet-billing-fixture.mbJ9Ln/native.m4a after running:
`LESSMEET_SYNTHETIC_M4A_OUTPUT=<path> swift test --filter CaptureAudioTests.testRealCAFAndM4AExportPreservesSharedOffsetsGapsAndDuration`.
Writer observed bytes/hash and backend compatibility; native generation command
success is Lead-provided evidence, not a writer-run Swift test. No user audio used.
Tests/backend/mediaFixture.ts additionally embeds FFmpeg-generated 0.1s silence.

## Verification and reproduction

Environment: Darwin arm64, Node v22.22.3, npm 10.9.8, TypeScript 5.9.3,
Vitest 5.0.1, convex-test 0.0.59 with transactionLimits and edge-runtime.
Run from /Users/tubakhuym/projects/lessmeet:

- `npm run typecheck:backend` — PASS (both backend and test projects).
- `npm run test:backend` — PASS, 51 tests in 4 files; includes all original 17.
- `git diff --check -- convex Tests/backend package.json package-lock.json` — PASS.
- `./node_modules/.bin/esbuild convex/http.ts --bundle --platform=browser --format=esm --outfile=/tmp/lessmeet-billing-http-20260923.js` — PASS, ~1.6MB bundle.
- `./node_modules/.bin/esbuild convex/jobs.ts --bundle --platform=browser --format=esm --outfile=/tmp/lessmeet-billing-jobs-20260923.js` — PASS, ~1.3MB bundle.

Esbuild is only an offline browser-runtime import check, not Convex deployment proof.
Generated api.d.ts was edited only to import/type-map the new billing module;
no codegen/deployment/network-auth command was run.
All RC/Gemini calls in tests use fixtures/mocks; none were live. No dashboard,
environment, store, production, repository commit, or user data mutation occurred.
Earlier local verification failed on a new test brace and TypeScript narrowing/test
ID typing; these were corrected before the passing final checks above.
Lead independently reports typecheck and the same 51 tests passed at 08:08:19.

Coverage includes anonymous/other-owner isolation, forged client fields, private-key
and restore-policy gates, RC HTTP/network/malformed/stale/404/201 responses,
sandbox/product/store/ownership restrictions, missing v1 evidence, cancellation,
expiry/refund, annual/month-end/leap-year windows, out-of-order refresh, TTL,
concurrent last-unit exhaustion, rollback on provider/result failure, scheduled
expiry, exact-once release, late replies/transcripts, rollover, preserved free usage,
repurchase anti-reset, server-derived duration, native compatibility and kill switch.
This does not establish real JWT/network behavior, live purchases/restores/refunds,
deployed scheduler timing, live model playback/transcription, or full security proof.

## Complete changed-path SHA-256 manifest

The manifest excludes only this handoff file itself; its final hash is in the
writer response. These paths plus this file are the complete owned candidate.

```text
2c138471218edff5741d3b63e45b9884aeeaea210b543cdf3f7ec8347f0406da  convex/billing.ts
c74f7160e57ce72aa645457bbe9aa5b8b24deb1005aad520f75007900dfee572  convex/billingPolicy.ts
5bffd502a1f16526bf66f7e186d7f83634838b160a648b70e28f0b2ccd19c564  convex/revenuecat.ts
0fe31ef1a4cee9fa34964869262c018144d2a9b27b71026f28973b868f468a94  convex/media.ts
9f16f0874131030625aeb344c09bf376733e4822e57899c729c3018b2f830fba  convex/http.ts
a686e9c5ad8b41addbc8ee4d77e5f1e311c67ed582e96bd409a5fddf5427b84c  convex/jobs.ts
4e5b703d0b86efae114dc0d68df4df28866f7eb7a84e4a300fe515d1b0010449  convex/recordings.ts
cb2e3e29bf02cdda6a67cc0a160ae367ea5f20a55d5206a976246b9278668a51  convex/schema.ts
681f9fee97ae78ae9d750bb0cdb6d9ca7ed81b0fa7998d61308fbfc082cc2c7f  convex/_generated/api.d.ts
b2401ee6ffadc95434779606d255bd05a510006dac8862a5dbe4b86d4b982a10  Tests/backend/billing.test.ts
037f80d8149b42f055543bfe2667b5321bfae094bc2c00dfc2cc92bbc9f3a205  Tests/backend/http.test.ts
f66b71a8cce993fb257a91bef5de78730762d49231a15b5d53237e295bfeb455  Tests/backend/mediaFixture.ts
b11cd012456954eb8f10e049101a3b5743690500ed5a3d48b75eb3402e5182db  Tests/backend/nativeMediaFixture.ts
f86948e57d10762f99a46b732ad26141a6ee4a06f682bbd275b58890310a56a9  package.json
ab92f7d2876e8923117d34a34842fcf0e66cdb6176a143b0bcdf7f856cae1460  package-lock.json
```
