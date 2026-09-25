# G: internal TestFlight tooling candidate

Outcome complete for local tooling; pending Lead acceptance. Original base:
`b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605`. Accepted dirty media/Clerk/native-test/docs
baseline preserved. No commit. Ownership of all assigned paths and exclusive Swift
compilation is relinquished to Lead at this handoff.

## Contract and usable downstream input

Explicit `testflight` mode uses isolated `dist/testflight` staging, explicit
version/build/approved complete ICNS artwork, and a distinct public approval record
binding every normalized supplied public configuration value. It permits the known
approved dev backend and public test Clerk key; RevenueCat retains `appl_` syntax.
No automatic environment-file fallback. Optional unpublished legal links need an
explicit internal acknowledgement. Store's publication/live Clerk/known-dev-backend
guards remain intact. Existing CLI defaults remain store for store-package.py.
Exact native `testflight` and `sandbox-dev` enable internal testing; variants do not.

Distribution profile/app certificate, exact team/bundle, every supported architecture
slice and separate installer policy reuse the existing store checks unchanged.
The existing policy checks every present arm64/x86_64 slice, not a new requirement
that both slices exist. Installer trust remains trusted status + selected unique
common name, not a new installer fingerprint check.

See TESTFLIGHT_INPUTS.md for non-passing approval template and commands. A mode
string does NOT enforce Apple's internal-only distribution. Manual internal group
selection and verification, upload authority, Apple processing, installation and
runtime checks are explicitly separate gates. No uploads are automated.

## Verification and failures

Environment: `/Users/tubakhuym/projects/lessmeet`, macOS 26.4 (25E246), arm64,
Python 3.9.6, Node 22.22.3, Apple Swift 6.3.3.

- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/packaging -q`:
  final PASS, 47 tests in 5.524s, exit 0. Apple signing/profile/icon/package commands
  mocked; real Node and PlistBuddy operate only on synthetic temporary fixtures.
  Covers beta inputs/record mixing/metadata tamper/legal/no fallback/isolation,
  original store guards, and per-arm64/x86_64 exact certificate extraction policy.
- `swift test --disable-automatic-resolution`: PASS, build 5.62s; 74 tests,
  one intentional opt-in long-capture skip, zero failures. Native configuration
  test checks exact beta spelling and rejects whitespace/case/other variants.
  This updates Swift debug build products, not existing dist app artifacts.
- `bash -n scripts/build-app.sh`: PASS, exit 0.
- `node --check scripts/configure-app.mjs`: PASS, exit 0.
- `plutil -lint Resources/Info.plist Resources/LessMeet.entitlements Resources/LessMeet.sandbox.entitlements`:
  PASS, all three OK.
- `git diff --check`: PASS, exit 0.
- Intentional RED: temporarily restored the original two-mode `MODES` declaration
  only, then ran `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/packaging -p test_testflight.py -k test_distribution_policy_identical_to_store -v`.
  Expected exit 1, one error: `signing.Invalid: Unknown signed packaging mode.`
  Restored the candidate declaration; final full 47-test GREEN includes this case.
  This is a bounded mutation regression, not a claim the whole suite ran on old HEAD.
- Initial packaging run passed 90 tests in 15.192s but included duplicate discovery
  from imported/inherited fixture classes. Removed duplicate discovery before final
  run; no failed implementation checks remain. One initial STATUS read used the
  wrong root path; corrected immediately to docs/STATUS.md before implementation.

## Unverified / still required

No actual signing/profile/Keychain access, certificate creation, app/installer
signing, install, launch, upload, provider request, dependency change or artwork
creation. Existing accepted app artifacts were not read, built, touched or promoted.
No UI, other native source, backend, legal-public assets, STATUS, README or shared
contract changes were made by this lane. Concurrent documentation changes belong
to their owners and are excluded from this candidate.

Actual approved icon bytes, approved public record/evidence, real signing inputs
and authority, Apple tool compatibility and server acceptance remain missing.
Approval references are assertions, not authenticated approvals or independently
verified backend/auth/billing/legal state. Mocked icon decoding does not prove
artwork quality. Internal-only Apple distribution is a manual delivery gate.
120-minute capture/upload/transcription, acoustic quality, OAuth, billing and
delivered-build runtime behavior are not established by these checks.

## Deterministic before/after SHA-256 snapshot

All owned pre-existing files are included (unchanged entries explicitly marked).
New paths had no before bytes. This handoff is also a new changed path; its own
hash is supplied separately in the final response to avoid recursive hashing.
The snapshot plus that handoff hash identifies the uncommitted candidate.

| Path | Before | After |
| --- | --- | --- |
| scripts/build-app.sh | 1cf5339bdb4993f0dc33f8f24731ba412c923b3b9b7d673ddb1698b06d3955d7 | 4f11b2ddc12e072e6816471c4078197d754482d2a0643d180fd252357fc5a6b7 |
| scripts/configure-app.mjs | 3fbf5d9b2e076e9b4e0b991dce2cd125b9909050143c70fe636737dde159066d | d3cae8df565900253ff03538c371567731f6ca7d162ba2a3ff08e2e12366c8b8 |
| scripts/packaging-signing.py | c03a885ae044a0d3141e2268a218317fbe3c7e2ad14d36bfb83978011da72118 | d2e606da6d3f034d012b55d71a64fcc3c3494348bea59c7e32106b182bf4ebbd |
| scripts/store-package.py | e70b1d0f97bcdf3c5d0e9688f9385e924d67690ada38150d5672d0d1ba66424c | 29bf74a529bcfdb02da5eafc83e6e6f13e960d4670ce1ae4b569fbc13a1bde0e |
| Sources/LessMeet/Configuration/BillingConfiguration.swift | 138b3dad9c592b1b1f2a27651c748eddd86edb5d1d4d85c716c60af05da6455c | 765decc7351397f8aaf2c3332dd62a4fd9379377b4aae7af986bbbde999d6989 |
| Tests/LessMeetTests/ConfigurationTests.swift | 2cfb38bf23189af32598bd94af2ef9f5812cb9a83ed1c074235ade17e63e81a0 | fd43fd33d1986f48b5ed630965ea651b74c03a3210dbca54a01900bd9a2ce092 |
| Tests/packaging/test_store_package.py | 97fcc91ccb0a484ab00a4ad1f805c2ac73a85b52c86365613c19e3c6b5407e0a | db8ebb6f195511bc0b9b677bbbe13292b7c8f64f8540362ca98a43f69241b593 |
| Tests/packaging/test_testflight.py | absent | 38661aa14ce09e2f5a4ec52b95d5d7aedce73d68bef3a2c6b10955a952f443c1 |
| Tests/packaging/TESTFLIGHT_INPUTS.md | absent | e4849f5f9d18158d3ac1f307c0de22c04dbb595ed190a6a937bb07e8939074d5 |
| Tests/packaging/HANDOFF.json | 869090909984cda4d2d24231796d7276c42b9cfa2dbba5a72462878785a16011 | unchanged |
| Tests/packaging/STORE_INPUTS.md | 687e33124163ae0aafb79e56fbd12b6d943d4fa6ed6845d9c96d1f5be65fc7e1 | unchanged |
| Tests/packaging/test_packaging.py | 364e925f52c0793059a64995aff1596dd8615dea1ddf6b067e82491ce05dc3c1 | unchanged |

Changed paths are the nine differing/new entries above plus this handoff (ten).
Lead owns candidate acceptance and all remaining delivery decisions.
