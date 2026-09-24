# Frozen deletion notification candidate — 2026-09-24

Status: local/offline candidate handed to Lead for exact-snapshot review, not
accepted by the writer. All write ownership relinquished at handoff; no further
writes without a new assignment. No commit, push, install or deployment.

## Candidate identity and preserved input

- Project: `/Users/tubakhuym/projects/lessmeet` (resolved explicitly).
- Original HEAD: `1a2685b5d56c04e13a724e611f9fafb16e7effe1`.
- Actual base: accepted dirty A/B/C/automation state, not clean HEAD.
- Input `Tests/backend/AUTOMATION_SHA256.json` remained
  `2a80a8baa459e8382d64479d929af16069f9294924e2a054ee77e6c94b924271`.
- Full scoped pre-edit hashes were captured before any edit. The deterministic
  `Tests/backend/NOTIFICATION_SHA256.json` carries the complete before/after
  inventory (unchanged paths included), changed paths and base identity. Null before
  means newly added. The manifest excludes itself to avoid recursive hashing; its
  own digest is supplied in the handoff response. This handoff is hashed normally.
- All edits are within convex/**, Tests/backend/** and docs/BACKEND.md. Accepted
  automation artifacts and unrelated dirty native/legal/packaging work were not
  overwritten. Git's clean-HEAD diff includes older accepted edits; review against
  this manifest, not that whole diff.

## Outcome against the brief

Implemented the separate default-off immutable send snapshot coupled to accepted
intent, exact six completion flags, recipient/configuration/payload/key freezing,
transactional claims, eight-attempt budget, 90-second fenced leases/watchdogs,
bounded cron recovery and ambiguity-safe retries within a conservative 24-hour
first-claim window. Missing contact, changed owner/config/intent/completion,
relay-only contact and exhausted/expired retries never create completion/delivery
fiction. API success stores only provider acceptance and explicit pending delivery.

Added optional server-only exact-user read contact inventory. It reads instance ID
before exact subject with a pinned `Clerk-API-Version: 2026-05-12` REST contract,
not 2021 or SDK wrapper shapes. Issuer/instance config is checked, primary address
must be verified, errors are sanitized and minimal contact persistence is gated.
No JWT/client email, secondary fallback, sessions, OAuth-token reads or destructive
Clerk/Apple/RevenueCat adapter. Missing/relay contact never delays Apple revocation.

The existing native/public deletion routes and response fields are unchanged.
`deletionOutbox` remains the accepted mutable intent with its legacy
`delivery:not_configured` marker; separate notification inventory describes the
new send. The manually extended generated API type map adds internal functions
only; no CLI codegen/deployment was run.

Chose the brief's explicit-pending delivery alternative. There is deliberately no
webhook, delivered transition or delivery readback. A pending accepted send cannot
be automatically resent, even after 24 hours. No new dependency was needed.

## Verification environment and reproduction

Darwin arm64, Node v22.22.3, existing pinned Convex 1.45.0, convex-test 0.0.59,
Vitest 5.0.1 and TypeScript 5.9.3, edge-runtime fixtures. No real keys/configuration,
accounts, recordings or audio were read. All provider HTTP in tests was mocked;
fake timers/scheduler exercise the actual internal functions. Public official
documentation was fetched read-only, with no authenticated provider access.

Commands from project root, observed results:

1. `npm run typecheck:backend && npm run test:backend`: initial existing-suite run
   PASS, both TypeScript projects and 130 tests / 8 files, 487ms test duration.
2. Same command after new contact/send/race tests: PASS, 232 tests / 10 files,
   507ms. After bounded recovery additions: PASS, 235 tests / 10 files, 544ms.
3. Final `npm run typecheck:backend && npm run test:backend && git diff --check -- convex Tests/backend docs/BACKEND.md`:
   PASS, both TypeScript projects; 236 tests / 10 files, start 08:27:33 local,
   duration 550ms; no whitespace diagnostics. No skipped tests reported.
4. `git diff --no-index --check /dev/null <new-path>` on both new implementation
   files and both new test files: no stdout/stderr diagnostics, exit 1 for new-file
   differences (not a whitespace failure). Handoff/manifest receive the same check.
5. Node crypto SHA-256 inventory comparison verifies all manifest after hashes and
   unchanged scoped baseline paths before final handoff. `git rev-parse HEAD`
   still identifies the original base above. Manifest verification includes the
   complete actual scoped file set, not only tracked files.

No local typecheck/test failures were observed during this assignment. No red-first
test run is claimed. Initial Clerk deep-link documentation reads failed; research
used the official current version guide and raw published REST schema instead.
This was not a live API check. The inspected schema content digest and URLs are
recorded in docs/BACKEND.md.

The 106 added cases cover pinned REST and shape checks, exact owner/subject/issuer/
instance, verified-primary-only selection, missing gates/secrets, forbidden relay
and unsafe recipients, sanitized errors/oversized bodies/timeouts, actual intake
through capture/intent/manual completion/scheduled POST, all six independent flags,
pending stages/outstanding work, immutable contact/snapshot, concurrent claims,
configuration changes during contact lookup, lease loss/exhaustion, long queue delay,
boundary/time-window expiry, Retry-After, same-byte/key retries, bounded 35-row cron
recovery in two passes, stale results and manual completion withdrawal during HTTP.
Tests assert scheduled jobs did not fail; none establish deployed cron behavior.

## Usable inputs, unresolved proof and release gates

Lead can inspect the exact snapshot and rerun the commands above. Setup/internal
inventory and recovery entry points are documented in docs/BACKEND.md. No independent
acceptance is claimed. This is usable for integration review/offline tests only.

- Implementation remains off unless both email and contact-retention gates are
  explicitly true. Contact read has its own opt-in. No env or secret was provisioned.
  Sender is fixed to `notifications@lessmeet.2m0r.com`; actual sending-only key was
  never read. Retention/purge/backup/privacy/message approval remain Human release
  gates, not implicit approval from implementation or tests.
- Clerk GET instance checks credential routing, but issuer-to-instance association
  remains an operator attestation. Resend route reference must never be repointed;
  a sending-only credential cannot independently prove its team. Live wire
  compatibility and account-specific bindings are unverified.
- Contact capture does not block deletion. If it loses access to the identity or
  primary contact is missing/relay-only, notification remains an exception. No
  fallback address or delivery promise. A successfully frozen address cannot be
  replaced without new Lead design/scope; do not directly edit contact/send tables.
- Destructive Clerk/Apple/RevenueCat/residual adapters are still absent. Apple
  ambiguous revocation stays an operator exception. Existing provider flags are
  attested by the accepted workflow; no automatic provider completion was invented.
  Native all-device quiescence and durable RC absence are not established here.
- Delivery is explicitly pending forever in this candidate until a separately
  accepted authenticated evidence path exists. HTTP 200/provider ID is not delivery;
  email/server acceptance would not prove human reading either. No full end-to-end
  readiness, real send, deletion or user-visible delivery proof is claimed.
- Fences cannot cancel submitted HTTP. Completion withdrawn during a call yields
  an exception with any returned acceptance ID, not an unsend guarantee. Timeout
  and 24-hour checks bound client dispatch conservatively, not remote execution
  timing. Expired/exception rows have no automatic rearm or new-key path.
- Trusted internal admin/table access can defeat invariants. Backup restores or
  copied deployments must keep email disabled until preserved send state/timestamps
  and duplication risks are reviewed. No deletion of guards/send records or retention
  duration is authorized by this candidate.
- No native/UI/playback/save-reopen, real OAuth, real provider or deployed scheduler
  test was performed; B remains independent. All dependencies and live release
  decisions remain with Lead/Human.

Ownership is relinquished on the exact manifest handoff; Lead decides acceptance.
