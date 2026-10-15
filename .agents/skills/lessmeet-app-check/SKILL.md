---
name: lessmeet-app-check
description: Verify the running LessMeet macOS app with Computer Use when diagnosing visible behavior, checking native UI changes, or accepting user-facing app flows. Not for code-only explanations or backend-only checks.
---

# LessMeet app check

Verify the requested behavior on the exact app artifact. Keep observed UI,
backend evidence and unverified claims separate. Respect a Human-imposed
code-only scope; do not operate the app in that case.

## Prepare

1. Read `docs/WORKSPACE_PROTOCOL.md` and current ownership in `docs/STATUS.md`.
   Lead owns or delegates one live UI scope. Supervisor routes checks through
   Lead. A read-only Peer requests evidence rather than operating the shared UI.
2. Check the tools exposed in the current session. For `mcp__cua_repl__js`,
   read its supplied instructions and the API documentation it returns. A
   separate installed `computer-use` skill is not required for this tool.
   Do not infer tool availability from cached plugins or enabled settings.
3. Identify the approved bundle, build identity, environment and allowed actions.
   Opening Account can itself send a status request. A state read can launch
   the app. Do not assume that observing a production app is network-free.

## Observe, act, verify

Use `mcp__cua_repl__js` for the current Computer Use workflow. In a fresh
session, make exactly one entry-point call to select the approved app:

```js
var lmApp = await cua.getApp('/absolute/path/to/the/approved/LessMeet.app');
```

This call returns API documentation and the initial app state. Read both before
continuing. Do not add clicks, waits, snapshots or other API calls to this first
invocation. Use only methods and arguments described by the tool or its returned
documentation. After a context reset, call `await cua.rewriteDocumentation()`
before continuing an existing Computer Use session.

1. Choose an authorized action from the current app state.
2. Use the documented app API to perform that action. Never guess a control
   identifier or reuse a stale one.
3. Fetch fresh state using the documented API before choosing another control.
4. For layout or rendering claims, inspect a screenshot using the documented
   capture and image-output APIs.

Do not import `@oai/sky` or copy older `sky.get_app_state(...)` examples into
`cua_repl`. If a session exposes only the older `mcp__node_repl__js` tool, read
its installed Computer Use skill before using that older workflow. If those
instructions are missing, report that specific blocker. An empty older skill
directory alone does not block a documented `cua_repl` workflow.

A final snapshot cannot prove that a brief spinner appeared. Use the documented
wait or observation methods when the scenario requires evidence during loading. For a tool smoke check, hide and restore the sidebar rather than opening
recordings or triggering cloud work.

## Evidence and limits

Report the bundle/build identity, scenario, UTC interval, expected versus observed
result, evidence location and remaining unknowns. Restore reversible changes.
Lead records acceptance and releases live UI ownership in `docs/STATUS.md`.
Keep needed private captures under ignored `.artifacts/`; do not commit or upload
raw screenshots or accessibility output containing account or recording details.

Build success, tests and HTTP 200 do not establish working UI. For example,
Refresh may receive `requested=false` without displaying a success message.
Server logs alone do not prove that the app applied that response. Report missing
click/request/applied-state correlation instead of inferring it. Do not repeat
clicks, or ask Human to repeat them, without a new evidence collection path.

If the tool, required API instructions, permissions, ownership or action authority
is unavailable, report the exact blocker and mark the affected behavior
UNVERIFIED. Ask Human
only for the missing permission or unavailable action. Do not bypass permissions
or silently install another automation stack. An approved limitation is not a pass.

This skill grants no additional authority for deletion, production writes,
uploads, recording, paid calls or account changes. Follow the current Computer
Use tool's supplied action-time confirmation rules for risky actions.
