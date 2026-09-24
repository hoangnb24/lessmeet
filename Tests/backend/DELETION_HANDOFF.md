# Account-deletion candidate evidence

Offline snapshot over base `1a2685b5d56c04e13a724e611f9fafb16e7effe1`.
No commit, deployment, provider mutation, private key/token inspection, paid request,
audio upload, signing, artifact promotion or policy/website edit was performed.
This is candidate evidence, not a second project-status tracker. Lead owns acceptance.
The adjacent `DELETION_SHA256.txt` lists every changed candidate path and SHA-256,
including this report; the handoff message supplies the manifest's own SHA-256.
Unrelated B/C/Lead changes in the shared tree are excluded and preserved.

## Outcome and interface

Native Account settings now offer authenticated deletion initiation, explicit
confirmation and status refresh. Confirmation/token/response work is user- and
session-fenced. Local files and saved results are preserved; cached cloud/purchase
controls lock on a possibly accepted request. Apple subscription cancellation is
separate, linked, and never a condition of deletion. No purchase/restore transfer,
price, quota, entitlement or billing-policy change is made.

Backend HTTP `GET /account/deletion` and confirmed POST derive the issuer-bound
owner exclusively from auth. A durable tombstone prevents new work and late
recording/chat/billing writes. Bounded transactional batches remove known recording
blobs, rows, reservations, quota buckets and billing rows; retries are idempotent.
Storage/provider calls have durable admission before nontransactional effects;
ambiguous or interrupted work stays pending. Known Gemini file IDs are recorded
before generation, and file deletion alone cannot resolve an unknown generation.

Manual provider fulfillment is intentional: separate Clerk, RevenueCat, Apple
sign-in revocation, Gemini and residual-copy progress, with private proof references.
No provider-success stub is used. Internal exact-owner inventory/retry/reconciliation/
confirmation helpers and their operator proof prerequisites are documented in
`docs/BACKEND.md`. Verified work is removed; unresolved work and the guard remain.
Generated API type declarations were extended locally; no live codegen/deploy ran.

## Reproduction and actual results

Working directory: `/Users/tubakhuym/projects/lessmeet`.
Environment observed: macOS 26.4 (25E246), arm64; Apple Swift 6.3.3
(`swiftlang-6.3.3.1.3`), Node v22.22.3, npm 10.9.8. Existing pinned dependencies
and the default Swift build cache were used; no dependency manifests were edited.

| Command | Actual result |
| --- | --- |
| `npm run typecheck:backend` | PASS; both Convex and backend-test TypeScript projects, final run 2026-09-23 23:07 local. |
| `npm run test:backend` | PASS; 82 tests in 6 files, final run 2026-09-23 23:07 local. Includes 17 new deletion tests and 3 additional Gemini adapter tests. |
| `swift test` | PASS; 66 tests, final run 2026-09-23 23:05 local. Includes 8 deletion model/local preservation tests and 2 transport tests. Latest Swift changes are included. |
| `git diff --check -- convex Sources/LessMeet Tests/backend Tests/LessMeetTests docs/BACKEND.md` | PASS; scoped whitespace validation. |
| `git rev-parse HEAD` | Exact original base above. |
| `sw_vers`, `swift --version`, `node --version`, `npm --version` | Environment above. |

Backend tests use `convex-test` in-memory storage/DB with transaction limits,
synthetic identities/media, fake timers and network-denying or explicit mocked
provider transports. Native transport uses URLProtocol fixtures; local preservation
uses generated temporary synthetic files, not existing recordings.

Evidence sources:

- `Tests/backend/deletion.test.ts`: auth/confirmation and default-off intake;
  issuer isolation, repeat requests; batch size and reservation settlement;
  missing storage/buckets, corrupt ownership fail-closed and rollback/retry;
  upload-body and admitted-storage races; in-flight RevenueCat/chat/Gemini;
  stale writes rejected, provider failures/unknown acknowledgments stay pending;
  retained-guard synthetic restore suppression; exact-owner operator validation;
  Apple proof independent of Clerk; successful work drains, interrupted generation
  stays pending even after File DELETE.
