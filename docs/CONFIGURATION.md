# Configuration reference

Last reconciled: 2026-10-03 (issue #3 scoped provider provisioning; older service observations retain their dates). This is the configuration inventory; decisions,
ownership and release gates remain in [STATUS.md](STATUS.md). Update this document
after each configuration change, including environment, verification date/result,
secret location and rollback limits. Never commit keys, tokens or private keys.

Oct4 local email candidate: normal scoped deletion within7 calendar days of receipt,
email updates/results, and explicit exception status/reason/next-update time are
approved. This is not permission to send or enable automatic sends. Candidate
separates contact capture from the send gate and checks durable verified contact
before new Clerk deletion. OFFLINE tests accepted; not deployed or activated here.
Production contact credential/gates below retain their observed state. Prepare
exact Clerk issuer/instance-bound contact credentials and existing retention gate
for a selected live capture; keep DELETION_EMAIL_ENABLED=false. Do not claim a usable
real email path until capture and separately authorized exact-recipient delivery
are verified. Broad privacy/retention review belongs to #4.

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
| Convex production | `hoang-bang:lessmeet:prod` resolves to `uncommon-narwhal-733`; team `252081`, project `3049432`, region `aws-us-east-1` | Sep 26 candidate remains deployed. Oct3 Chrome confirms exact running production. Intake/automation and Clerk/RC execution true; exact case adoption still required. Apple, preflight and email off. No real E2E pass. |
| Clerk development | LessMeet app `app_3JggBoRulgsbt70ZFjgy9h7UjqQ`, dev instance `ins_3JggBsWybMahxou8G4rXVmM2Snu` | Dashboard Sep 24: Apple/Google shared credentials. Sep 25 API readback: audience convex and exact callback still present; dev not modified. |
| Clerk production | Same LessMeet app; `ins_3JoKJsnX2ro7wXXYQfu94imtJNX`, domain `auth.lessmeet.2m0r.com` | Sep 26 CLI complete=true: DNS/SSL/mail complete, Apple and Google configured, no pending providers. Apple exact config readback accepted below. Native API/callback previously verified; aud=convex rechecked. Google Publishing/Branding and end-to-end auth still incomplete. |
| Clerk production issuer | `https://clerk.auth.lessmeet.2m0r.com` | Provisioned/readback verified on Convex production Sep 26; deployed auth config audience convex. Public JWKS/CLI SSL previously verified. Native JWT/backend runtime acceptance deferred to #7. |
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

Current containment: production backend is now deployed with activation gates off;
do not point the native release at this runtime-unverified stack yet. Development
remains selected. See Sep 26 provisioning/rollback checkpoint below.
The new Clerk instance is retained for resumable setup, not deleted. Reopen if its
domain/issuer or provider identity changes. Creating this instance does not prove
production billing eligibility or authorize paid upgrades.

## Secrets: where to find them

| Purpose | Storage / provisioned state | Scope |
| --- | --- | --- |
| Resend sending | 1Password **Private / LessMeet Resend / credential**; saved/readback verified. Oct3 copied to production `RESEND_API_KEY` and readback matched; email gate false. | Key **LessMeet transactional**, Sending access only to `lessmeet.2m0r.com`. |
| Existing RC backend | Convex dev `REVENUECAT_SECRET_API_KEY`; dashboard key **Lessmeet Convex Dev**, v1. Vault reference not audited. | Existing billing contract; not the new v2 inventory credential. |
| RC preflight | Generated Sep 24; ignored local `keys/.env` is mode 0600 and not tracked. Provisioned to exact Convex dev `zany-octopus-315` with immutable revision `rc_lessmeet_preflight_20260924_v1`; secret readback matched without printing. Retention schema/functions are deployed; empty tables and no-op purge verified. 1Password storage was bypassed by Human direction after its CLI failed. | Key name **LessMeet deletion preflight read-only**, V2, Customers Configuration **Read only**; all other permission groups No access and Issue token disabled. Read-only synthetic 404 verified exact project `proja83a7730`; project-verified flag set. Intake and activation gates remain absent. |
| Clerk contact/preflight | `CLERK_CONTACT_SECRET_KEY` absent in audited Convex dev; vault reference not established. | Exact configured Clerk instance, server only. |
| Clerk deletion production | Existing standard `default` key from exact production Clerk, copied to Convex `CLERK_DELETION_SECRET_KEY` Oct3. `/v1/instance` returned200 and matched production; secret readback matched. | Admin-level Clerk key, not a new least-privilege key. Shared rotation with its other existing consumers. No contact key or Apple credential copied implicitly. |
| RC deletion production | Key `LessMeet production deletion`, V2, dashboard ID `apikeya8bb87e231`, created Oct3 with Human's specific confirmation. Stored in Convex `REVENUECAT_DELETION_SECRET_KEY`; readback matched. | Only Customers Configuration Read & write. All other groups No access, Issue token off; saved permission readback verified. No customer DELETE yet. |
| Apple revocation signer | Current hosted Services ID/Team ID/Key ID and login-secret presence verified. Dedicated presigned revocation credential and per-identity historical client provenance are not established. | Do not substitute the native bundle ID or treat current login settings as historical provenance. |
| Gemini | Human identifies existing Convex dev `GEMINI_API_KEY` as the production credential and authorizes reuse Sep 26. Copied in memory into exact production uncommon-narwhal-733; readback equals dev, dev unchanged. No key value persisted locally or printed. | Backend only; GEMINI_MODEL=gemini-flash-latest (existing source default), GEMINI_BILLABLE_ENABLED=false. Shared credential couples dev/prod rotation; runtime model access not tested. |

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

The pre-release landing is `website/`, worker `lessmeet-legal`, live at
`www.lessmeet.2m0r.com` with verified HTTPS Sep 25. Legal policies remain unpublished.
Do not confuse it with existing
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
| `CLERK_DELETION_ENABLED` | Oct3 production true; bound credential/revision provisioned. Requires automation gate, exact adoption and frozen Apple disposition. No live deletion tested. |
| `GOOGLE_DELETION_ENABLED` | Local Oct5 extension, default-off. Required before new Clerk execution adoption or destructive effects. Not activated by tests or old-case approval. |
| `GOOGLE_DELETION_CLIENT_ID`, `GOOGLE_DELETION_AUTHORIZED_PARTY_ID` | Exact trusted OAuth client IDs for tokeninfo `aud` and `azp`. Do not infer one from the other or use Clerk publishable keys. |
| `GOOGLE_DELETION_PROJECT_REF`, `GOOGLE_DELETION_CONFIG_REF` | Verified project provenance label and immutable revision. Google revocation can affect this user's grants across clients in that project. Exact live scope confirmation is required. |
| `APPLE_DELETION_ENABLED` | Deployed Sep 26, absent/default-off in production; dedicated credentials/configuration and original-client provenance required. |
| `REVENUECAT_DELETION_ENABLED` | Oct3 production true; separate v2 write credential/configuration provisioned. Exact adoption, fresh alias checks and Clerk/recreation evidence still required. No live deletion tested. |
| `CLERK_CONTACT_ISSUER`, `CLERK_CONTACT_INSTANCE_ID`, `CLERK_CONTACT_SECRET_KEY` | Oct3 production issuer/instance binding set and verified; contact credential absent. Contact issuer must equal `CLERK_JWT_ISSUER_DOMAIN`. Do not use dev identifiers in production. |
| `CLERK_CONTACT_INVENTORY_ENABLED` | Oct4 local candidate: with contact-retention approval, permits verified-primary read even with sends off. No JWT/client-address fallback; Apple relay contacts blocked. |
| `DELETION_EMAIL_ENABLED`, `DELETION_CONTACT_RETENTION_APPROVED` | Both required for automatic sending. Contact capture instead combines the retention gate with CLERK_CONTACT_INVENTORY_ENABLED. Approval is a Human decision, not a test flag. |
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

### Oct3 issue #3 configuration and rehearsal boundary

Chrome plugin works with the existing session. Human completed Clerk/Resend login;
fresh pages now show LessMeet production and kieng/lessmeet.2m0r.com respectively.
The old browser-runtime failure below is historical. No Apple Events setting change
is needed. No user/customer lists or unrelated secret values were read.

Production has29 names after scoped provisioning. New nonsecret bindings:
- CLERK_CONTACT_ISSUER=https://clerk.auth.lessmeet.2m0r.com;
  CLERK_CONTACT_INSTANCE_ID=ins_3JoKJsnX2ro7wXXYQfu94imtJNX.
- CLERK_DELETION_CONFIG_REF=clerk_lessmeet_prod_deletion_20261003_v1.
- REVENUECAT_DELETION_PROJECT_ID=proja83a7730;
  REVENUECAT_DELETION_CONFIG_REF=rc_lessmeet_prod_deletion_20261003_v1.
- REVENUECAT_PREFLIGHT_PROJECT_ID=proja83a7730;
  REVENUECAT_PREFLIGHT_CONFIG_REF=rc_lessmeet_prod_preflight_20261003_v1;
  REVENUECAT_PREFLIGHT_PROJECT_VERIFIED=true. Existing dev read key reused;
  dev value unchanged. Chrome reconfirmed the scoped read-only key permissions.
- RESEND_DELETION_CONFIG_REF=resend_lessmeet_prod_deletion_20261003_v1.
  Existing `Private / LessMeet Resend / credential` copied to RESEND_API_KEY
  through memory/stdin; readback matched. Initial vault read timed out; second
  scoped attempt succeeded. No new key or notification was sent.

Resend Chrome evidence: exact domain verified in Tokyo; `LessMeet transactional`
has Sending access only to lessmeet.2m0r.com and zero uses. This does not prove the
stored credential still authorizes a send, inbox delivery or Apple relay delivery.
Email/contact/preflight gates stay false. CLERK_CONTACT_SECRET_KEY and preflight
revision are not provisioned. Oct4 local candidate now requires durable verified
contact before new Clerk adoption/destructive work. Preflight remains independent.
Do not enable email sending to make contact inventory work.

Clerk/RC gates were enabled only after deletions, deletionClerkExecutions and
deletionProviderExecutions returned empty. They remained empty after activation.
No request/case was adopted. Apple signing/provenance remains conditional work:
current hosted config and secret presence are verified, but no dedicated presigned
APPLE_DELETION_CLIENT_SECRET or Apple execution credential has been provisioned.
Current client configuration is not proof for an older identity. Keep Apple off;
use the approved manual exception for missing evidence, not a fabricated success.

Local rehearsal artifact: `dist/issue3-production-rehearsal-20261003/LessMeet.app`.
Built with existing `build-app.sh dev`, explicit production publishable key and
Convex URL, ad-hoc signature and empty RevenueCat/public-legal configuration.
No source/.env.local change. Prior `dist/LessMeet.app` restored after build.
This is a local account/JWT/intake trial, not TestFlight/App Store signing or a
RevenueCat SDK/customer-deletion test. See the [rehearsal steps](legal/DELETION_RUNBOOK.md#oct3-production-rehearsal--prepared-not-run).

### Sep 26 issue #2 provisioning scope accepted by Human

Human explicitly narrows #2 closure to (1) production backend/Clerk issuer deployment
and (2) Gemini secret/model provisioning. Native/JWT and live transcription/chat
tests are deferred to release QA (#7), not reported as passing. Operating-cost
approval supersedes billing audit holds. Gemini credential is reused from dev by
explicit instruction; exact Google project and provider data settings are not
independently attested by equality of secrets. Retain policy/eligibility work in #4.

Production URLs: https://uncommon-narwhal-733.convex.cloud (deployment) and
https://uncommon-narwhal-733.convex.site (HTTP routes). Issuer:
https://clerk.auth.lessmeet.2m0r.com, audience convex. Native release config is not
switched by this deployment. Names-only inventory (14 names):

- CLERK_JWT_ISSUER_DOMAIN
- GEMINI_API_KEY, GEMINI_MODEL
- GEMINI_BILLABLE_ENABLED, BATCH_TRANSCRIPTION_ENABLED, BATCH_CHAT_ENABLED
- BILLING_ENFORCEMENT_ENABLED
- ACCOUNT_DELETION_ENABLED, DELETION_AUTOMATION_ENABLED
- DELETION_PREFLIGHT_ENABLED, DELETION_PREFLIGHT_RETENTION_APPROVED
- DELETION_EMAIL_ENABLED, DELETION_CONTACT_RETENTION_APPROVED
- CLERK_CONTACT_INVENTORY_ENABLED

At the issue #2 checkpoint all11 gates above were false. Issue #3 later enabled
ACCOUNT_DELETION_ENABLED and DELETION_AUTOMATION_ENABLED, both readback verified;
other gates unchanged. Missing provider execution gates default off. No RevenueCat,
Clerk backend or email secret copied; no batch-owner allowlist. Deployment registers
the existing five minute crons and two daily purges (nominal 7,202 invocations/day);
flags prevent new gated work, not all Convex resource usage or retention execution.
Pre-deploy storage/scheduled work were freshly checked empty. No live AI calls,
recording upload, native login or destructive test performed.

Containment/rollback: native config remains unchanged. Intake/automation activation
is now authorized; provider gates stay off until provisioning is complete.
To stop new deletion admission, set both intake and automation false on this exact
production deployment before investigating; this does not cancel in-flight work
or disable all crons. Do not delete data or revoke the shared Gemini key as a
rollback shortcut. Code rollback requires an identified previously accepted
production candidate; the prior #2 deployed source is HEAD8edfcee, but rollback
compatibility with new execution records must be checked. Preserve issuer/key
binding and evidence tables during any rollback.

Earlier Sep 26 checkpoint (superseded by provisioning above): Human accepts operating costs and waives another billing/plan audit.
Historical cost/allowance holds below are superseded; no numeric budget is required
to continue technical production setup. Exact production CLI refresh still returns
no env names and functions: []; production Gemini is not provisioned. Retain dev,
secret hygiene and separate destructive/public-release boundaries.

### Sep 26 Apple credential setup accepted

Human saved credentials directly in Clerk production. Exact readback: enabled=true,
Services ID com.lessmeet.app.signin, Team ID 63M98WD275, Key ID 9QG4X948Z4,
secret present without printing/persisting its value. Optional native bundle ID is
empty; current app uses hosted authentication. Deploy status complete=true with
both Apple/Google configured, DNS/SSL/mail complete and no pending providers.
This supersedes missing-Apple-credential observations below. Human subsequently
tested Apple login and supplied an authenticated Clerk profile screenshot with
Apple linked and Hide My Email. Hosted web login accepted as Human-supplied
evidence; no account email or screenshot copied into Git. Key backup location,
private-relay Email Source registration/delivery, native
callback and backend JWT acceptance remain unverified. Do not treat configuration
acceptance as a working revocation signer or change development shared credentials.

### Sep 25 production access refresh

Convex production empty-state and region are now verified by the bounded read-only
audit accepted in STATUS. Team usage state Default does not identify its plan.
Spending-limit readback has disableThresholdCents=null and state=null; deployment
usage limits list is empty. Seeded usage reported nonzero query/mutation compute
(4.1666666666666667e-7 GB-hours day/month) and eight other metrics zero before
subsequent diagnostic reads. This is not zero-cost proof. Verify actual plan,
remaining allowance and Human-approved spending boundary before deploying the
backend with its nominal 7,202 scheduled invocations/day. Do not change team-wide
limits without considering other deployments or silently disable retention crons.

Clerk exact production config readback: Apple enabled, but Services ID, Team ID,
Key ID, secret and optional native bundle ID fields are empty. Google enabled with
the previously recorded client ID. Session aud=convex, Native API enabled and the
single exact callback com.lessmeet.app://callback remain verified. Deploy status is
oauth_pending (Apple only); DNS/SSL/mail complete. No configuration was changed.

Apple next input: inspect existing Services IDs and Sign in with Apple keys under
team 63M98WD275 before creating anything. Bind the hosted OAuth client to existing
primary App ID com.lessmeet.app; do not substitute an IAP/ASC key. For hosted login,
Clerk requires Services ID, Team ID, Key ID and Apple private key. Preserve dev's
shared credentials. Obtain Return URL and private-relay Email Source from the exact
production Apple connection; do not invent the relay sender. Keep private-key
material out of Git/chat and decide durable secure storage before generating a
download-once key. [Clerk Apple setup](https://clerk.com/docs/guides/configure/auth-strategies/social-connections/apple)
checked Sep 25. Browser/computer-use startup is still broken, before authentication;
there is no usable Apple management CLI credential established by this audit.

RevenueCat exact read-only probe GET /v2/projects/proja83a7730/apps/app0efc34c2fb
with the existing scoped preflight key returned 403 authorization_error, requiring
project_configuration:apps:read. This is a permissions limit, not evidence of an
incorrect app or absent products. Keep that customer-inventory key unchanged;
complete app/products/entitlement readback using the dashboard or a separately
approved least-privilege configuration-read credential. No customers, purchases or
provider mutations occurred. Match bundle com.lessmeet.app, entitlement lessmeet_pro,
and products com.lessmeet.app.pro.monthly / com.lessmeet.app.pro.yearly.

Gemini exact production project/billing identity remains unverified; Human asked
for Project ID and managing account, not an API key. Google OAuth project lessmeet
does not establish Gemini binding. No gcloud executable available in the current
shell. Source fallback model is gemini-flash-latest (convex/gemini.ts); a source
default is not a verified production model or evidence of access/data settings.
No live generation or secret copying is authorized by this check.

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
