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
2. Read the installed `computer-use` skill before using its runtime. Discover
   its current location from the plugin catalog; do not pin a cache version.
3. Identify the approved bundle, build identity, environment and allowed actions.
   Opening Account can itself send a status request. A state read can launch
   the app. Do not assume that observing a production app is network-free.

## Observe, act, verify

Use `mcp__node_repl__js` and the installed `@oai/sky` runtime. Import once per
fresh session, then get the app state:

```js
var sky = (await import('@oai/sky')).sky;
var lmApp = '/absolute/path/to/the/approved/LessMeet.app';
var before = await sky.get_app_state({app: lmApp});
nodeRepl.write(before.text);
```

Choose an authorized action from the current accessibility tree. Replace
`observedIndex` below with its actual index; never guess or reuse a stale index.

```js
var startedAt = new Date().toISOString();
await sky.click({app: lmApp, element_index: observedIndex});
var after = await sky.get_app_state({app: lmApp});
nodeRepl.write(after.text);
```

Inspect a screenshot for visible layout or rendering claims:

```js
var fs = await import('node:fs/promises');
var url = await import('node:url');
if (after.screenshot) {
  await nodeRepl.emitImage({
    bytes: await fs.readFile(url.fileURLToPath(after.screenshot.url)),
    mimeType: 'image/png'
  });
}
```

Fetch fresh state after each action before choosing the next control. The runtime
can wait for loading to settle; a final snapshot cannot prove a brief spinner
appeared. For a tool smoke check, hide and restore the sidebar rather than opening
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

If the tool, skill, permissions, ownership or action authority is unavailable,
report the exact blocker and mark the affected behavior UNVERIFIED. Ask Human
only for the missing permission or unavailable action. Do not bypass permissions
or silently install another automation stack. An approved limitation is not a pass.

This skill grants no additional authority for deletion, production writes,
uploads, recording, paid calls or account changes. Follow the installed Computer
Use skill's action-time confirmation rules for risky actions.
