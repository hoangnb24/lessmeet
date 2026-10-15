# LessMeet Terms of Use — unpublished draft

This draft describes the pre-pivot cloud product and retained provider obligations.
It is not the current local-first/ChatGPT product contract. Reconcile that change
before any publication; existing subscription obligations remain.

NOT FOR PUBLICATION until reviewed and completed by the operator. This is product
copy for review, not a complete jurisdiction-specific legal agreement.

Implementation notes reconciled 2026-10-13 against local source and recorded
acceptance. No external legal terms or live settings were revalidated.

Reconciled 2026-09-24 against `b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605`
and the accepted working-tree/development evidence in [STATUS](../STATUS.md).
Approved commercial inputs below are not evidence of public availability or
production configuration. See [provider decisions](PROVIDER_DISCLOSURES.md).
Sep 25 update: this candidate also supports the public homepage/Google Branding
dependency in issue #2; it is not an approved agreement or evidence of public launch.
Human confirmed operator Hoang Bang and support/privacy hoang@2m0r.com Sep 25.

Effective date: [REQUIRED]

Service operator: Hoang Bang
Support: hoang@2m0r.com
Website: https://www.lessmeet.2m0r.com
Planned terms URL (not yet verified/published): https://www.lessmeet.2m0r.com/terms
Planned privacy policy URL (not yet verified/published): https://www.lessmeet.2m0r.com/privacy

## App license

The operator has selected Apple's Standard End User License Agreement for the
App Store version: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
These service and subscription disclosures do not replace that license or limit
mandatory consumer rights. Sep 25 App Store Connect readback displayed the Standard
License Agreement; final release verification remains required before submission.

## Recording and AI

You are responsible for having permission to record and upload content, including
other participants' information. LessMeet provides local recording and optional
cloud transcription, recording chat, summaries and action items. AI output may be
inaccurate or incomplete; review it before relying on it. Local recording and
playback are not subject to subscription usage quotas. Technical/device limits
still apply. The existing single-upload route accepts at most 18 MiB. A separate
bounded chunked-recording path is implemented but default-off and not accepted
as a public production capability. A 120-minute allowance is not a promise that
any individual 120-minute recording can currently be uploaded.

## Accounts and availability

Google sign-in uses Clerk and basic identity, email and profile information, not
Calendar or Drive permissions. Signing in alone does not upload a recording or
start a subscription. You separately confirm a cloud upload or an App Store purchase.
Production Google publishing remains incomplete in the recorded handoff. Apple
credential readback and Human-reported hosted login were accepted Sep26; native
callback and full production flow remain separate checks. These review notes are
not a promise of current availability. See [configuration](../CONFIGURATION.md).

## Plans and allowances

At launch, Free includes a one-time allowance of 120 AI transcription minutes and
20 AI questions. This is not a monthly free grant. Pro includes 1,200 transcription
minutes and 200 AI questions per monthly allowance period. Annual subscribers also
receive monthly allowances, not a full year's usage upfront. Unused quota does not
roll over. Summary and action-item requests each use one AI question when successful.
System-failed tasks do not consume quota. Audio charges are rounded up to whole
seconds per upload, including encoding padding.

Pro allowance periods follow the original subscription anniversary in UTC, with
month-end clamping. Switching billing periods, restoring, or repurchasing does not
reset usage. When allowance is exhausted, new AI work stops; local capture and
already-saved local recordings/results remain available.

## Purchases and account access

The approved US launch prices are USD 9.99 per month or USD 99.99 per year.
The App Store purchase sheet shows the applicable localized price, billing period
and purchase terms. Subscriptions renew automatically unless canceled through
Apple's subscription management. Cancellation stops future renewal; access remains
until the verified paid period ends, subject to refunds/revocation. Handle purchase
and refund requests through Apple's available processes and applicable rights.

Sign in to LessMeet before purchasing. Subscription access is tied to the original
LessMeet account; using the same Apple account with a different LessMeet login does
not transfer it. Use Restore Purchases while signed in to the original LessMeet
account. Contact support if you cannot recover that account. Do not repurchase
under another LessMeet account as an account-recovery workaround.

Subscription cancellation does not delete stored data. See the Privacy Policy for
current retention and the approved privacy-request process.

Account deletion also does not cancel Apple renewal. Accepted native Account
settings include initiation, confirmation and status refresh. Provider workers are
integrated, and a selected Clerk deletion has recorded live evidence. Complete
provider fulfillment and automatic notification delivery remain unverified. See
the [deletion runbook](DELETION_RUNBOOK.md); do not present partial evidence as an
available end-to-end deletion service. Deletion may remove access tied to the original LessMeet
account; do not promise recovery, subscription transfer or a new allowance after
re-registration. Explain these consequences without making cancellation or a
support conversation a prerequisite for requesting deletion.

Cloud content remains indefinite unless deletion is requested. The separate approved
30-day provider-inventory inactivity policy and 90-day completed operational-ledger
policy are not content-expiry or fulfillment deadlines; see the Privacy draft for
their conditions. The approved operating policy is normal scoped deletion within
seven calendar days of receipt, with email updates/results. Exceptions require a
status, reason and next-update time. Actual fulfillment and remaining provider
handling still need evidence before public claims. Local files remain separate.

## Publication checklist — unresolved legal decisions

- Set the effective date when approved; publish and verify the planned URLs.
- Verify App Store Connect matches the approved Apple Standard EULA choice;
  do not upload this service disclosure as a custom EULA.
- Review mandatory consumer rights, governing law, permitted use, service changes,
  responsibility and dispute terms with the operator's legal adviser as appropriate.
- Confirm production quota/price behavior and support/account-recovery procedures
  match this copy before sale. Do not publish until launch gates are accepted.
- Human must resolve eligible ages and markets under the actual Gemini service
  terms, plus any required eligibility controls. No minimum-age clause or global
  availability promise is adopted by this draft. Do not change approved prices,
  allowances or indefinite cloud retention to resolve these questions implicitly.
