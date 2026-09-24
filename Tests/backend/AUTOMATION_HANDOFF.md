# Partial deletion automation candidate — 2026-09-23

Status: implementation handed to Lead for exact-candidate acceptance, not accepted
by the writer. Write ownership relinquished at handoff. No commit or deployment.

## Identity and actual base

- Original HEAD: `1a2685b5d56c04e13a724e611f9fafb16e7effe1`.
- Actual input is the accepted, dirty A working snapshot, NOT clean HEAD.
- Input manifest: `Tests/backend/DELETION_SHA256.txt`, SHA-256
  `df822f671f3607e28d6fd42ceb344ff3503a89fd9e7dfa4f1055b84bc957d31c`.
- At assignment entry, `git rev-parse HEAD`, `shasum -a 256` on that manifest,
  and `shasum -a 256 -c Tests/backend/DELETION_SHA256.txt` matched HEAD, manifest
  identity and all 25 entries. The old manifest itself remains unchanged; its
  modified implementation entries are now intentionally superseded by this candidate.
- `Tests/backend/AUTOMATION_SHA256.json` lists each changed path with before/after
  hashes, preserves the entire 34-file scoped pre-edit hash inventory and records
  the manifest's own exclusion from recursive hashing. Its final SHA-256 is supplied
  in the handoff response. A null before hash means this assignment added the file.
- Preexisting A/B/C and Lead changes were preserved. Git's clean-HEAD diff includes
  those earlier changes; use the new before/after manifest to identify this assignment.

## Delivered scope

Provider-neutral durable stages, default-off automation gate separate from intake,
immutable request/owner/target/config bindings, transactional claims/fences,
90-second leases, committed watchdogs, one-minute bounded cron recovery, eight-attempt
budget, persisted exponential/jittered retry and longer Retry-After handling.
Per-provider missing implementations terminate honestly as blocked exceptions.

Only one external adapter exists: exact-known Gemini File DELETE, no listing or
generation retry. It validates fixed origin/name/config, rejects redirects, bounds
fetch/body reads to 20 seconds and response JSON to 16 KiB, and accepts only `200 {}`
or structured resource `404 NOT_FOUND` under the verified-project binding invariant.
No provider API was called during this assignment; all adapter transports in tests
were synthetic mocks. No secret/config/account reads were performed.

Generation intent/response knowledge is now independently durable and awaited.
File absence cannot resolve interrupted generation, unknown uploads, old combined
ambiguity, active work or residual retention. Manual reconciliation fences stale
workers. Once automation starts, manual confirm/reconcile requires the freshly read
request automationRevision; old non-automation rows retain the existing interface.
No public HTTP/native deletion response shape changed.

Exactly one provider-neutral outbox status INTENT per request, updated atomically
with revision and queued/exceptions/scope-complete classification. It has no contact,
payload, sender, send operation or delivery transition. API acceptance is not delivery.
Human selected Resend Free during this assignment; Lead owns that follow-up after
acceptance. No Resend adapter, setup, sends or cost authority was added here.

`docs/BACKEND.md` contains current controls, exact internal entry points, stage/error
semantics, legacy manual compatibility, configuration assumptions and remaining
dependencies. Existing deletion evidence/guard flags remain authoritative and are
not set by successful file cleanup or elapsed time.

## Reproduction and observed verification

Environment: local `/Users/tubakhuym/projects/lessmeet`, Darwin arm64, Node v22.22.3,
existing pinned Convex 1.45.0 / convex-test 0.0.59 / Vitest 5.0.1 / TypeScript 5.9.3.
No dependency install or package change; no native build/tests performed.

Commands from project root:

1. `npm run typecheck:backend` — PASS (both backend and test TypeScript projects).
2. `npm run test:backend` — PASS, 8 files / 130 tests. Last independent full run:
   2026-09-23 23:48 local, 510ms reported by Vitest; no tests skipped.
3. `git diff --check -- convex Tests/backend docs/BACKEND.md` — no whitespace
   diagnostics. New/untracked candidate files were additionally checked with
   `git diff --no-index --check /dev/null <path>`; no whitespace diagnostics
   (no-index reports differences for added files).
4. The new manifest's after hashes are checked with Node crypto at handoff; all
   unchanged pre-edit scoped files are also checked against their baseline hashes.

The 130 tests include the existing 82-test baseline plus new adapter/scheduler and
durable-hook assertions. Tests use fake timers and mocked fetch, not live accounts,
credentials, audio or provider data. Scheduler fixtures exercise request → local
cleanup → paginated discovery → actual scheduled actions/watchdogs/retries, and
assert that scheduled functions did not fail. Cron registration is inspected in
addition to recovery execution. Concurrency/manual races include a suspended mocked
DELETE released after operator reconciliation. Other tests cover missing gates/key,
eight transient or abandoned claims, longer Retry-After, malformed/oversized bodies,
hanging fetch/body reads, project/owner/target mismatch, legacy rows, unknown
generation, 35-file discovery and one unique intent with no delivery fiction.

Red/green observed:

- Initial new adapter test failed module resolution before implementation (expected
  test-first red); adapter implementation made those tests pass.
- First scheduler suite: 13/14 passed; the lease-expiry/retry test left a retry
  unclaimed. Retry due times included fractional milliseconds; rounding up made
  the scheduler regression pass. A direct integer-delay assertion now covers that
  boundary. The first typecheck also rejected a test's use of the SDK's internal
  `crons.export()` method; the test now checks the public cron definition instead.
- Subsequent focused 14/14, full 128/128, and final full 130/130 runs passed after
  the added durable-generation-hook tests. Passing offline tests do not establish
  production timing or provider compatibility.

## Boundaries and usable downstream inputs

Ready for Lead inspection: worker/stage schema, independent Gemini-file adapter,
manual-fence interface and provider-neutral intent boundary, with synthetic tests.
All code is local and automation remains default-off. No deploy, env/key change,
real deletion, email send, audio access, paid test, install, commit or push occurred.

Not implemented/not verified:

- Executable Clerk, Apple, RevenueCat, residual-copy or email adapters. No success
  stubs. Apple token/original-client prerequisites and revocation ordering remain
  external dependencies. RC alias route is the planned separate v2 read-only
  inventory; credentials, SDK shutdown/startup and other-device quiescence are unmet.
- `GEMINI_DELETION_PROJECT_REF` is an operator-attested nonsecret routing reference,
  not automatic verification of a key's project. It must be bound correctly before
  activation and never silently repointed. Old work without a binding stays blocked.
- File deletion does not prove unknown generation completion or erase logs/backups.
  No guard purge, retention duration, completion SLA or legacy-orphan sweeping.
- Stage fences protect local state, not cancellation of an already submitted remote
  DELETE. Repeated exact-file ensure-absence is the bounded recovery operation.
- Discovery paused by disabling automation needs an exact-owner restart. Cron
  recovers existing due stages but does not adopt every old request. Failed legacy
  local-cleanup mutations still need the documented exact-owner operator retry.
- Native UI/playback/save/reopen and other-device behavior were outside this scope.
- Resend verified-contact/sender setup, relay-only fallback, idempotent payload/key
  freezing and delivery evidence belong to Lead's follow-up. The mutable intent
  cannot itself serve as a delivered event or a frozen send payload. Ambiguous sends
  must not be blindly retried outside the selected provider's deduplication window.

Lead decides acceptance of the exact manifest before dependent writable dispatch.
