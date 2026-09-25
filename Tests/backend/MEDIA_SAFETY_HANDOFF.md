# Lane A: bounded M4A admission hardening

Original accepted base: `b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605`.
Uncommitted deterministic snapshot, 2026-09-24. Lead decides acceptance.
Only owned changes: `convex/media.ts`, `Tests/backend/mediaSafety.test.ts`,
and this handoff. No commits, deployment, credentials, providers, personal audio,
native compilation or app launch. Concurrent changes in other scopes are untouched.
Writer relinquishes all lane A write ownership to Lead with this handoff.

## Outcome

MP4Box 2.4.1 `stszBox.parse` constructs `sample_sizes` before the existing
`buildSampleLists` override can reject constant-size/sample-count amplification.
The new preflight runs before `createFile`, not merely before sample-list building.
It checks explicit 32/64-bit box sizes, parent-relative boundaries, short/trailing
headers, recognized-container depth (maximum 16) and total visited boxes (4096).
It rejects fragmentation and compact sample-size tables before expansion, requires
variable-size backed `stsz`, and bounds fixed-width timing/chunk/offset/sync/edit
tables by their own payload and 1,000,000 entries. Table checks do not iterate their
declared counts. The existing sample-list guard and billing validation stay intact.

Conservative admission details: open-ended size-zero boxes are rejected; `stsd`
and `dref` require one declared entry; only one edit is allowed as before. The
native v0 `mp4a` layout is traversed, along with metadata and recognized generic
containers. Files outside this native-oriented subset may now receive 415.
Actual accepted native fixture (64-bit `mdat`) and FFmpeg fixture both remain
accepted under both MIME types, charging 2s and 1s respectively. Existing HTTP
upload and saved-job native billing tests pass. API, error 415, 18 MiB cap, codec
and billing policy are unchanged; exact-cap padded input is accepted, cap+1 denied.

## Bounded evidence and reproduction

Working directory `/Users/tubakhuym/projects/lessmeet`; Darwin arm64,
Node v22.22.3, npm 10.9.8, pinned Vitest 5.0.1 and edge-runtime.
Fixtures are deterministic mutations of existing synthetic audio or tiny generated
boxes. No random/unbounded fuzzing. Deep tree: 40 wrappers, 328 bytes. Wide list:
4097 empty boxes, 32,776 bytes. Sample-entry and metadata recursion use 20 wrappers.
Huge declared table counts use the 872-byte FFmpeg fixture, not huge arrays.
The only large inputs are the fixed 18 MiB and 18 MiB+1 cap cases.

Dangerous-case tests replace `createFile` with a throwing sentinel and assert it
was NEVER called. Thus red verification cannot trigger hostile parser allocation
or recursion. Compatibility, bounded malformed-offset/truncation, exact-cap and
erased-payload tests use the real parser (spy delegates to original implementation).

Commands and actual results:

- `npm run test:backend -- Tests/backend/mediaSafety.test.ts` on unchanged media
  baseline: initial harness run had 19 failures/3 passes, including an accidental
  returned mock interpreted as a cleanup callback. Corrected hook to return void.
- `npm run test:backend -- Tests/backend/mediaSafety.test.ts --reporter=dot`
  on unchanged media baseline, corrected initial 22 tests: **18 failed, 4 passed**.
  All 18 red failures were the parser-boundary assertion (parser called once).
  This demonstrates late admission, NOT measured exploit/OOM behavior.
- After hardening: `npm run test:backend -- Tests/backend/mediaSafety.test.ts
  Tests/backend/billing.test.ts`: **62 passed**, then typecheck passed.
- Added five boundary/recursion cases. Final `npm run test:backend`: **383 passed
  across 14 files**, reported suite duration 640ms (baseline 356 + 27 new).
- Final `npm run typecheck:backend`: **PASS**, backend and test TS projects.
- `/usr/bin/time -l npm run test:backend -- Tests/backend/mediaSafety.test.ts`:
  **27 passed**, Vitest 148ms; command 0.46s real, 0.40s user, 0.06s system;
  reported maximum resident set size 166,739,968 bytes, zero swaps. This is local
  test-runner measurement, not isolated parser or deployed Convex resource proof.
- `git diff --check -- convex/media.ts Tests/backend/mediaSafety.test.ts
  Tests/backend/MEDIA_SAFETY_HANDOFF.md`: **PASS**.

Tests are durable reproduction evidence; this file records observed red/green and
resource results. To reproduce the initial red boundary evidence safely, use the
base media implementation in a separate scratch checkout with the new tests and
pinned dependencies. Do not revert shared-checkout files; do not bypass the sentinel
on hostile inputs. The five later tests were not part of the recorded red run.

## Remaining risks / decision

The erased compressed payload test still returns 1 second: structurally consistent
metadata does not establish decodability, acoustic content or decoder-equivalent
duration. No full decode, re-encode, fuzz campaign, deployed load/CPU/memory limit,
long native export or exhaustive format compatibility was tested in lane A.
The preflight is deliberately not a complete ISO-BMFF firewall. Codec descriptors
(including nested ES descriptors), extension-box parsers and auxiliary variable
tables remain downstream MP4Box attack surface. Its depth/box bound applies to the
tree it recognizes, not every structure that MP4Box might parse. Existing expanded
sample limit (1,000,000) is not a proven safe deployed-runtime memory ceiling.

REOPEN_REQUEST for any claim of robust hostile-media/release decoding safety:
Lead must retain this gate or separately scope a resource-isolated decoder/service
and its runtime/cost/compatibility evidence. This bounded candidate is usable now
for earlier structural rejection; passing it does not satisfy that broader claim.
No new dependency or shared-interface change was made or assumed authorized.

## Snapshot SHA-256

Original `convex/media.ts`:
`0fe31ef1a4cee9fa34964869262c018144d2a9b27b71026f28973b868f468a94`.

```text
83c1c9ddd8dfb2f70b59cd89e408795ad8353ac256fb911a442a938ef584b720  convex/media.ts
b4f8eb0155cfbd3a3983b431f465c0939acc5678b5930cc54596b7fdd5b85e07  Tests/backend/mediaSafety.test.ts
```

This handoff's own SHA-256 is supplied in the final response, avoiding self-reference.
