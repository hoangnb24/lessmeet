# LessMeet Xcode verification

Use unit/component tests for model behavior and view controls. Use the XCUITest
suite for repeatable flows in the running offline app. Use Computer Use for the
project's required visual acceptance and exploratory checks. Keep their results
separate. No test here logs in, records audio, uploads data or deletes an account.

## Run the UI tests

1. Read current UI ownership in `docs/STATUS.md`. Claim the offline fixture scope.
2. Close only your own offline-check app. The runner refuses an existing instance.
3. Run `bash scripts/test-ui.sh` from the repository root.
4. Open the printed `Tests.xcresult` in Xcode to inspect pass/fail results,
   named actions, screenshots and accessibility attachments.
5. Check `cleanup.txt` and release UI ownership.

The script creates a unique `.artifacts/verify-lessmeet/xcode.XXXXXX/` directory.
It retains build/test logs, exit code, Xcode version, bundle/test hashes and the
result bundle. DerivedData is reusable scratch state in the same ignored parent.
Evidence survives fixture termination and failed runs. Never delete proof during
cleanup. If a run is interrupted, inspect its exact process before terminating it;
do not kill apps by name. Check ownership before removing a stale `ui-test.lock`.

An active macOS desktop session and Xcode's UI automation permissions are required.
If macOS blocks automation, report the prompt and stop. Do not change permissions
or reset privacy settings automatically. A build-only pass is not a UI test pass.

## Run and debug in Xcode

1. Open `Tests/UI/LessMeetUITests.xcodeproj` in Xcode.
2. Select the shared **LessMeetOfflineUI** scheme and **My Mac** destination.
3. Choose **Product → Test** (Command-U).
4. Open the Test navigator to rerun a failed test. Set a breakpoint in
   `OfflineAccountUITests.swift` to inspect an element query or assertion.
5. Open the Report navigator to inspect the test's activities and attachments.

The `OfflineApp` dependency invokes `bash scripts/test-ui.sh --build-fixture`.
That checks for an existing fixture process and runs the repo's offline packaging
command. Both GUI and command-line tests therefore use the same packaged app.
The test runner is ad-hoc signed and independent of the production app target.
Run tests serially; do not drive Computer Use while XCUITest owns the fixture.

For app/model debugging:

1. Open the repository's `Package.swift` in Xcode.
2. Select a relevant test under `LessMeetTests` in the Test navigator.
3. Set a breakpoint in the model or view code and run that test.
4. Inspect values and the call stack when the breakpoint stops execution.

For example, run `AccountDeletionTests.testLateResponseCannotPublishAfterAccountChange`
with a breakpoint in `AccountDeletionModel.perform`. It exercises response handling
without live accounts. For editor behavior, run `ChatTextEditorTests`.
The package executable is not a substitute for the packaged app's recording
permission checks. The packaged offline build is optimized and hardened; this
setup does not promise source-level app attachment or change its signing rules.

## Coverage

| Test | Observable outcome |
| --- | --- |
| `testReadyAndPendingRefresh` | Selection alone leaves the old result; Refresh applies pending status |
| `testFailurePreservesLastAppliedStatus` | Failure text appears and prior status remains |
| `testGoogleStatesStaySeparateFromProviderCompletion` | Google pending/exception/acknowledgement stay separate from broad provider completion; failed refresh preserves the applied state |
| `testDelayedResponseCompletes` | Controls disable while waiting and recover when completed |
| `testSwitchAccountDiscardsDelayedResponse` | Bob receives no applied result from Alice's pending response |
| `testConfirmationCanBeCancelledAndCannotDelete` | Deletion stays disabled and Cancel closes the dialog |

The Google test is synthetic. It cannot prove provider revocation or propagation.
The confirmation check also requires the Google-project sign-in consequence.
Inspect screenshots for text wrapping; accessible text alone can hide truncation.
If the runner cannot enable automation mode, keep that result separate from
Computer Use evidence. Do not change system permissions as an automatic repair.

The suite drives visible controls through `XCUIApplication(url:)`. It checks the
bundle ID and absence of service configuration before launch. Each test starts
fresh and terminates only the app it launched, including after assertion failures.
The fixture uses the existing injected transport and shared production view/model.
No internal setters or HTTP test endpoints establish success.

Live sidebar account entry, OAuth, HTTP transport, real deletion, recording,
transcripts, chat and billing remain outside this suite. See the maintained
[feature map](../../.agents/skills/verify-lessmeet/features/README.md).

## Focused unit and component checks

Run `swift test --filter 'AccountDeletionTests|OfflineAccountFixtureTests|ChatTextEditorTests'`
for the initial focused checks. Run additional existing suites when changed code
requires them. XCUITest requires this Xcode project; `swift test` alone does not
run the UI suite.
