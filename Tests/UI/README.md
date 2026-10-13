# LessMeet Xcode verification

## Full-Library navigation regression

`LessMeetLibraryUI` is a separate target with no app-build dependency. It leaves
the legacy `LessMeetOfflineUI` target and packaging flow unchanged. The dedicated
script tests an existing bundle; it never rebuilds or overwrites that bundle.

1. Obtain sole UI ownership and stop Computer Use before running this suite.
2. Supply a canonical absolute path to an approved `library-ui-check` bundle.
3. Run the retained baseline first:
   `bash scripts/test-library-ui.sh --app "$PWD/dist/library-ui-baseline/LessMeet.app"`.
4. Run the fixed candidate separately:
   `bash scripts/test-library-ui.sh --app "$PWD/dist/library-ui-check/LessMeet.app"`.
5. Inspect each printed evidence directory before accepting the result.

The script requires bundle ID `com.lessmeet.app.library-ui-check`, packaging mode
`library-ui-check`, a valid signature and no service configuration. It rejects
existing fixture processes, including another bundle path. The test repeats the
running-app check before each launch and verifies the executable hash. It uses
`XCUIApplication(url:)`, never bundle-ID launch or a production bundle fallback.
Do not replace the selected bundle during a run. The test terminates only its
recorded process with matching PID, launch date and bundle path. Interrupted runs
can leave a process alive; inspect the retained identity before manual cleanup.

Each meeting starts in a fresh fixture process. The test opens a real Library
row, checks Transcript, opens Chat, types a synthetic draft, switches to Transcript
and back, and checks that the exact draft remains. It switches to the other
meeting through Recent, checks its title and transcript, returns through sidebar
Library, filters for `short transcript`, then clears the search through Library.
No message is sent. It uses only the two fixed `Synthetic planning` titles.

Search, Recent, tabs and every clicked control must have nonempty frames fully
inside the window, be enabled and pass hit testing. This detects the original
off-window layout even when the accessibility tree still contains the controls.
The baseline must fail at the post-open geometry check; an unrelated setup/query
failure does not establish regression sensitivity. The fixed candidate must pass
both tests. Runtime results remain UNVERIFIED until these serial runs occur.
On 2026-10-13, the target built successfully, but the baseline runner failed before
test execution: `Timed out while enabling automation mode.` This is not a detected
layout failure. Rerun baseline and candidate when UI automation is available;
do not count the initialization failure as red/green evidence.

Evidence is retained under `.artifacts/verify-lessmeet/library-xcode.XXXXXX/`:
`identity.json`, build/test commands and logs, isolated `DerivedData`, exit code,
`Tests.xcresult`, summary and cleanup status. The result bundle includes screenshots,
accessibility trees, frame measurements and launched PID/start identity. A failure
before Xcode testing has no `.xcresult`; its nonzero exit still remains recorded.
The script shares the existing UI-run lock but does not use shared DerivedData.

Build-only verification does not launch an app:

```sh
xcodebuild build-for-testing -project Tests/UI/LessMeetUITests.xcodeproj \
  -scheme LessMeetLibraryUI -destination platform=macOS \
  -disableAutomaticPackageResolution -derivedDataPath /absolute/private/DerivedData
```

Run through the script, not Command-U: the script supplies the exact app path and
hash in the generated test plan. Resize, visual polish, real data, persistence
across launches, auth and live networking remain outside this regression. Resize
requires the separately owned Computer Use check. Do not change automation
permissions or install tools to bypass a blocked run.

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
