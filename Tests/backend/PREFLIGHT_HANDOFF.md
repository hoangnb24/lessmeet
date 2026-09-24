# Read-only provider preflight candidate — 2026-09-24

Status: local/offline candidate for Lead acceptance. Writer does not accept its own
candidate. All writes relinquished at final manifest handoff; no commit/deployment.

## Identity and input preservation

- Explicit project: `/Users/tubakhuym/projects/lessmeet`.
- Original HEAD: `1a2685b5d56c04e13a724e611f9fafb16e7effe1`.
- Actual base: accepted dirty notification/native/automation work, not clean HEAD.
- Before edits, Node SHA-256 verification matched notification manifest
  `b99be58b8f620efd1a3cd7ab560210c2aceba5f8c358d600b173b1f298f5c808`
  and all 47 entries; native manifest
  `ff38147b3fc59e5592c7aa32095e25003aea6d9c7091c8b3709472887b1a2446`
  and all 38 entries. All 48 actual scoped input files were captured before edits.
- `PREFLIGHT_SHA256.json` contains the complete scoped before/after hashes,
  unchanged paths included, changed paths and input identities. Null before means
  new. Only the manifest excludes itself; its SHA is supplied in the final response.
  This handoff is hashed normally. It is the deterministic candidate identity.
- No writes outside convex/**, Tests/backend/**, docs/BACKEND.md. No changes to
  accepted contact/notification implementation, sender snapshots, public/native
  endpoints, dependencies, native/legal/packaging or STATUS. Native 38 hashes were
  independently rechecked unchanged at handoff preparation. Git's clean-HEAD diff
  includes prior accepted changes; use this manifest to isolate this assignment.

## Outcome and decisions

Implemented separately default-off Clerk/RC preflight attached to the accepted
worker start, plus exact-owner explicit adoption/recovery. It reuses accepted
Clerk `contactBinding`, API version and credential routing; it does not duplicate
or replace recipient capture. The official 2026-05-12 schema was fetched publicly
and its SHA matches A's recorded
`4c42713b9fc0d68a5f5263286fb6c87bab6320d74be261acb8a77bc1ad26d2bd`.
That version's Session.List is an array, not SDK `{data,totalCount}`. Fixtures and
parser reject the wrapper and earlier/unbound shapes.

Internal `deletionPreflights` rows freeze request/owner/subject/request timestamp,
canonical config revision/issuer/instance/wire version/project and per-claim
fences. One row per provider/request, no reset/retarget/rearm. Clerk instance is
checked before each user/session page; sessions are unfiltered (no shrinking
active-only list). RC uses separate project-attested v2 customer/alias GETs, never
v1 GET, with strict continuation validation/reconstruction. Payload extraction
keeps only minimum identifiers/statuses; full responses/errors/metadata/emails and
tokens are not persisted. Existing sender/contact/outbox behavior is unchanged.

Each action commits one page, limited to 8 list pages/256 accumulated items,
64 total claims and 8 attempts per phase/page, 90-second leases and 20-second
transport/body timeout, 64-KiB JSON. Accepted retry-delay implementation is reused;
provider Retry-After/backoff_ms can extend it. Transactional watchdogs, persisted
wakeups, fences and at-most-16-per-state cron recovery bound interrupted work.
Repeated/overlapping cursors/IDs, identity/config drift, unexpected shapes and
page-budget exhaustion remain blocked with prior partial observations preserved.

There are **zero destructive provider operations** in this lane: no OAuth token
reads, Clerk session revoke/ban/delete, Apple endpoint, RC delete or v1 GET. No
provider completion flags, manual evidence or accepted provider stages are written.
`observed`/`inventoryComplete` mean bounded traversal ended, not provider deletion
or authorization to delete. Linked Apple is always provenance-blocked; no current
Apple link does not establish historical applicability. Every RC alias beyond the
exact subject is unexplained ownership, including anonymous aliases. The lane
does not supply an ownership/provenance setter or fabricate missing evidence.

## Verification environment and commands

Darwin arm64, Node v22.22.3; existing Convex 1.45.0, convex-test 0.0.59,
Vitest 5.0.1, TypeScript 5.9.3; edge-runtime synthetic fixtures. No installation,
credential/env provisioning or native build. All provider test transport mocked;
no live account/API, real sends, audio/recordings, paid APIs or data deletion.
Public documentation/schema fetches only, no authenticated provider access.

From project root:

1. `npm run typecheck:backend && npm run test:backend` before edits: PASS,
   236 tests / 10 files, 08:33:46 local, 558ms.
2. Same after adapter fixtures: PASS, 307 / 11 files, 08:41:17, 585ms.
3. First durable-fixture run: typecheck PASS, tests 345 pass / 1 fail. The delayed
   HTTP test assumed 30 microtask turns sufficed to enter the mocked transport;
   its release callback was still undefined. Replaced that fixture's loop with
   an explicit transport-entry promise, not a production workaround.
4. Same command after fixture correction: PASS, 346 / 12 files, 08:45:26, 594ms.
5. Additional watchdog/cron-fallback/duplicate-alias tests: PASS, 349 / 12 files.
6. Final code verification:
   `npm run typecheck:backend && npm run test:backend && git diff --check -- convex Tests/backend docs/BACKEND.md`
   PASS both TypeScript projects, 349 tests / 12 files, 08:48:18 local, 582ms;
   zero skipped tests/whitespace diagnostics. This is all 236 baseline cases plus
   113 new cases. The cron fallback test asserts its synthetic watchdog was
   actually cancelled before exercising recovery.
7. `git diff --no-index --check /dev/null <path>` for the five new implementation/
   test files: no diagnostics (exit 1 denotes an added file). Final handoff and
   manifest receive the same check. Node crypto checks all final manifest hashes,
   unchanged baseline entries and the exact scoped path set before handoff.
8. `uname -sm`, `node --version`, `git rev-parse HEAD`: environment above and
   unchanged original HEAD. Node crypto verifies all 38 native hashes unchanged.

Coverage includes actual deletion intake → accepted automation → scheduled
preflight, exact owner isolation, all gates, wrong instance/project/issuer/subject,
wire versions, stripped payloads, minimum identities, malicious continuation
routes/queries, pagination termination and caps, duplicate sessions/aliases,
structured/generic/mid-pagination 404, missing keys, HTTP error/backoff/timeout,
immutable once-only starts, concurrent claims, stale/expired results, config drift
between/during pages, retry budgets, abandoned leases, disabled/re-enabled queues,
and 35 due rows recovered in bounded 16/16/3 passes. Every captured provider call
is asserted GET on an allowlisted non-token/noncreating route. Existing request,
contact, intent and frozen send rows are explicitly compared unchanged. Scheduled
fixture jobs are inspected for failure; passing tests do not prove deployed cron.

## Usable inputs and limits

`docs/BACKEND.md` documents gate/config contracts, allowed routes, wire shapes,
internal `start`, `inventory`, recovery and worker plumbing. No setup is performed
or authorized. Existing automation start is the normal integration path; internal
start adopts only already initialized exact-owner requests. No terminal-row rearm
or inventory refresh is included. A future lane must explicitly design new
revision/refresh/provenance/alias-ownership handling, not patch frozen rows.

Unverified: live wire compatibility and credentials/account/project attestations,
deployed scheduler behavior, historical/atomic inventory completeness, all-device
SDK quiescence, permanent RC non-recreation, UI/native lifecycle and provider
activation. Clerk removes old/inactive sessions from its list, and remote state
can change between pages even without detectable duplicate IDs. Traversal
completion is not stronger proof. 404 is unavailable inventory, never proof that
Apple/unknown aliases are resolved. External writes remain unimplemented.

Preserved decisions: ambiguous Apple revocation without a recovered bound token
is an operator exception, no raw-token store; Clerk deletion requires durable
Apple disposition. No ban added. RC point-in-time absence is not all-device
quiescence or permanent removal. No subscription cancellation, logs/backups
erasure, retention duration, SLA, notification delivery or production readiness
claim. Identifier retention/provider activation remain Human gates; all preflight
gates are off unless explicitly enabled. Trusted internal/admin DB edits can break
invariants; never forge observations or repoint configuration references.

All writer ownership is relinquished with the final exact-manifest handoff. Lead
owns technical acceptance and subsequent integration/activation sequencing.
