---
name: verify-lessmeet
description: Validate LessMeet changes with Xcode, unit/component tests, XCUITest and Computer Use evidence. Use for repeatable offline account-status checks, debugging failed tests, or mapped recording, transcript, chat and billing verification.
---

# Verify LessMeet

Read `~/.config/codex-room/workflow/WORKSPACE_PROTOCOL.md`, `docs/WORKSPACE_PROTOCOL.md`
and current ownership in `docs/STATUS.md`. Use the required
[lessmeet-app-check](../lessmeet-app-check/SKILL.md) and installed Computer Use skill.
Record one live UI owner before launch. Read the [feature map](features/README.md).

The primary surface is a SwiftUI macOS app. Convex HTTP services and the website
are secondary surfaces; this skill does not establish their deployment state.
macOS 15+, Swift 6.3 with Swift Build, Node 22+, Python 3 and the installed
`mcp__node_repl__js` / `@oai/sky` tools are needed. Do not install missing tools.

## Choose the verification path

Use existing unit/component tests for changed logic. Use XCUITest for repeatable
offline user flows. Use Xcode to inspect test reports and debug failures. Keep
Computer Use for the required visual acceptance and exploratory checks. Run one
UI driver at a time. Do not substitute a build pass for a UI assertion pass.

1. Run `swift test --filter 'AccountDeletionTests|OfflineAccountFixtureTests|ChatTextEditorTests'`
   for the initial account/model/editor checks. Select other suites for other changes.
2. Run `bash scripts/test-ui.sh` for the five offline account UI tests. It builds
   the packaged fixture, runs XCUITest serially and prints a durable evidence path.
3. Inspect `exit-code.txt`, `summary.json`, `cleanup.txt` and `Tests.xcresult` in
   that directory. Failed attempts retain logs and evidence too.
4. For Xcode, open `Tests/UI/LessMeetUITests.xcodeproj`, select **LessMeetOfflineUI**
   and **My Mac**, then use **Product → Test**. Debug a test query with a breakpoint
   in `OfflineAccountUITests.swift`. Open `Package.swift` to debug model/component tests.
5. After XCUITest releases the fixture, use the Computer Use procedure below for
   the affected visual acceptance. Record exact artifact hashes for both checks.

Read [Xcode verification](../../../Tests/UI/README.md) for setup, coverage,
cleanup and debugging limits. Xcode UI automation needs a logged-in desktop and
the required macOS permissions. Report blocked permissions as UNVERIFIED; do not
change system settings automatically. Tests do not authorize live cloud actions.

## Launch

Run commands from the repository root. The default rehearsal needs no account,
ports, seed files or environment variables. The existing `offline-check` build
uses an in-memory transport at the production model's injected `send` boundary.
It renders the shared `AccountDeletionView`. It does not prove live HTTP behavior.

1. Check `ps -axo pid=,command=` for an existing exact
   `dist/offline-check/LessMeet.app/Contents/MacOS/LessMeet` process. Stop if one
   exists without ownership. Do not replace a bundle while another agent drives it.
2. Create a private evidence directory:
   `mkdir -p .artifacts/verify-lessmeet; mktemp -d "$PWD/.artifacts/verify-lessmeet/run.XXXXXX"`.
   Use that returned absolute path as `lmEvidence` below. Keep build output there.
3. Build with `bash scripts/build-app.sh offline-check`. Require exit code 0 and
   `Built .../dist/offline-check/LessMeet.app`. Keep the command and output in the proof.
4. Start the exact executable with `exec "$PWD/dist/offline-check/LessMeet.app/Contents/MacOS/LessMeet"`
   through `exec_command` with `tty: true` and `yield_time_ms: 1000`. Retain its session ID.
5. Run Doctor. Then get state through Computer Use with the absolute bundle path.
   Require the `Offline account check` heading and `Account: offline-alice`.
   Automatic refresh can already show `Applied response: requested=false`.

The offline bundle ID is `com.lessmeet.app.offline-check`. It has no OAuth callback
or service configuration and uses ad-hoc signing. Its entry point is compile-time
isolated in `Sources/LessMeet/LessMeetApp.swift`. It shares no recording store with
normal builds. Still allow only one driver of this fixture instance.

For authorized live features, use the exact approved bundle. The documented dev
command is `bash scripts/build-app.sh` then `open dist/LessMeet.app`. It reads
allowlisted public configuration from `.env.local`; do not print the file.
For auth checks, follow README's `auth-check --preflight` and stable-signing procedure.
Do not rebuild or replace a signed artifact just to make automation work.
Normal instances share `~/Library/Application Support/LessMeet/Recordings`;
there is no UI launch flag for a separate library. Do not double-drive them.

## Doctor

Run `.agents/skills/verify-lessmeet/scripts/doctor.py` before driving the fixture
and whenever its identity or state is uncertain. It is read-only and emits JSON
with the exact PID, start time, bundle ID, executable/plist hashes and signature
result. It rejects absent/duplicate processes and service-configured bundles.
Save stdout as `doctor.json` in the evidence directory. A pass establishes bundle
and process identity; readiness still requires the visible heading above.

For a live bundle, record its absolute path, PID/start time, executable/plist hashes
and `codesign --verify --strict` result separately. The offline helper intentionally
rejects live bundles. Check auth through the approved UI only; opening Account can
refresh status. Do not treat HTTP 200 as proof that a response reached the UI.

