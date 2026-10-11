# LessMeet verification map

Read this index before driving the app. This map lists required entry points for
feature-level claims. XCUITest covers five offline account-status flows.
Other paths require their stated inputs and authority; report them UNVERIFIED
when absent. A fixture pass cannot substitute for a live-path pass.

## Baseline preconditions

- Follow Launch and Doctor in [SKILL.md](../SKILL.md).
- One agent owns the UI in `docs/STATUS.md`.
- Offline checks need no account, recordings or external service.
- Live checks need an approved bundle, account and synthetic recording as relevant.
- Do not infer permission for recording, uploads, paid work or destructive actions.

## Driving conventions

Run `bash scripts/test-ui.sh` for the automated account-status checks; inspect
the `.xcresult` activities, assertions and attachments. See
[Xcode verification](../../../../Tests/UI/README.md) for test/debug instructions.
Use `lmClick(index, label)` and `lmCapture(name)` from SKILL.md in Computer Use.
Each index comes from the latest accessibility tree. Picker choices and menus need
another snapshot after opening. Record text input and keyboard actions too.
Keep action and result evidence, exact build identity and UTC times. Restore UI
state and retain evidence after cleanup. Mark transient states unseen if the tool
settles past them. A final screenshot cannot prove a spinner was displayed.

## Features

| Map | Scope | Source anchors (relative to repository root) |
| --- | --- | --- |
| [Account status](account-status.md) | Offline refresh, stale responses, confirmation; live account entry | `Sources/LessMeet/Account/{AccountPanel,OfflineAccountCheckView,OfflineAccountFixture,AccountDeletionModel}.swift` |
| [Recording library](recording-library.md) | Capture, search, title, playback, saved files | `Sources/LessMeet/Presentation/LibraryView.swift`, `Sources/LessMeet/Recordings/RecordingStore.swift` |
| [Transcripts](transcripts.md) | Upload consent, saved refresh, batch recovery | `Sources/LessMeet/Presentation/{LibraryView,BatchTranscriptView,RecordingCloudModel}.swift` |
| [Transcript chat](transcript-chat.md) | Composer, keyboard send, notes prompts, source, batch chat | `Sources/LessMeet/Presentation/{RecordingChatView,ChatTextEditor,BatchChatView}.swift` |
| [Plan and usage](plan-usage.md) | Allowance, refresh, purchase and restore | `Sources/LessMeet/Presentation/SubscriptionView.swift`, `Sources/LessMeet/Billing/BillingStore.swift` |

## Proof and skip reporting

Report each sub-feature and entry point as PASS, FAIL or UNVERIFIED. Record the
unmet precondition for skips. Saved files, provider state and financial effects
need evidence beyond the visible screen. Keep raw captures under ignored
`.artifacts/verify-lessmeet/`. No production deployment is implied by this map.
