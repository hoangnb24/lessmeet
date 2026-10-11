# Account status

Users connect an account and inspect deletion status. The offline app exercises
shared status rendering with synthetic responses and a disabled deletion action.

## Sub-features

- `account-connect`: restore a session or sign in from Account (live only).
- `status-ready`: apply a response with no deletion request.
- `status-pending`: show pending cloud and provider handling.
- `status-error`: show a refresh failure.
- `status-wait`: show and complete a delayed response.
- `status-stale`: discard the previous account's delayed response.
- `confirmation`: preview the deletion terms and cancel.

## How to get to it (user POV)

- Offline: launch **LessMeet Offline Check** to reach the response controls.
- Live: click **Your account** (or the signed-in display name) in the sidebar.
  Click **Connect Account**, then **Sign In with Google or Apple** if needed.
- Live: use **Refresh deletion status** in Account. Opening the status view also
  refreshes automatically. **Delete Account…** opens the confirmation dialog.
- Offline: **Preview deletion confirmation (no deletion)** opens the same dialog.

## Driving it with XCUITest and Computer Use

Preconditions: Launch and Doctor pass. Offline actions below need no live account.
Live login and account changes need separate authority and the app-check procedure.

- **Automated checks.** Run `bash scripts/test-ui.sh`, or open
  `Tests/UI/LessMeetUITests.xcodeproj` and test the **LessMeetOfflineUI** scheme.
  The five tests cover ready/pending refresh, error preservation, delayed completion,
  account switching and confirmation cancellation. Inspect assertions and retained
  screenshots in `Tests.xcresult`. The picker uses `offline-response`; the result
  uses `offline-refresh-result`. Do not run Computer Use at the same time.

- **Ready.** Run `lmClick(index, 'Refresh deletion status')`, then `lmCapture('ready')`.
  Expect **Applied response: requested=false**. Startup may already have applied it.
- **Pending.** Click **Response**, capture the opened picker, then click
  **Deletion pending** using `lmClick`. Capture again. Click **Refresh deletion status**.
  Expect **Applied response: requested=true**, **Account deletion requested**,
  pending cloud cleanup and pending provider handling.
- **Failure.** Select **Request fails** through the picker. Click **Refresh deletion status**.
  Expect **Synthetic connection failure. No request was sent.** Do not infer that
  a prior applied status disappears; preserve the before/after evidence.
- **Waiting.** Select **Wait for response**, then refresh. Capture **Refresh is waiting**
  and disabled refresh. Click **Complete pending response**. Expect requested=false.
- **Stale response.** Start the waiting scenario, then click **Switch synthetic account**.
  Expect **Account: offline-bob** and **No response applied**. No old result may apply.
- **Confirmation.** Click **Preview deletion confirmation (no deletion)**.
  Capture the terms and disabled **Delete Account and Cloud Data** action.
  Click **Cancel** and confirm the dialog closes.
- **Live entry.** Use the sidebar account control, then the observed connection
  controls. Capture state after each `lmClick`. After authorized refresh, correlate
  the click, request and applied state. Fixture evidence does not cover this entry.

## Gotchas

- Response selection alone does not refresh status.
- Offline confirmation cannot delete. Do not enable or bypass its disabled control.
- No status text proves that every provider copy was erased.
- Live deletion and sign-out are not part of the default rehearsal.
- A shared view passes only for the exact build and scenario that was driven.
