# Internal TestFlight tooling inputs

Local tooling contract, not approval to sign or upload. Store defaults and its
production/publication gates remain unchanged. Existing STORE_INPUTS.md describes
the shared icon, version, app/profile/certificate and installer checks.

Use `bash scripts/build-app.sh testflight` only after separate build/sign authority.
It stages under `dist/testflight`, never promotes dev or sandbox-dev artifacts,
and produces an app only. Even `--preflight` reads signing metadata after public
input validation: do not run against real profiles without authority.

Public-only validation (no signing/profile access):

```
python3 scripts/store-package.py inputs --mode testflight
```

Explicit LESSMEET_VERSION, LESSMEET_BUILD, LESSMEET_ICON_ICNS and
LESSMEET_TESTFLIGHT_APPROVAL are required. Never set LESSMEET_STORE_APPROVAL at
the same time. No `.env.local` fallback. RevenueCat uses the existing public
`appl_` SDK key syntax (not a secret or a literal `publicappl_` prefix).
Clerk `pk_test_` and the approved development URL
`https://zany-octopus-315.convex.site` are allowed when exactly bound below.
Other syntactically valid public inputs also require their own explicit approval.

The distinct public JSON approval has this deliberately non-passing template:

```json
{
  "schema": 1,
  "mode": "testflight",
  "bundle": "com.lessmeet.app",
  "team": "63M98WD275",
  "version": null,
  "build": null,
  "public_configuration": {
    "CLERK_PUBLISHABLE_KEY": null,
    "CONVEX_SITE_URL": null,
    "REVENUECAT_PUBLIC_APPLE_KEY": null,
    "LESSMEET_PRIVACY_URL": "",
    "LESSMEET_TERMS_URL": ""
  },
  "icon_sha256": null,
  "approved_by": null,
  "approved_icon_evidence": null,
  "internal_audience": "internal-only",
  "backend_evidence": null,
  "auth_billing_evidence": null,
  "internal_unpublished_legal_acknowledgement": null,
  "distribution_control_acknowledgement": "manual-app-store-connect-internal-group-selection"
}
```

Evidence must reference actual reviewed backend/auth/billing alignment, artwork,
approver and intended internal testers, plus acknowledgement that unpublished
legal content is for internal testing only. Missing legal URLs are bound as empty
strings; supplied URLs must be HTTPS and bound exactly after the same whitespace
normalization used for bundling. All five public configuration fields are bound,
including supplied legal URLs. No drafts are published. Assertions are not
authenticated approvals or independent provider/legal evidence.

Temporary artwork is now available under `Resources/Artwork/`; its direction was
approved for internal TestFlight. Packaging must bind the exact validated ICNS bytes
and approval evidence, not merely a direction approval or this document's presence.
Version/build must be checked manually against App Store Connect. Distribution
signing policy is identical to store, including per-slice certificate/profile and
entitlement checks. It accepts the existing supported arm64/x86_64 slice policy;
it does not newly require a universal binary.

After separate authority and acceptance of the signed app:

```
python3 scripts/store-package.py package --mode testflight \
  --app /explicit/accepted/LessMeet.app \
  --output-dir /explicit/existing-parent/new-beta-installer \
  --installer-identity 'EXACT INSTALLER IDENTITY NAME OR SHA1'
```

This reads signing metadata and signs an installer; never run merely to validate
public inputs. Output must be new and separate from the source app. The validation
manifest includes mode, approval digest, version/build and package digest.
`stamp APP --mode testflight` is only for fresh unsigned build staging.
Omitting `--mode` preserves all original store CLI defaults.

## Separate manual delivery checks

### Preparing the missing signing inputs

Use the Apple account/team that owns `com.lessmeet.app` (team `63M98WD275`).
In Xcode Settings → Accounts, select that team and Manage Certificates. An
authorized Account Holder/Admin can create the appropriate app distribution
certificate and Mac Installer Distribution certificate. Existing valid team
certificates may instead be used with their matching private keys already present
on this Mac. Do not revoke another certificate just to resolve a setup problem.
Developer ID is for distribution outside the Mac App Store, not this workflow.

In the developer portal, create/download a Mac App Store Connect provisioning
profile for the exact app identifier and selected distribution certificate. Use
the current capability configuration; an old profile may predate capability changes.
Keep the profile at an explicit local path for packaging. Installing a certificate
without its matching private key does not supply a signing identity. Do not send
private keys, passwords, Apple login details or recovery codes through chat or Git.

Tell Lead only that setup is ready and the profile's local path; subsequent checks
validate team, bundle, expiry, certificate membership and entitlements. Creating
signing assets does not establish a successful build or Apple processing result.

Official guidance checked 2026-09-25:
[certificate types](https://developer.apple.com/help/account/certificates/certificates-overview),
[Xcode certificate management](https://help.apple.com/xcode/mac/current/en.lproj/dev154b28f09.html),
[App Store profiles](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile).

No command uploads, installs, launches or manages tester groups. The mode string
and approval record do NOT enforce Apple's internal-only distribution.

Before any separately authorized upload, the operator must verify the App Store
Connect app/team/permissions, unique version/build, approved icon and public
configuration, matching distribution profile/app certificate and separate installer
identity. After upload, inspect processing results and any required compliance or
beta metadata. Explicitly select and verify only the intended internal testing
group/users; do not enable external testing or public distribution. Record those
manual checks independently. If the available Apple workflow cannot meet the
internal-only requirement, stop and return the decision to Lead/Human.

Actual installation, capture permissions, OAuth, backend/billing behavior and
120-minute upload/transcription must be tested separately on the delivered build.
Mocked tooling tests cannot establish these outcomes or Apple acceptance.
