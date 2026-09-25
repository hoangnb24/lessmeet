# Clerk transport-only candidate — 2026-09-24

Pending Lead acceptance. No commit, push, deployment, provisioning or live HTTP.
Write ownership of all three assigned paths is relinquished with final handoff.

## Identity and scope

Project: `/Users/tubakhuym/projects/lessmeet`.
Original and current HEAD: `b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605`.
Three newly created files; none existed at dispatch (the initial `ls` returned 1
with three expected missing-path diagnostics). Full final SHA-256 values are in
the final handoff response, including this document; no self-referential hash.

- `convex/clerkDeletionTransport.ts`
- `Tests/backend/clerkDeletionTransport.test.ts`
- `Tests/backend/CLERK_TRANSPORT_HANDOFF.md`

No other writes. Shared checkout already contained Lead documentation/package,
A media and B native-test changes. Full-suite results below include their current
shared snapshot, not an assertion that those unrelated changes are accepted.
Existing worker/adapter/preflight/schema/generated API remain untouched by C.

## Usable contract

`clerkDeletionTransport(input)` accepts `verifyInstance`, `getUser`, `getSession`,
`deleteUser`, or `revokeSession`. It requires injected fetch and credential; it has
no default global fetch, environment read, handler registration or persistence.
Its only runtime import is the existing pinned `CLERK_API_VERSION` constant.
Omitted/false enable blocks before any network. Binding snapshots are frozen
before awaiting: issuer, instance, exact owner/subject, immutable config revision.
Syntax and owner equality follow frozen binding conventions. Caller must attest
the issuer/instance association and must never repoint a configuration revision;
GET instance alone cannot independently prove the issuer association.

Each operation first verifies the exact instance. Target reads verify exact user
or session identity; session read also verifies owning subject and known status.
Destructive calls first read the exact target, require an Apple-disposition
revision, and await a trusted authorization callback immediately before submission.
The callback receives the frozen target/binding/revision, never the credential.
Future worker MUST recheck enable gates, request/owner/config, lease/fence and
durable Apple evidence there. A revision string is not evidence validation by this
module. No atomicity with remote submission or cancellation guarantee is claimed.

Results are sanitized observations, never provider completion:

- `observed`: exact instance/user/session read matched.
- `acknowledgement`: DELETE returned valid acknowledgement; later worker GET
  observation is required, deliberately not automatically performed here.
- `absence_observed`: exact target structured resource-not-found response;
  session absence is explicitly NOT successful revocation. Instance 404 is blocked.
- `session_revoked`: exact owned session returned status revoked after POST.
- `unknown`: transport failure/deadline/transient provider response.
- `blocked`: prerequisites, identity, shape or provider rejection prevent progress.
  After submission this does NOT prove no side effect; malformed acknowledgements
  and contradictory identities require worker/operator reconciliation, not retries.

DeletedObject.object remains a string (no invented user enum); optional id may be
absent, but a contradictory/null id blocks. Deleted must be true. The parser checks
security-relevant fields rather than pretending to validate every optional field
in the whole provider schema. Structured404 policy requires exactly one error with
code resource_not_found; mixed/unknown error shapes intentionally fail closed.
No ban, subscription cancellation, all-session completeness, global quiescence,
Apple revocation, permanent absence, notification delivery or erasure claim.

Network is fixed to api.clerk.com/v1 with pinned 2026-05-12 header and redirects
set to error. Every flow has one 20-second deadline, including auth callback and
stream reads; decoded input capped at 64 KiB. No retries/backoff or SDK dependency.
Aborts cancel readers and guard every subsequent submission. Injected fetch must
honor RequestInit and must not add retries or log credentials. A malicious transport
or an already-submitted remote request cannot be undone by this module. Late fetch
responses are cancelled and cannot replace the settled timeout or cause more calls.

## Verification and reproduction

Darwin arm64, Node v22.22.3; existing TypeScript 5.9.3 / Vitest 5.0.1 and backend
edge-runtime configuration. No installation or native compilation. All network
fixtures use injected mocks; global fetch is trapped and asserted unused after
each test. Synthetic credentials only; no keys, env files or account access.

From project root, observed:

1. `npm run test:backend -- Tests/backend/clerkDeletionTransport.test.ts`:
   first pass 71/71 (23:02:07 local).
2. `npm run typecheck:backend`: both TypeScript projects passed.
3. After additional stream/deadline/shape boundary fixtures, same scoped command:
   84/84 passed (23:02:52 local, 133ms total).
4. `npm run typecheck:backend`: both projects passed again.
5. `npm run test:backend`: 467/467, 15 files passed (23:02:54 local, 659ms total).
   Includes A's shared media tests. No shared failures observed or repaired.
6. `git diff --check -- convex/clerkDeletionTransport.ts Tests/backend/clerkDeletionTransport.test.ts`
   produced no diagnostics. Because these are new untracked files, additionally
   ran `git diff --no-index --check /dev/null <path>` for both: no diagnostics.
   Final document receives that check as well. Final SHA-256 via `shasum -a 256`.

No test/typecheck failures occurred. The expected initial missing-path check is
not a verification failure. No live provider compatibility or account configuration
was tested; previous baseline tests are not substituted for these actual runs.

Coverage: five exact wire paths/methods, pinned headers and body omission;
disabled/invalid binding/no transport/no secret/no Apple prerequisite zero calls;
instance/subject/session mismatch; exact session ownership before POST; optional
and contradictory DELETE IDs; unconstrained schema object string; typed/generic/
mixed/instance404; status and malformed/UTF-8/missing/throwing bodies; streamed
size cap and exact boundary; auth withdrawal/error/nonboolean; immutable callback
context; hanging fetch/body/callback, late read/mutation results, cumulative deadline,
reader cancellation; sanitized rejection and no global fetch or automatic retry.

## Remaining integration boundaries

No existing automation calls this module; Clerk remains adapter_unimplemented.
Durable state, fresh execution inventory, legacy-stage adoption, fence integration,
Apple original-client proof, observe-before-retry, aggregate session/user completion,
retention of added evidence and any activation remain Lead-owned deferred work.
No state schema, exported Convex function, public endpoint or feature gate changed.
Notification delivery stays unknown. Existing 30-day inventory and 90-day completed
ledger policies are unchanged. Transport observations alone cannot satisfy release
readiness or the complete account-deletion process.

Source contract: https://raw.githubusercontent.com/clerk/openapi-specs/main/bapi/2026-05-12.yml
(prior accepted public inspection SHA-256
`4c42713b9fc0d68a5f5263286fb6c87bab6320d74be261acb8a77bc1ad26d2bd`).
No additional public/provider HTTP was performed during this implementation lane.
