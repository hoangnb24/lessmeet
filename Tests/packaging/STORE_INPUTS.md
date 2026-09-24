# Offline Store packaging contract

This is tool/test documentation, not release approval or a second status tracker.
The existing `build-app.sh [dev|sandbox-dev|store] [--preflight]` CLI is unchanged.
Dev and sandbox-dev inputs, output paths, legal-link exception and entitlements
are unchanged. No Swift configuration property, callback or billing product changes.

## Gates and inputs

Store builds now require explicit `LESSMEET_VERSION` (three numeric components),
`LESSMEET_BUILD` (positive major, at most 4 digits; optional minor/patch at most
2 digits each), `LESSMEET_ICON_ICNS`, and `LESSMEET_STORE_APPROVAL`. This build
format is a conservative local subset of Apple's numeric build-string format.
The operator must check App Store Connect build-number uniqueness/incrementing;
the offline tool cannot establish that. Existing signing and public environment
variables remain required. Store mode never reads `.env.local`.

`LESSMEET_STORE_APPROVAL` names a public JSON record, supplied only after Lead/Human
approval of actual production provisioning, legal publication and artwork. Its
schema is below. **Null entries are intentional blockers, not example evidence.**
Do not copy synthetic test approval strings into a real release record.

```json
{
  "schema": 1,
  "bundle": "com.lessmeet.app",
  "team": "63M98WD275",
  "version": null,
  "build": null,
  "public_configuration": {
    "CLERK_PUBLISHABLE_KEY": null,
    "CONVEX_SITE_URL": null,
    "REVENUECAT_PUBLIC_APPLE_KEY": null,
    "LESSMEET_PRIVACY_URL": null,
    "LESSMEET_TERMS_URL": null
  },
  "icon_sha256": null,
  "approved_by": null,
  "production_backend_evidence": null,
  "production_auth_billing_evidence": null,
  "published_legal_evidence": null,
  "approved_icon_evidence": null
}
```

Evidence fields are nonempty references to reviewed evidence, not credentials,
tokens, screenshots containing private data or a boolean saying "production".
Bind all public configuration bytes, version/build and approved ICNS hash exactly.
Backend evidence must establish the deployment is production in the correct
project; its Convex hostname is not sufficient. Auth/billing evidence must cover
production Clerk and RevenueCat app/backend alignment. Legal evidence must cover
the published approved URLs. The tool checks this record's structure/bindings;
it cannot authenticate approval or independently verify provider settings, URL
availability, policy adequacy or branding. Human/Lead review remains mandatory.

`pk_test_` Clerk and the known `zany-octopus-315` development backend are rejected
even if somebody puts them in an approval record. A RevenueCat `appl_` prefix
is public SDK-key syntax, not proof of production provider configuration.

