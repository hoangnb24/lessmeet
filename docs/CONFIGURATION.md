# Configuration reference

Last reconciled: 2026-09-24. This is the configuration inventory; decisions,
ownership and release gates remain in [STATUS.md](STATUS.md). Update this document
after each configuration change, including environment, verification date/result,
secret location and rollback limits. Never commit keys, tokens or private keys.

## Accounts and environments

| Service | Exact target / public configuration | Verified state |
| --- | --- | --- |
| Convex | `hoang-bang/lessmeet`, dev `zany-octopus-315`; `https://zany-octopus-315.convex.site` | Dev env names inspected Sep 24; new deletion/email/preflight configuration absent. Production not established by this audit. |
| Clerk | LessMeet app `app_3JggBoRulgsbt70ZFjgy9h7UjqQ`, dev instance `ins_3JggBsWybMahxou8G4rXVmM2Snu` | Dashboard Sep 24: no production environment; Apple and Google use Shared credentials. |
| Clerk issuer | `https://major-fish-4158.clerk.accounts.dev` | Explicit dev env value matches dashboard Sep 24. |
| RevenueCat | **Lessmeet**, dashboard `a83a7730`, API v2 `proja83a7730` | Sep 24: Keep with original App User ID; separate sandbox transfer behavior off. Do not use unrelated Meetless project. |
| RevenueCat apps | App Store `app0efc34c2fb`; Test Store `app2b707bf0f0` | Dashboard inventory Sep 24. |
| Resend | Team `kieng`; domain `lessmeet.2m0r.com`; Tokyo `ap-northeast-1` | Domain/DNS verified; no real sends. |
| Cloudflare | Account `6031f1f85e189c44fb3bcd150ca65920`, zone `2m0r.com` | Three LessMeet email records added and verified; unrelated records untouched. |
| Native app | Bundle `com.lessmeet.app`, callback `com.lessmeet.app://callback`, team `63M98WD275` | Sep 24: Sign In with Apple enabled as primary App ID after Human approval; saved and reopened to verify. Existing provisioning profiles for this App ID must be regenerated. Callback is existing project configuration; signing/profile compatibility not verified. |

