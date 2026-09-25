# Configuration reference

Last reconciled: 2026-09-25 (issue #2 production provisioning; older service observations retain their dates). This is the configuration inventory; decisions,
ownership and release gates remain in [STATUS.md](STATUS.md). Update this document
after each configuration change, including environment, verification date/result,
secret location and rollback limits. Never commit keys, tokens or private keys.

## First public Mac App Store release contract — issue #1

Status: issue #1 release identity ACCEPTED on 2026-09-25; core choices and target
audience 10+ approved, Apple identity/metadata readback completed. Actual Apple age
rating remains unsaved and is explicitly owned by [issue #4](https://github.com/hoangnb24/lessmeet/issues/4),
with category-by-category content assessment and saved rating required before
submission. Business/account verification deferred
at Human direction because the account is reported to be operating normally.
This section is the single release-identity reference; it does not approve signing,
upload, submission, public availability, legal declarations or agreement acceptance.
Sep 25 authorized Apple changes: saved name LessMeet, version 1.0.0, Productivity,
manual release and all 175 storefronts (including future storefronts). App remains
Prepare for Submission; no review submission or release occurred.

| Field | Evidence / current state | Proposed decision or remaining input |
| --- | --- | --- |
| Platform / identity | macOS; bundle `com.lessmeet.app`; team `63M98WD275`. Sep 25 live Developer account/Identifiers readback confirms team and exact Lessmeet App ID row; ASC selected bundle agrees. | Matches native plist/signing constants. Developer identifier description remains Lessmeet; no capability or profile change. |
| App record | Apple ID `6815021182`, SKU `lessmeet-macos`, English US; Sep 25 live [App Information](https://appstoreconnect.apple.com/apps/6815021182/distribution/info) readback confirms identity under Long Le account. | Accepted fresh dashboard evidence, not another app named Meetless. |
| Branding | Native `CFBundleName`/`CFBundleDisplayName`: `LessMeet`; Apple name changed from Lessmeet to LessMeet and verified after leaving/reopening App Information Sep 25. | Saved and aligned; historical provider labels are not new identities and need not be renamed. |
| First public version | Repo source and Apple draft now `1.0.0`; reopened [version page](https://appstoreconnect.apple.com/apps/6815021182/distribution/macos/version/inflight) Sep 25 shows 1.0.0 Prepare for Submission. | Accepted saved metadata only. No release build or upload produced; explicit release version input remains required. |
| Build strategy | Sep 25 [TestFlight](https://appstoreconnect.apple.com/teams/69a6de8c-6878-47e3-e053-5b8c7c11a4d1/apps/6815021182/testflight) shows No Builds / Submit a build to start testing. | First intended upload build `1`; recheck immediately before upload to detect intervening uploads. Increase integer numbers across uploads, never reset on version change; use explicit input within packaging validator range. No Apple reservation/upload made. |
| Primary category | Source plist `public.app-category.productivity`, Store/TestFlight validation and listing agree. Sep 25 Apple primary Category saved as Productivity and confirmed after reopening. | Accepted local and Apple metadata alignment. Secondary category unchanged/unset. |
| Storefronts | Human approved all; Sep 25 saved [availability page](https://appstoreconnect.apple.com/apps/6815021182/distribution/pricing/availability) shows Availability (175 Countries or Regions), 175 data rows, Available on App Release. Confirmation also includes future countries/regions, surfaced to Human before saving. | Availability selection accepted, not public release or provider/legal eligibility. No pre-order, price schedule or distribution-method change. |
| Target audience / age rating | Human explicitly selected ages 10+ Sep 25 and clarified this is target audience only, with rating based on actual content, not a binding minimum in terms. | Audience decision accepted for #1. No age override solely to force 10+; no new minimum-age clause or Made for Kids selection. Issue #4 owns unsaved questionnaire, defensible release-representative content assessment, under-13 privacy/consent/provider eligibility, and saved rating before submission. |
| Release mode | Sep 25 changed from automatic to Manually release this version; reopened version page confirms checked radio and saved version 1.0.0. | Accepted manual setting; no Add for Review, submission or release action. |
| Seller / DSA trader | Team display name Long Le; website draft copyright Hoang Bang remains unresolved. App Information incidentally displays existing non-trader declaration for this app Sep 25. | Recorded existing declaration, not validated or changed. Account Holder owns seller/DSA review at issue #4 before public submission; other business checks stay deferred. |
| Agreements / Tax / Banking | Human reports Sep 25 that the account is operating normally; individual statuses were not inspected. | Skip this check for current issue #1 work as requested. Account Holder owns any later Apple action-required notice; revisit at issue #5 production subscriptions, before public submission. This is not independent verification or authority to accept agreements/submit financial data. |

Age-rating reference checked Sep 25: Apple's current global tiers are 4+, 9+,
13+, 16+, 18+ (OS/regional ratings can differ), not a global 10+ tier.
[Apple rating guidance](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating)
and [rating definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions).
Human resolved the interpretation: 10+ is only target audience. Use the calculated
rating from truthful content declarations without a target-age override; do not
invent questionnaire answers to obtain a preferred rating. Apple's
[AI-specific reminder](https://developer.apple.com/news/?id=ks775ehf) requires
considering sensitive-content frequency from assistants/chatbots. Current source
prompts ground replies in transcripts, but do not prove a particular frequency or
absence of sensitive content; release-representative policy/behavior must inform
answers under issue #4. Suitable pre-release evidence can inform the assessment;
neither production users/personal recordings nor a particular sampling methodology
is inherently required. No paid/live tests are authorized by this handoff.

Local identity verification: packaging tests assert the source version/name/category,
explicit release version/build stamping, and rejection of missing/wrong branding or
category in both Store and TestFlight bundles. Existing approval, public service,
legal URL and signing gates remain intact; product-choice approval does not satisfy
them. Category value follows [Apple's plist reference](https://developer.apple.com/documentation/bundleresources/information-property-list/lsapplicationcategorytype).
Current listing, support HTML and unpublished legal drafts now spell the product
LessMeet; historical provider labels/identity records remain untouched. No website
publication or legal-policy approval is implied by spelling normalization.

Evidence policy: each accepted decision needs its dated Human confirmation and,
where applicable, saved dashboard readback. No credential, private key, personal
financial details or unredacted dashboard screenshots belong in Git. Sep 25 Chrome
skill connection accessed the signed-in Apple session; earlier claims that browser
tooling was unavailable were premature and are superseded. Only nonsecret readback
summaries/URLs are recorded here. Do not reuse an IAP private key as an App Store
Connect management credential. Reopen on bundle/team/seller/audience/storefront
changes. Remaining ownership and next checkpoint are in STATUS, not a second tracker.

## Accounts and environments

Sep 25 Human confirmed **Hoang Bang** as website/privacy/terms operator and
**hoang@2m0r.com** as website support/privacy contact. This does not independently
establish Apple seller/trader status or approve the legal drafts. Google OAuth
support/contact remains hoang@kieng.io.vn in the supplied handoff; no external
change performed. Reconcile the public support field before Branding submission.

| Service | Exact target / public configuration | Verified state |
| --- | --- | --- |
| Convex | `hoang-bang/lessmeet`, dev `zany-octopus-315`; `https://zany-octopus-315.convex.site` | Sep 24: accepted backend and retention workers deployed; RC preflight configuration provisioned. Intake/automation/preflight activation gates absent after synthetic rehearsal. Production not established. |
| Convex production | `hoang-bang:lessmeet:prod` resolves to `uncommon-narwhal-733` | Sep 25 CLI names-only inventory: no environment variables; usage-limits list: none configured. Discovered existing deployment; no create, env mutation or code deploy performed. Plan/region, code/data/scheduled-work state and cost boundary not yet verified. |
| Clerk development | LessMeet app `app_3JggBoRulgsbt70ZFjgy9h7UjqQ`, dev instance `ins_3JggBsWybMahxou8G4rXVmM2Snu` | Dashboard Sep 24: Apple/Google shared credentials. Sep 25 API readback: audience convex and exact callback still present; dev not modified. |
| Clerk production | Same LessMeet app; new `ins_3JoKJsnX2ro7wXXYQfu94imtJNX`, domain `auth.lessmeet.2m0r.com` | Sep 25 latest CLI readback: DNS/SSL/mail complete, Google configured, Apple credentials pending. Native API and aud=convex verified; exact callback saved. Google Publishing/Branding and end-to-end auth still incomplete. |
| Clerk production issuer | `https://clerk.auth.lessmeet.2m0r.com` | Matches generated domain/publishable key; public JWKS GET succeeds (one RSA key), CLI SSL complete. Backend JWT acceptance not tested; not provisioned to Convex. |
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

### Issue #2 production DNS and access checkpoint

Latest Sep 25 readback after Human Google handoff: Clerk DNS, SSL and mail all
complete; no pending DNS records. Earlier SSL-pending/handshake-failure observations
below are historical. No actual mail-delivery or end-to-end login claim.

Human approved production/credential setup and `auth.lessmeet.2m0r.com` plus only
necessary Clerk DNS additions on Sep 25. Clerk generated these exact CNAMEs;
Human reports adding all five on Sep 25. Lead verified each exact CNAME target
directly against authoritative `newt.ns.cloudflare.com` (TTL 300). DNS addition
is accepted; Clerk domain/SSL/mail verification is a separate checkpoint. Preserve
DNS-only (no proxy) and existing website/email records.

| Host | Target |
| --- | --- |
| `clerk.auth.lessmeet.2m0r.com` | `frontend-api.clerk.services` |
| `accounts.auth.lessmeet.2m0r.com` | `accounts.clerk.services` |
| `clkmail.auth.lessmeet.2m0r.com` | `mail.pfcieoi0slra.clerk.services` |
| `clk._domainkey.auth.lessmeet.2m0r.com` | `dkim1.pfcieoi0slra.clerk.services` |
| `clk2._domainkey.auth.lessmeet.2m0r.com` | `dkim2.pfcieoi0slra.clerk.services` |

Initial post-addition CLI status still reported domain_pending. Exact domain API
then verified four of five CNAMEs; DKIM2 remained unverified despite authoritative
DNS matching. Lead triggered the documented `dns_check` endpoint: DNS in_progress,
SSL/mail not_started, no failure hints. This supersedes the earlier missing-DNS
observation, not evidence of functioning OAuth or email delivery.
Subsequent exact-domain readback confirms **all five verified, DNS complete and
mail complete**. API-host SSL complete; account-portal SSL in_progress. Public GET
`https://clerk.auth.lessmeet.2m0r.com/.well-known/jwks.json` succeeds with one RSA
key; HEAD returned 405 (GET required). Account-portal HTTPS handshake failed while
its certificate was pending. Keep this failed probe separate from API-host success;
neither proves production OAuth, backend JWT acceptance or email delivery.
[Production domains dashboard](https://dashboard.clerk.com/apps/app_3JggBoRulgsbt70ZFjgy9h7UjqQ/instances/ins_3JoKJsnX2ro7wXXYQfu94imtJNX/domains).
Production callback `com.lessmeet.app://callback` is saved as
`ru_3JoKWBtrvDQuqMQ48JtSLr1L2d4`; audience `convex` and Native API enabled verified
through exact-instance API reads. No secret keys were printed/exported or copied
from dev; Clerk's production instance/key provisioning stays provider-managed.

Chrome runtime initialization currently fails on a missing browser-service module;
no provider page or browser authentication was inspected this turn. Wrangler
4.136.3 is logged in and sees the expected Cloudflare account, but its displayed
OAuth scopes have zone read, not DNS write. Do not substitute unrelated credentials
or reauthorize broad scopes to bypass this. Human completed the DNS additions;
Apple/Google credential setup still needs working dashboard access or an approved
scoped alternative. DNS verification can continue through Clerk CLI.

### Google production credentials — configured, public release incomplete

Human handoff: Google project `lessmeet` (LessMeet), organization `kieng.io.vn`;
External audience, support/contact `hoang@kieng.io.vn`. Web OAuth client
**LessMeet Clerk Production**, ID
`1040637696359-gkvivq7fqteo84b59ouf7lk671o5q4pq.apps.googleusercontent.com`.
Redirect `https://clerk.auth.lessmeet.2m0r.com/v1/oauth_callback`; JS origins empty
for hosted Clerk flow. Human reports only openid/userinfo.email/userinfo.profile
scopes, no Calendar/Drive; owner accepted Google User Data Policy. Client secret
entered directly into Clerk, not exported/read back or included in this inventory.

Lead exact Clerk config read independently confirms enabled=true, matching client
ID and aud=convex. CLI deploy status reports Google configured, Apple pending.
Human reached Google account chooser from the production account portal; full
sign-in/consent/callback/session and native/backend JWT smoke remain untested.
Google dashboard state is Human-reported: Testing, no test users; Publish app blocked
on Branding. Authorized domain 2m0r.com present but homepage/privacy/terms URLs empty.
The earlier missing-DNS observation is historical: Human authorized landing-only
publication Sep 25, deployed as Cloudflare Worker `lessmeet-legal`, version
`9550542c-f6e1-48f7-8a08-cd962a49ff00`, at `www.lessmeet.2m0r.com`.
See STATUS for live HTTPS verification. Policy approval/publication remains a
dependency; the landing deployment does not authorize publishing legal drafts.
Do not recreate this project/client or put any client secret into app configuration.
Google project identity here establishes OAuth only, not Gemini API project/key binding.

Rollback/current containment: do not point the native release at this unverified
stack, do not deploy backend code or enable gates yet; development remains selected.
The new Clerk instance is retained for resumable setup, not deleted. Reopen if its
domain/issuer or provider identity changes. Creating this instance does not prove
production billing eligibility or authorize paid upgrades.

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

RC preflight credential, project, revision and verified flag are provisioned to dev;
the other new names below were absent at the recorded checkpoint. Activation gates
remain off/unset until their configuration and external-operation approvals exist.
Approved retention policies do not themselves activate inventory or deletion.
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

Sep 25 issue #2 read-only refresh of exact dev `zany-octopus-315` succeeded:
the seven names above plus `REVENUECAT_PREFLIGHT_CONFIG_REF`,
`REVENUECAT_PREFLIGHT_PROJECT_ID`, `REVENUECAT_PREFLIGHT_PROJECT_VERIFIED` and
`REVENUECAT_PREFLIGHT_SECRET_KEY` (11 total). Names only: no values or secret
material read, no inference that present switches are enabled. No production
environment was verified by that earlier inventory alone. Subsequent production
Convex/Clerk observations are recorded above; other account observations retain
their original dates. Human approved production creation/necessary credentials;
paid upgrades/activation remain separate decisions in STATUS.

## Verification and change procedure

From the project root, read-only names inventory:

```sh
node node_modules/convex/bin/main.js env list --names-only --deployment zany-octopus-315
dig +short TXT resend._domainkey.lessmeet.2m0r.com
dig +short CNAME rsend.lessmeet.2m0r.com
dig +short CNAME send.lessmeet.2m0r.com
```

Before each setup/rotation: confirm exact environment/account and approved scope;
store secrets only in the approved vault/backend secret store or explicitly approved
ignored local storage (the current RC exception above); record the item
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
operator exception. RC inventory's separate v2 read key is provisioned; it does not
grant destructive permission. SDK/cross-device recreation risk remains unresolved.
Ledger/preflight retention approval and dev deployment are complete as recorded
above; contact/send privacy, provider activation, live tests and production remain
separate checkpoints. Store signing inputs remain in
[STORE_INPUTS.md](../Tests/packaging/STORE_INPUTS.md).