- `Tests/backend/gemini.test.ts`: real adapter construction against mocked SDK/
  HTTP, ledger-before-generation, post-upload guard, cleanup warnings and ledger
  failure preventing generation. No real provider call.
- `Tests/backend/deletionRehearsal.test.ts`: historical raw-row deletion hazards
  retained. These deliberately bypass the new request workflow and still show
  that ad-hoc row deletion is unsafe; they are not readiness failures of the new API.
- `Tests/LessMeetTests/AccountDeletionTests.swift` and `CloudClientTests.swift`:
  intentional confirmation, session/account switching before send and on late
  response, double submission, ambiguity/no retry, exact bearer-only transport,
  malformed completion rejection and unchanged synthetic local audio/results.

Earlier failures, now resolved:

- First backend regression run: 60/62 passed; two old warning-text expectations
  still expected the prior expiry wording. Updated expectations to honest pending
  cleanup wording; subsequent runs pass.
- First new-fixture run: typecheck caught a query invoked as a mutation, and
  convex-test rejected a Blob returned outside its fixture boundary. Corrected the
  tests; these were fixture errors, not deletion acceptance evidence.
- Missing-blob regression: 77/78 passed; cleanup threw `Delete on non-existent doc`.
  Fixed with transactional `_storage` metadata existence checks. Final regression
  verifies missing blobs and repeated cleanup, rather than suppressing the failure.

## Ready downstream inputs and limits

Ready for Lead's source integration and independent review: native/backend interface,
synthetic tests, guarded bounded cleanup and exact-owner operator procedure. Code
can be exercised offline with the commands above. Native entry is Account settings
→ Delete Account; a real deployment must first satisfy the prerequisites below.
No rendered deletion dialog, actual click sequence, live OAuth/session revocation,
real storage/provider cleanup, real backup restore, release artifact or store
compliance is established by these tests. Existing local-cache preservation is not
proof of live playback or hardware capture quality.

Requests are default-off (`ACCOUNT_DELETION_ENABLED` must be exactly `true` for
new intake). The flag does not disable guards or cleanup and is not permission to
retain identity. Cloud operations create work admissions even when intake is off;
deployment therefore also needs Human-approved ledger retention/access. No switch
was changed. No retention duration, automatic tombstone purge, fulfillment SLA or
completion-notification channel was invented. Human must decide minimum ledger
fields/purpose/duration/access, restore suppression, completion-time disclosure and
notification/operational staffing before activation/public release.

Proposed minimum tombstone: issuer-bound owner, provider-targeting subject, timestamps,
progress and opaque proof references; unresolved operations additionally retain
kind/time, known exact storage/file IDs and uncertainty flags. No emails/tokens/
content are duplicated. Removing the guard without a replacement permits data/quota
resurrection. Current non-purging code is a technical safety hold, not approved
indefinite identity retention.

Manual verification is a real trust boundary: `confirm` and `reconcileWork` record
the authorized operator's proof, not automated provider proof. Do not attest stopped
work until it has actually stopped. The API cannot prevent already-admitted network
calls from reaching a provider; it prevents late persistence and completion while
unknown work remains. Google processing/log copies, legacy untracked files/storage
orphans, independent Apple records, support records and backups remain explicit
limits. Surviving JWTs can access their own deletion status only; their signatures
are not revoked here. Restore without replaying the retained guard defeats deletion.
Provider SDK calls on other devices and old-deployment actions need live operational
quiescence checks before provider completion/intake activation.

Accepted read-only B inputs were SHA-256 verified before use:

- `docs/legal/PROVIDER_DISCLOSURES.md`:
  `2cc395266e0fa4357d46286106ba3264904d880b959d004f1ce63a55890eb15a`.
- `docs/legal/DELETION_RUNBOOK.md`:
  `f7f18a29dd7b3f4b146c08bd00acce11be9fbd753e2fa3d74dc4b815727d6bbb`.

Official Apple/Google/Convex/Clerk/RevenueCat sources used are linked in
`docs/BACKEND.md`; account settings were not inspected. Apple token revocation is
explicitly separate, pending until verified. Legal drafts, publication and release
decisions remain outside this candidate. A relinquishes all writes at handoff.