Dashboard entry points: [Clerk SSO](https://dashboard.clerk.com/apps/app_3JggBoRulgsbt70ZFjgy9h7UjqQ/instances/ins_3JggBsWybMahxou8G4rXVmM2Snu/user-authentication/sso-connections),
[RevenueCat keys](https://app.revenuecat.com/projects/a83a7730/api-keys),
[Resend keys](https://resend.com/api-keys),
[Cloudflare DNS](https://dash.cloudflare.com/6031f1f85e189c44fb3bcd150ca65920/2m0r.com/dns/records).

## Secrets: where to find them

| Purpose | Storage / provisioned state | Scope |
| --- | --- | --- |
| Resend sending | 1Password **Private / LessMeet Resend / credential**; saved and readback verified. Not provisioned to Convex. | Key **LessMeet transactional**, Sending access only to `lessmeet.2m0r.com`. |
| Existing RC backend | Convex dev `REVENUECAT_SECRET_API_KEY`; dashboard key **Lessmeet Convex Dev**, v1. Vault reference not audited. | Existing billing contract; not the new v2 inventory credential. |
| RC preflight | Generated Sep 24; ignored local `keys/.env` is mode 0600 and not tracked. Provisioned to exact Convex dev `zany-octopus-315` with immutable revision `rc_lessmeet_preflight_20260924_v1`; secret readback matched without printing. Retention schema/functions are deployed; empty tables and no-op purge verified. 1Password storage was bypassed by Human direction after its CLI failed. | Key name **LessMeet deletion preflight read-only**, V2, Customers Configuration **Read only**; all other permission groups No access and Issue token disabled. Read-only synthetic 404 verified exact project `proja83a7730`; project-verified flag set. Intake and activation gates remain absent. |
| Clerk contact/preflight | `CLERK_CONTACT_SECRET_KEY` absent in audited Convex dev; vault reference not established. | Exact configured Clerk instance, server only. |
| Apple revocation signer | Original Services ID, applicable Key ID/private key and client provenance not established. | Do not substitute the native bundle ID or a different OAuth client. |
| Gemini | Existing Convex dev `GEMINI_API_KEY`; value and vault reference not audited. | Backend only; do not copy into native/public build configuration. |

Do not print secret-bearing `env list`, vault item JSON or `.env.local`. Use
names-only inventory. Saving a key in 1Password does not provision the backend.
No new production credentials or permissions are implied by this reference.

## Email and DNS

Sender: `notifications@lessmeet.2m0r.com` (fixed in the current adapter).
Resend domain ID: `f5879f50-fd00-4908-837e-2f6f2a143396`.

| Type | Name relative to `2m0r.com` | Value / source |
| --- | --- | --- |
| TXT | `resend._domainkey.lessmeet` | Exact public DKIM value from the Resend domain page; already verified. |
| CNAME | `rsend.lessmeet` | `rsend-apne1.forge.rmta.net`, DNS only |
| CNAME | `send.lessmeet` | `send.forge.rmta.net`, DNS only |

All TTLs Auto. Root SPF/DMARC/MX unchanged. Receiving off; no custom tracking
subdomain configured; opportunistic TLS unchanged. No paid upgrade performed;
account billing tier was not verified. Provider acceptance is not inbox delivery;
no delivery webhook/evidence path exists yet.

The local legal-site candidate is `website/`, worker `lessmeet-legal`, proposed
hostname `www.lessmeet.2m0r.com`; not published. Do not confuse it with existing
unrelated `meetless.2m0r.com` / `meetless-website`. See [website README](../website/README.md).

## Backend configuration map — not an activation script

These new names are absent from the audited dev deployment. Keep them off/unset
until the relevant configuration, retention and external-operation approvals exist.
Source behavior is specified in [BACKEND.md](BACKEND.md).

| Variables | Purpose / prerequisite |
| --- | --- |
| `ACCOUNT_DELETION_ENABLED` | New account-deletion intake; defaults off. |
| `DELETION_AUTOMATION_ENABLED` | Durable worker admission; does not implement missing destructive adapters. |
| `CLERK_CONTACT_ISSUER`, `CLERK_CONTACT_INSTANCE_ID`, `CLERK_CONTACT_SECRET_KEY` | Exact issuer/instance/credential binding; contact issuer must equal existing `CLERK_JWT_ISSUER_DOMAIN`. Current dev values are above, not production values. |
| `CLERK_CONTACT_INVENTORY_ENABLED` | Optional verified-primary contact read; no JWT/client-address fallback; Apple relay contacts blocked. |
| `DELETION_EMAIL_ENABLED`, `DELETION_CONTACT_RETENTION_APPROVED` | Both required for the notification adapter; approval is a Human decision, not a test flag. |
| `RESEND_API_KEY`, `RESEND_DELETION_CONFIG_REF` | Server-only vault credential and immutable configuration revision label. |
| `DELETION_PREFLIGHT_ENABLED`, `DELETION_PREFLIGHT_RETENTION_APPROVED` | Preflight also requires automation enabled; inventory is not deletion clearance. |
| `CLERK_PREFLIGHT_CONFIG_REF` | Immutable Clerk inventory configuration revision, using the shared Clerk binding above. |
| `REVENUECAT_PREFLIGHT_CONFIG_REF`, `REVENUECAT_PREFLIGHT_PROJECT_ID` | Immutable RC revision and exact v2 project ID `proja83a7730`. |
| `REVENUECAT_PREFLIGHT_SECRET_KEY`, `REVENUECAT_PREFLIGHT_PROJECT_VERIFIED` | Separate v2 read credential; verified flag requires actual project binding evidence. |

Clerk adapter pins API version `2026-05-12`. Revision labels must not be reused
after changing their target/account semantics. Frozen operations must not be
retargeted to another issuer/project during credential rotation or environment setup.

Existing dev names observed Sep 24: `BILLING_ENFORCEMENT_ENABLED`,
`CLERK_JWT_ISSUER_DOMAIN`, `GEMINI_API_KEY`, `GEMINI_BILLABLE_ENABLED`,
`REVENUECAT_ALLOW_SANDBOX`, `REVENUECAT_ORIGINAL_USER_POLICY_CONFIRMED`,
`REVENUECAT_SECRET_API_KEY`. Except the public issuer, this audit did not read values.

## Verification and change procedure

From the project root, read-only names inventory:

```sh
node node_modules/convex/bin/main.js env list --names-only --deployment zany-octopus-315
dig +short TXT resend._domainkey.lessmeet.2m0r.com
dig +short CNAME rsend.lessmeet.2m0r.com
dig +short CNAME send.lessmeet.2m0r.com
```

Before each setup/rotation: confirm exact environment/account and approved scope;
store secrets only in the approved vault/backend secret store; record the item
reference, nonsecret revision, verification outcome and date here. Record acceptance
and outstanding decisions in STATUS, not a second task tracker.

Disabling intake/email/preflight/automation switches prevents the corresponding
new admissions; it cannot recall submitted HTTP requests, undo completed deletion
or prove all in-flight work stopped. Existing deletion owner guards must remain.
Never purge durable records to reset retries. The approved ledger worker may purge
only after 90 uninterrupted days of verified full completion and with no unresolved
owner work; it removes request-linked identifiers and leaves only an unlinkable
policy/timestamp receipt. Secret revocation/DNS removal requires scoped approval and
may interrupt service; it is not a substitute for disabling sends.

Dev `zany-octopus-315` has the 90-day ledger schema/worker and one completed synthetic
rehearsal row scheduled under that policy. The temporary rehearsal function was
removed after use. `ACCOUNT_DELETION_ENABLED`, `DELETION_REHEARSAL_ENABLED`,
`DELETION_AUTOMATION_ENABLED`, `DELETION_PREFLIGHT_ENABLED`, and
`DELETION_PREFLIGHT_RETENTION_APPROVED` are absent; no provider deletion is active.

## Remaining setup decisions

Sep 24 authorized setup: enabled Sign In with Apple as primary App ID for Lessmeet
`com.lessmeet.app` under team `63M98WD275`; saved and reopened the identifier to
verify the checked state. Apple warned that this invalidates provisioning profiles
containing the App ID: regenerate them before future signing. No profile regeneration,
Services ID/private-key creation or Clerk connection changes performed.
RevenueCat V2 preflight key creation is complete. Human explicitly replaced the
blocked 1Password route with ignored local storage. `keys/.env` contains the secret
and exact project ID, has mode 0600, is covered by `/keys/`, and is not tracked.
Dashboard readback shows the V2 key with the approved name. A read-only GET for a
synthetic missing subject returned 404 `resource_missing`, establishing the key's
binding to exact project `proja83a7730` without creating or reading a real customer.
Convex dev `zany-octopus-315` now has the matching secret, project ID, immutable
revision `rc_lessmeet_preflight_20260924_v1`, and project-verified flag. The
automation, preflight and retention-approval gates remain absent, so this does not
activate provider reads. Move the secret to durable approved storage before release
or removing the workstation copy; never commit or paste it into chat.

Apple custom credentials must be bound to the original hosted OAuth Services ID;
preserve the existing shared development login until the target environment and
identity migration implications are decided. Apple ambiguous revocation remains an
operator exception. RC inventory needs a separate v2 key; SDK/cross-device recreation
risk remains unresolved. Retention/privacy decisions, dev provisioning, live tests,
real sends and deployment are separate checkpoints. Store signing inputs remain in
[STORE_INPUTS.md](../Tests/packaging/STORE_INPUTS.md).