Prefix policy follows [Clerk's current environment-variable documentation](https://clerk.com/docs/guides/development/clerk-environment-variables).
[Convex's deployment URL documentation](https://docs.convex.dev/client/react/deployment-urls)
distinguishes development and production deployments and points to deployment
settings for their URLs; our requirement for reviewed deployment provenance is
a local fail-closed policy, not an inference from hostname shape.

An approved `.icns` file must have all 10 standard/Retina representations for
16, 32, 128, 256 and 512 points, including 512@2x (1024 pixels). `iconutil` decodes
a private byte snapshot; `sips` checks each representation's pixel dimensions.
This is a deliberately complete-set local policy, not a claim Apple rejects
every incomplete set. The tool does not generate, resize, brand or approve art.
No icon supplied by this lane is release artwork. Missing approved icon stays
a release gate. The selected bytes are copied to `Contents/Resources/LessMeet.icns`
and version/build/icon metadata is stamped before signing the fresh store bundle.

## Commands and authority

Public-input validation, safe without signing authority:

```sh
python3 scripts/store-package.py inputs
```

Unlike this command, existing `build-app.sh store --preflight` subsequently reads
local signing metadata/profile. Do not run it against real inputs without authority.
`stamp APP` is an internal hook for fresh unsigned store staging; it refuses a
bundle containing `_CodeSignature` and is not a way to retrofit a signed artifact.

After accepted source, real public inputs, and separately authorized app build/sign:

```sh
python3 scripts/store-package.py package \
  --app /explicit/accepted/LessMeet.app \
  --output-dir /explicit/existing-parent/new-installer-candidate \
  --installer-identity 'EXACT INSTALLER IDENTITY NAME OR SHA1'
```

This command **accesses signing metadata and signs an installer**; it was NOT run
on real inputs during this assignment. There is no upload/install/launch subcommand.
It does not compile Swift or re-sign the app. It copies to a private staging
directory, validates store metadata/config/icon/resources, strict signature on
all architectures with an Apple anchor/team/bundle requirement, embedded profile,
signature-leaf profile membership and minimal sandbox entitlements. It rejects
symlinks (current app has none; new frameworks need a packaging-policy review).
Installer identities must be unambiguous, valid, this team's Mac Installer
Distribution type (`3rd Party Mac Developer Installer` legacy common name accepted),
not Apple Development/Apple Distribution/Developer ID Installer. Duplicate common
names are rejected even when selected by hash because productbuild uses a name.

`productbuild --component APP /Applications --sign IDENTITY PKG` produces the
candidate. `pkgutil --check-signature` must report a trusted matching installer
leaf name. The exact input snapshot is rechecked afterward. A new output directory
and exclusive final file creation avoid replacing existing artifacts. Tool failure
leaves at most a new isolated output directory, not a promoted dist artifact.
`validation.json` records version/build, normalized approval hash and package hash.
No accepted dev/sandbox-dev app is read, changed or promoted automatically.

Limitations: actual Apple output parsing and profile/signature compatibility are
mock-verified only here. Each detected arm64/x86_64 slice has its entitlements and
signature certificate checked; other architectures fail closed. The pkg payload is produced by Apple's component mode,
not independently unpacked/reinstalled in this lane. Trust checks may consult OS
trust services when a real operator runs them; no network-offline guarantee is
made for future Apple tool executions. Offline refers to this lane's mock proof.

## Official Apple references, checked 2026-09-23

- [Packaging Mac software](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution): Mac App Store uses an installer package; the simple component productbuild path uses a separate installer identity. Do not filter installer identities with `security ... -p codesigning`.
- [Certificate types](https://developer.apple.com/help/account/certificates/certificates-overview): Apple/Mac App Distribution signs apps; Mac Installer Distribution signs Store installers; Developer ID Installer is for outside the Store.
- [Mac App Store Connect profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile): explicit App ID/app record, matching distribution profile and certificate.
- [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/): Xcode, Transporter and altool are documented upload routes. Account roles, matching app record, unique version/build and server processing remain external gates. No upload is automated here.
- [Version number](https://developer.apple.com/help/glossary/version-number/) and [build string](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion): explicit version/build metadata; increment macOS build before distribution.
- [Current icon catalog guidance](https://developer.apple.com/documentation/xcode/configuring-your-app-icon) and [ICNS tooling reference](https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/Optimizing/Optimizing.html): per-size Mac assets and iconutil ICNS conversion. This SwiftPM bundle retains the ICNS path; no asset-catalog/dependency migration.

Local Apple manuals inspected: `man productbuild`, `man pkgutil`; no signing
identity, real profile or Keychain was inspected. Full documentation endpoint
Markdown fetches failed for two pages; official indexed excerpts and current
certificate/profile/upload pages supplied the cited requirements.

## Reproduce the offline proof

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/packaging -v
bash -n scripts/build-app.sh
node --check scripts/configure-app.mjs
plutil -lint Resources/Info.plist Resources/LessMeet.entitlements Resources/LessMeet.sandbox.entitlements
git diff --check -- scripts Resources Tests/packaging
```

Fixtures use temporary synthetic app/config/profile bytes, fake artwork and mocked
Apple commands. The previous test generating a temporary certificate/private key
was replaced with mocked OpenSSL metadata parsing so the suite creates no keys or
certificates. Existing build-flow tests stub the Store input/stamp hook; dedicated
Store tests exercise those gates separately. None prove rendering, app launch,
sandbox recording, OAuth, purchases, installer execution or Apple upload acceptance.
