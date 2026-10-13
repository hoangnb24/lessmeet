# LessMeet verification map

Read this index before driving the app. This map lists required entry points for
feature-level claims. XCUITest covers retained offline account-status flows.
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

The recording map applies to the current app. For current local transcription,
model setup and ChatGPT chat, use the procedures in the repository README and
inspect `Sources/LessMeet/Presentation/{LocalModelSetupView,LocalTranscriptView}.swift`
and `Sources/LessMeet/ChatGPTChat/{ChatGPTAccountView,LocalChatView}.swift`.
These source anchors are not runtime acceptance evidence.
The account, cloud transcript and cloud chat maps below are legacy only. They
must not direct checks of the current local app. The billing map is retired.

| Map | Scope | Source anchors (relative to repository root) |
| --- | --- | --- |
| [Account status](account-status.md) | Legacy offline refresh, stale responses and confirmation | `Sources/LessMeet/Account/{AccountPanel,OfflineAccountCheckView,OfflineAccountFixture,AccountDeletionModel}.swift` |
| [Recording library](recording-library.md) | Capture, search, title, playback, saved files | `Sources/LessMeet/Presentation/LibraryView.swift`, `Sources/LessMeet/Recordings/RecordingStore.swift` |
| [Transcripts](transcripts.md) | Legacy upload consent, saved refresh, batch recovery | `Sources/LessMeet/Presentation/{BatchTranscriptView,RecordingCloudModel}.swift` |
| [Transcript chat](transcript-chat.md) | Historical cloud chat; retained batch fixtures | `Sources/LessMeet/Presentation/{ChatTextEditor,BatchChatView}.swift` |

## Proof and skip reporting

Report each sub-feature and entry point as PASS, FAIL or UNVERIFIED. Record the
unmet precondition for skips. Saved files, provider state and financial effects
need evidence beyond the visible screen. Keep raw captures under ignored
`.artifacts/verify-lessmeet/`. No production deployment is implied by this map.