## Drive

For manual Computer Use checks, use `mcp__node_repl__js` for every UI action.
The XCUITest suite drives its own controls through Apple's runner. Do not operate
both drivers at once. Initialize once in a fresh Computer Use session:

```js
var sky = (await import('@oai/sky')).sky;
var fs = await import('node:fs/promises');
var fileURLToPath = (await import('node:url')).fileURLToPath;
```

Set `lmApp` to the absolute approved bundle and `lmEvidence` to the directory
returned by Launch. Define these small evidence functions in that same session:

```js
var lmCapture = async (name) => {
  var state = await sky.get_app_state({app: lmApp, disableDiff: true});
  await fs.writeFile(`${lmEvidence}/${name}.txt`, state.text);
  if (state.screenshot) await fs.copyFile(fileURLToPath(state.screenshot.url), `${lmEvidence}/${name}.png`);
  nodeRepl.write(state.text);
  return state;
};
var lmClick = async (index, label) => {
  await fs.appendFile(`${lmEvidence}/actions.jsonl`, JSON.stringify({at: new Date().toISOString(), action: 'click', index, label}) + '\n');
  await sky.click({app: lmApp, element_index: index});
};
var lmState = await lmCapture('01-before');
```

Read the current accessibility tree, which lists visible controls and their indices.
Call `lmClick` with the observed index and label, then `lmCapture` before choosing
another index. Never persist indices across snapshots or runs. For text, use
`sky.click` then `sky.paste({app: lmApp, text: ..., format: 'text'})`; record the
input action and take a new snapshot. Use `sky.press_key` for mapped shortcuts.
Inspect saved screenshots through `nodeRepl.emitImage` before making visual claims.

Default proof: follow `account-status.md` for ready, pending and failure refreshes.
For example, select **Deletion pending**, click **Refresh deletion status**, and
expect **Applied response: requested=true** plus **Account deletion requested**.
The fixture returns the selected synthetic response through the real refresh model.
Do not call internal model setters to establish UI success.

## Evidence

Retain `.artifacts/verify-lessmeet/run.XXXXXX/` for Computer Use and
`.artifacts/verify-lessmeet/xcode.XXXXXX/` for XCUITest after teardown. Both are ignored.
XCUITest keeps named actions, screenshots and accessibility text in `Tests.xcresult`.
Open that bundle in Xcode. `identity.json` records app and test source hashes;
`summary.json` records test counts when Xcode produced a readable result.
Capture build command/output, Doctor JSON, UTC action log, before/after accessibility
text and screenshots, expected/observed result, cleanup result and limitations.
For live data, keep only the authorized recording/account scope in private captures.

Exercise each claimed user entry point. A convenient fixture entry does not prove
the Account panel, OAuth, transport, provider deletion, recording or billing.
Observe side effects alongside the UI: saved files/reopen for recording; saved
remote IDs and authorized readback for cloud; server-verified allowance for billing.
Use mocks only at an existing production boundary. Never replace live results with
fixture results. Label skipped and inaccessible paths UNVERIFIED.

For the offline run, inspect `lsof -nP -a -p PID -i` and
`lsof -nP -p PID` for network sockets and recording-store handles after actions.
Save output and exit codes. These are point-in-time checks, not a packet trace or
proof that no transient access occurred. Combine them with the compile-time entry
point and configuration checks; do not trust the word "offline" alone.
Do not read unrelated recording contents or credentials to audit the fixture.

## Cleanup

For XCUITest, each test terminates its own app in teardown. The script checks for
leftover fixture processes and writes `cleanup.txt`. If one remains, inspect its
recorded PID and ownership before terminating it. Do not start Computer Use until
XCUITest has finished. Keep `.xcresult` bundles after failed runs and cleanup.

For Computer Use:

1. Close any fixture dialog with **Cancel** using fresh state.
2. Quit the fixture with `sky.press_key({app: lmApp, key: 'super+q'})`.
3. Poll the exact launch session with `write_stdin` and confirm it exited. If UI
   quit fails, send Control-C (`\u0003`) to that retained PTY session. Never kill
   by process name or signal an unverified PID. Stop and report if it remains alive.
4. Confirm the recorded process is gone with `ps -p PID -o pid=,lstart=,command=`.
5. Check that `doctor.json`, `actions.jsonl` and the captured `.txt`/`.png` files
   still exist. Write `result.md` with proof and limits; release UI ownership in STATUS.

Run cleanup after failed attempts too. Do not remove the evidence, previous bundles,
shared build caches, user recordings or sessions. The fixture's scratch state is
in memory and disappears at process exit. Retain the reusable build in `dist/`.
For live checks, restore reversible UI state and quit only an app this run started;
do not remove created recordings without the required scope and confirmation.

## Helpers

`.agents/skills/verify-lessmeet/scripts/doctor.py` is the executable read-only helper.
The inline `lmCapture` and `lmClick` functions run only inside the installed Node
REPL. `bash scripts/test-ui.sh` runs XCUITest and saves evidence.
`bash scripts/test-ui.sh --build-fixture` is the Xcode build dependency's guarded
entry point to the existing `scripts/build-app.sh offline-check` command.

Maintain the feature map with `$pstack-codex:pstack-maintain-verification-skill`.
The source anchors in its index identify what to review when labels or flows change.
