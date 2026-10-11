# Plan and usage

Users inspect server-verified allowances and access configured purchase or restore flows.

## Sub-features

- `plan-open`: display plan, allowance and configuration errors.
- `plan-refresh`: refresh server state.
- `plan-purchase`: purchase the selected configured package.
- `plan-restore`: restore an existing purchase.

## How to get to it (user POV)

- Click **Plan & usage** in the sidebar.
- Use **Refresh**, the displayed package purchase button, or **Restore Purchases**.
- Use **Privacy** and **Terms** links when configured. **Done** closes the sheet.

## Driving it with Computer Use

Preconditions: approved normal/sandbox bundle and account. This feature can make
network requests when opened. Store actions need explicit financial authority and
Computer Use's action-time confirmation. The offline fixture has no billing.

- **Open.** Run `lmClick(index, 'Plan & usage')`, then `lmCapture('plan-open')`.
  Compare displayed allowance with an authorized scoped server readback.
- **Refresh.** Click **Refresh**, capture resulting allowance/error and correlate
  the request with the applied state. Do not treat RevenueCat identity as authorization.
- **Purchase.** In an explicitly approved sandbox scenario, inspect the actual
  package price and Apple purchase sheet before confirmation. Capture completion
  and server-verified entitlement/allowance. Never assume the internal testing
  checkbox alone proves a sandbox transaction.
- **Restore.** With authority, click **Restore Purchases** and capture completion or
  error. Verify account-bound server state rather than relying only on the SDK result.
- **Close.** Click **Done** and confirm the library returns.

## Gotchas

- Disabled purchase controls can reflect missing legal links, configuration or auth.
- Opening links changes browser state; preserve the user's existing tabs.
- Account deletion does not cancel an Apple subscription.
- This map grants no purchase, restore, sign-in or configuration-change authority.
