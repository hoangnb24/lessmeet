import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { googleDeletionTransport, GOOGLE_TRANSPORT_MAX_BYTES, GOOGLE_TRANSPORT_TIMEOUT_MS,
  type GoogleTransportInput, type GoogleAccount } from "../../convex/googleDeletionTransport";

const credential = "synthetic-clerk-secret", token = "synthetic-google-secret";
const account = { externalAccountId: "eac_one", providerUserId: "123456" };
const other = { externalAccountId: "eac_two", providerUserId: "234567" };
const binding = { issuer: "https://synthetic.clerk.accounts.dev", instance: "ins_test", subject: "user_test",
  owner: "https://synthetic.clerk.accounts.dev|user_test", revision: "config_v1", projectRef: "project_v1",
  clientId: "111.apps.googleusercontent.com", authorizedPartyId: "222.apps.googleusercontent.com" };
const instance = { object: "instance", id: binding.instance };
const external = (a: GoogleAccount, provider = "google") => ({ object: "external_account", id: a.externalAccountId,
  provider_user_id: a.providerUserId, provider, verification: { status: "verified" } });
const user = (accounts = [account]) => ({ object: "user", id: binding.subject, external_accounts: accounts.map(a => external(a)) });
const row = (a = account) => ({ object: "oauth_access_token", external_account_id: a.externalAccountId,
  provider_user_id: a.providerUserId, provider: "oauth_google", token });
const info = { sub: account.providerUserId, aud: binding.clientId, azp: binding.authorizedPartyId,
  expires_in: "3600", scope: "openid profile email https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/userinfo.email" };
function setup(operation: GoogleTransportInput["operation"] = "revoke") {
  const transport = vi.fn<GoogleTransportInput["fetch"]>();
  const authorize = vi.fn(async () => true);
  const input: GoogleTransportInput = { enabled: true, binding: { ...binding }, operation, credential, fetch: transport, authorize,
    ...(operation === "revoke" ? { accounts: [{ ...account }], target: { ...account } } : {}) };
  return { input, transport, authorize };
}
type Mock = ReturnType<typeof setup>["transport"];
function queue(transport: Mock, ...bodies: unknown[]) {
  for (const body of bodies) transport.mockResolvedValueOnce(Response.json(body));
}
function ready(transport: Mock) { queue(transport, instance, user(), [row()], info, instance, user()); }
function sanitized(value: unknown) {
  const output = JSON.stringify(value);
  for (const secret of [credential, token, "access_token=", "private-upstream"]) expect(output).not.toContain(secret);
}
beforeEach(() => { vi.stubGlobal("fetch", vi.fn(() => { throw new Error("Real network forbidden"); })); });
afterEach(() => { expect(fetch).not.toHaveBeenCalled(); vi.unstubAllGlobals(); vi.useRealTimers(); });

it.each([undefined, false, "true"])("disabled %s makes no calls", async enabled => {
  const { input, transport, authorize } = setup(); input.enabled = enabled as boolean;
  expect(await googleDeletionTransport(input)).toEqual({ state: "blocked", code: "disabled" });
  expect(transport).not.toHaveBeenCalled(); expect(authorize).not.toHaveBeenCalled();
});
it.each([
  { issuer: "http://invalid.test" }, { issuer: "https://evil.test/path" }, { instance: "ins_test/other" },
  { subject: "user_test?x=y" }, { owner: "wrong" }, { revision: "" }, { projectRef: "bad/ref" },
  { clientId: "" }, { clientId: "https://evil.test" }, { authorizedPartyId: "111.apps.googleusercontent.com/" },
])("invalid binding %j", async patch => {
  const { input, transport } = setup(); input.binding = { ...binding, ...patch };
  expect(await googleDeletionTransport(input)).toMatchObject({ code: "invalid_binding", state: "blocked" });
  expect(transport).not.toHaveBeenCalled();
});
it.each(["operation", "credential", "fetch", "authorize", "emptyAccounts", "duplicateAccounts", "duplicateSubjects", "target", "invalidId", "inventoryTarget"])(
  "invalid input %s has no network", async kind => {
    const { input, transport } = setup();
    if (kind === "operation") input.operation = "delete" as GoogleTransportInput["operation"];
    if (kind === "credential") input.credential = "bad\nsecret";
    if (kind === "fetch") input.fetch = undefined as unknown as GoogleTransportInput["fetch"];
    if (kind === "authorize") input.authorize = undefined as unknown as GoogleTransportInput["authorize"];
    if (kind === "emptyAccounts") input.accounts = [];
    if (kind === "duplicateAccounts") input.accounts = [account, account];
    if (kind === "duplicateSubjects") input.accounts = [account, { ...other, providerUserId: account.providerUserId }];
    if (kind === "target") input.target = other;
    if (kind === "invalidId") input.target = { ...account, externalAccountId: "../eac_one" };
    if (kind === "inventoryTarget") input.operation = "inventory";
    expect(await googleDeletionTransport(input)).toMatchObject({ state: "blocked" }); expect(transport).not.toHaveBeenCalled();
  });
it("inventory sorts Google aliases and ignores non-Google details", async () => {
  const { input, transport, authorize } = setup("inventory");
  queue(transport, instance, { ...user(), external_accounts: [external(other, "oauth_google"),
    { provider: "github", unrelated: "private-upstream" }, { ...external(account), object: "google_account" }] });
  expect(await googleDeletionTransport(input)).toEqual({ state: "inventory", code: "google_inventory_observed", httpStatus: 200, accounts: [account, other] });
  expect(authorize).not.toHaveBeenCalled(); expect(transport).toHaveBeenCalledTimes(2);
});
it("empty inventory is observation only", async () => {
  const { input, transport } = setup("inventory"); queue(transport, instance, user([]));
  expect(await googleDeletionTransport(input)).toEqual({ state: "inventory", code: "google_inventory_observed", httpStatus: 200, accounts: [] });
});
it.each([undefined, null, {}, [null], [{}], [{ provider: "" }], [{ provider: "google_oauth", object: "google_account" }],
  [{ ...external(account), verification: null }], [{ ...external(account), verification: { status: "unverified" } }],
  [{ ...external(account), id: "bad/id" }], [{ ...external(account), provider_user_id: null }],
  [external(account), external(account)], [external(account), external({ ...other, providerUserId: account.providerUserId })],
  Array.from({ length: 17 }, (_, i) => external({ externalAccountId: `eac_${i}`, providerUserId: `${i}` })),
].map(external_accounts => ({ external_accounts })))("malformed or ambiguous inventory blocks (%j)", async ({ external_accounts }) => {
  const { input, transport } = setup("inventory"); queue(transport, instance, { ...user(), external_accounts });
  expect(await googleDeletionTransport(input)).toMatchObject({ state: "blocked" });
});
it.each(["instance", "user"])("rejects %s identity before lookup", async kind => {
  const { input, transport, authorize } = setup();
  queue(transport, kind === "instance" ? { ...instance, id: "ins_other" } : instance, { ...user(), id: "user_other" });
  expect(await googleDeletionTransport(input)).toMatchObject({ code: `${kind}_identity_mismatch`, state: "blocked" });
  expect(authorize).not.toHaveBeenCalled();
});
it.each([[], [other], [account, other]].map(current => ({ current })))("changed expected inventory %j stops before token lookup", async ({ current }) => {
  const { input, transport, authorize } = setup(); queue(transport, instance, user(current));
  expect(await googleDeletionTransport(input)).toMatchObject({ code: "google_inventory_changed" });
  expect(transport).toHaveBeenCalledTimes(2); expect(authorize).not.toHaveBeenCalled();
});
it.each([[], {}, { data: [row()], totalCount: 1 }, Array.from({ length: 32 }, () => row()),
  [row(), row()], [{ ...row(), external_account_id: other.externalAccountId }], [{ ...row(), provider_user_id: other.providerUserId }],
  [{ ...row(), provider: "github" }], [{ ...row(), object: "user" }], [{ ...row(), token: "" }], [{ ...row(), token: "bad\nsecret" }],
  [row(), row(other)], [null],
].map(rows => ({ rows })))("rejects token absence, pagination and identity ambiguity (%j)", async ({ rows }) => {
  const { input, transport } = setup(); queue(transport, instance, user(), rows);
  expect(await googleDeletionTransport(input)).toMatchObject({ state: "blocked" }); expect(transport).toHaveBeenCalledTimes(3);
});
it.each([{ sub: "other" }, { aud: binding.authorizedPartyId }, { azp: binding.clientId }, { aud: null }, { azp: undefined },
  { expires_in: "0" }, { expires_in: -1 }, { expires_in: "Infinity" }, { expires_in: "1e3" },
  { scope: "" }, { scope: "openid https://www.googleapis.com/auth/calendar" }, { scope: "openid\nemail" }])(
  "rejects tokeninfo mismatch or scope (%j)", async patch => {
    const { input, transport } = setup(); queue(transport, instance, user(), [row()], { ...info, ...patch });
    expect(await googleDeletionTransport(input)).toMatchObject({ state: "blocked" }); expect(transport).toHaveBeenCalledTimes(4);
  });
it("acknowledges exact Google POST with separate aud/azp and pinned Clerk routes", async () => {
  const { input, transport, authorize } = setup(); ready(transport); transport.mockResolvedValueOnce(new Response(null));
  const output = await googleDeletionTransport(input);
  expect(output).toEqual({ state: "acknowledgement", code: "google_revoke_acknowledged", httpStatus: 200 }); sanitized(output);
  expect(transport.mock.calls.map(c => c[0])).toEqual([
    "https://api.clerk.com/v1/instance", "https://api.clerk.com/v1/users/user_test",
    "https://api.clerk.com/v1/users/user_test/oauth_access_tokens/oauth_google?paginated=false&limit=32&offset=0",
    `https://oauth2.googleapis.com/tokeninfo?access_token=${token}`,
    "https://api.clerk.com/v1/instance", "https://api.clerk.com/v1/users/user_test", "https://oauth2.googleapis.com/revoke",
  ]);
  for (const [url, init] of transport.mock.calls) {
    expect(init.redirect).toBe("error"); expect(init.signal).toBeInstanceOf(AbortSignal);
    if (url.startsWith("https://api.clerk.com/")) expect(init.headers).toEqual({ Authorization: `Bearer ${credential}`,
      "Clerk-API-Version": "2026-05-12", Accept: "application/json" });
    else expect(init.headers).not.toHaveProperty("Authorization");
  }
  expect(transport.mock.calls[6][1]).toMatchObject({ method: "POST", body: `token=${token}`,
    headers: { "Content-Type": "application/x-www-form-urlencoded" } });
  expect(authorize).toHaveBeenCalledTimes(2);
});
it("client and authorized party may equal; token form encoding is exact", async () => {
  const { input, transport } = setup(); input.binding.authorizedPartyId = binding.clientId;
  const encodedToken = "synthetic+token&value=1";
  queue(transport, instance, user(), [{ ...row(), provider: "google", token: encodedToken }],
    { ...info, azp: binding.clientId, expires_in: 5 }, instance, user());
  transport.mockResolvedValueOnce(new Response(null));
  expect(await googleDeletionTransport(input)).toMatchObject({ state: "acknowledgement" });
  expect(transport.mock.calls[3][0]).toBe(`https://oauth2.googleapis.com/tokeninfo?access_token=${encodeURIComponent(encodedToken)}`);
  expect(transport.mock.calls[6][1].body).toBe(`token=${encodeURIComponent(encodedToken)}`);
});
it("snapshots all caller identity inputs before awaits", async () => {
  const { input, transport } = setup(); ready(transport); transport.mockResolvedValueOnce(new Response(null));
  const pending = googleDeletionTransport(input);
  input.binding.clientId = "changed.apps.googleusercontent.com"; input.target!.providerUserId = "changed";
  input.accounts![0].externalAccountId = "changed"; input.credential = "changed";
  expect(await pending).toMatchObject({ state: "acknowledgement" });
  expect(transport.mock.calls[2][1].headers).toHaveProperty("Authorization", `Bearer ${credential}`);
});
it("matches the target token rather than choosing the first token row", async () => {
  const { input, transport } = setup(); input.accounts = [other, account];
  queue(transport, instance, user([other, account]), [{ ...row(other), token: "other-secret" }, row()], info,
    instance, user([account, other])); transport.mockResolvedValueOnce(new Response(null));
  expect(await googleDeletionTransport(input)).toMatchObject({ state: "acknowledgement" });
  expect(transport.mock.calls[6][1].body).toBe(`token=${token}`);
});
it("known non-target token does not prove target absence or revocation", async () => {
  const { input, transport } = setup(); input.accounts = [account, other];
  queue(transport, instance, user([account, other]), [row(other)]);
  expect(await googleDeletionTransport(input)).toMatchObject({ state: "blocked", code: "google_target_token_missing" });
  expect(transport).toHaveBeenCalledTimes(3);
});
it("exactly 16 Google accounts is a complete bounded inventory", async () => {
  const { input, transport } = setup("inventory");
  const accounts = Array.from({ length: 16 }, (_, i) => ({ externalAccountId: `eac_${i}`, providerUserId: `${i}` }));
  queue(transport, instance, user(accounts));
  expect(await googleDeletionTransport(input)).toMatchObject({ state: "inventory", accounts: expect.any(Array) });
});
it.each(["token", "revoke"])("withdrawn authorization before %s prevents dispatch", async phase => {
  const { input, transport, authorize } = setup(); ready(transport);
  if (phase === "revoke") authorize.mockResolvedValueOnce(true);
  authorize.mockResolvedValueOnce(false);
  expect(await googleDeletionTransport(input)).toEqual({ state: "blocked", code: "authorization_withdrawn" });
  expect(transport).toHaveBeenCalledTimes(phase === "token" ? 2 : 6);
});
it("authorization is the final async prerequisite before token GET and POST", async () => {
  const { input, transport } = setup(); const events: string[] = [];
  const bodies = [instance, user(), [row()], info, instance, user()];
  input.authorize = async () => { events.push("authorize"); return true; };
  transport.mockImplementation(async (_url, init) => { events.push(init.method!); return bodies.length ? Response.json(bodies.shift()) : new Response(null); });
  expect(await googleDeletionTransport(input)).toMatchObject({ state: "acknowledgement" });
  expect(events).toEqual(["GET", "GET", "authorize", "GET", "GET", "GET", "GET", "authorize", "POST"]);
});
it("authorization exception is sanitized", async () => {
  const { input, transport, authorize } = setup(); queue(transport, instance, user());
  authorize.mockRejectedValueOnce(new Error(`${credential} ${token}`));
  const output = await googleDeletionTransport(input); expect(output).toEqual({ state: "blocked", code: "authorization_check_failed" }); sanitized(output);
});
it("final metadata inventory change prevents POST", async () => {
  const { input, transport, authorize } = setup(); queue(transport, instance, user(), [row()], info, instance, user([account, other]));
  expect(await googleDeletionTransport(input)).toMatchObject({ code: "google_inventory_changed", state: "blocked" });
  expect(authorize).toHaveBeenCalledTimes(1); expect(transport).toHaveBeenCalledTimes(6);
});
it.each([400, 401, 404, 422, 429, 500])("refresh lookup failure %s never retries or succeeds", async status => {
  const { input, transport } = setup(); queue(transport, instance, user());
  transport.mockResolvedValueOnce(Response.json({ error: `${credential} ${token}` }, { status }));
  const output = await googleDeletionTransport(input);
  expect(output).toMatchObject({ state: status >= 500 || status === 429 ? "unknown" : "blocked", code: "google_token_lookup_failed", httpStatus: status });
  sanitized(output); expect(transport).toHaveBeenCalledTimes(3);
});
it.each([400, 429, 503, "throw"])("tokeninfo unavailable %s fails closed", async status => {
  const { input, transport } = setup(); queue(transport, instance, user(), [row()]);
  if (status === "throw") transport.mockRejectedValueOnce(new Error(`private-upstream ${token}`));
  else transport.mockResolvedValueOnce(new Response(null, { status: status as number }));
  const output = await googleDeletionTransport(input); expect(output).toMatchObject({ state: "blocked", code: "google_tokeninfo_unavailable" });
  sanitized(output); expect(transport).toHaveBeenCalledTimes(4);
});
it.each([204, 302, 400, 401, 404, 408, 429, 500, 503])("Google POST status %s is never acknowledgement", async status => {
  const { input, transport } = setup(); ready(transport); transport.mockResolvedValueOnce(new Response(null, { status }));
  const output = await googleDeletionTransport(input);
  expect(output).toMatchObject({ state: status === 408 || status === 429 || status >= 500 ? "unknown" : "blocked", code: "google_revoke_rejected", httpStatus: status });
  sanitized(output); expect(transport).toHaveBeenCalledTimes(7);
});
it("lost POST response stays unknown without replay or leaked error", async () => {
  const { input, transport } = setup(); ready(transport);
  transport.mockRejectedValueOnce(new Error(`https://oauth2.googleapis.com/revoke?token=${token} ${credential}`));
  const output = await googleDeletionTransport(input); expect(output).toEqual({ state: "unknown", code: "transport_unknown" });
  sanitized(output); expect(transport).toHaveBeenCalledTimes(7);
});
it.each([0, 1, 2, 4, 5])("network failure at Clerk call %s is sanitized and not replayed", async call => {
  const { input, transport } = setup(); queue(transport, ...[instance, user(), [row()], info, instance, user()].slice(0, call));
  transport.mockRejectedValueOnce(new Error(`private-upstream ${token} ${credential}`));
  const output = await googleDeletionTransport(input); expect(output).toEqual({ state: "unknown", code: "transport_unknown" });
  sanitized(output); expect(transport).toHaveBeenCalledTimes(call + 1);
});
it.each([400, 404, 429, 503])("metadata HTTP %s cannot prove absence or completion", async status => {
  const { input, transport } = setup("inventory"); queue(transport, instance);
  transport.mockResolvedValueOnce(Response.json({ errors: [{ code: "resource_not_found", message: token }] }, { status }));
  const output = await googleDeletionTransport(input);
  expect(output).toMatchObject({ state: status === 429 || status >= 500 ? "unknown" : "blocked", code: "provider_rejected", httpStatus: status });
  sanitized(output);
});
it.each([0, 2, 3])("malformed JSON at call %s blocks", async call => {
  const { input, transport } = setup();
  queue(transport, ...[instance, user(), [row()], info].slice(0, call));
  transport.mockResolvedValueOnce(new Response(`private-upstream ${token}`));
  const output = await googleDeletionTransport(input); expect(output).toMatchObject({ state: "blocked", code: "malformed_response" }); sanitized(output);
});
it("caps total response bytes across calls", async () => {
  const { input, transport } = setup("inventory");
  transport.mockResolvedValueOnce(Response.json({ ...instance, padding: "x".repeat(40_000) }));
  transport.mockResolvedValueOnce(Response.json({ ...user(), padding: "x".repeat(30_000) }));
  expect(await googleDeletionTransport(input)).toMatchObject({ state: "blocked", code: "response_too_large" });
});
it("cancels oversized streamed response", async () => {
  const { input, transport } = setup(); const cancel = vi.fn(); let chunks = 0;
  transport.mockResolvedValueOnce(new Response(new ReadableStream({ pull(c) { chunks++; c.enqueue(new Uint8Array(8192)); }, cancel })));
  expect(await googleDeletionTransport(input)).toMatchObject({ state: "blocked", code: "response_too_large" });
  expect(cancel).toHaveBeenCalled(); expect(chunks).toBeLessThanOrEqual(GOOGLE_TRANSPORT_MAX_BYTES / 8192 + 2);
});
it("oversized POST response is not reported as acknowledgement", async () => {
  const { input, transport } = setup(); ready(transport); transport.mockResolvedValueOnce(new Response("x".repeat(GOOGLE_TRANSPORT_MAX_BYTES)));
  expect(await googleDeletionTransport(input)).toMatchObject({ state: "blocked", code: "response_too_large" });
  expect(transport).toHaveBeenCalledTimes(7);
});
it("wall-clock deadline prevents dispatch even before the timer callback runs", async () => {
  vi.useFakeTimers(); const { input, transport } = setup(); queue(transport, instance, user());
  input.authorize = async () => { vi.setSystemTime(Date.now() + GOOGLE_TRANSPORT_TIMEOUT_MS); return true; };
  expect(await googleDeletionTransport(input)).toEqual({ state: "unknown", code: "transport_timeout" });
  expect(transport).toHaveBeenCalledTimes(2);
});
it.each(["fetch", "body", "tokenLookup", "tokeninfo", "tokenAuthorization", "revokeAuthorization", "post"])("deadline during %s prevents late dispatch", async hang => {
  vi.useFakeTimers(); const { input, transport } = setup(); let release: ((value: any) => void) | undefined;
  if (hang === "fetch") transport.mockImplementationOnce(() => new Promise(resolve => { release = resolve; }));
  if (hang === "body") transport.mockResolvedValueOnce(new Response(new ReadableStream({ start() {} })));
  if (hang === "tokenLookup") { queue(transport, instance, user()); transport.mockImplementationOnce(() => new Promise(resolve => { release = resolve; })); }
  if (hang === "tokeninfo") { queue(transport, instance, user(), [row()]); transport.mockImplementationOnce(() => new Promise(resolve => { release = resolve; })); }
  if (hang === "tokenAuthorization") { queue(transport, instance, user()); input.authorize = () => new Promise(resolve => { release = resolve; }); }
  if (hang === "revokeAuthorization") { ready(transport); let calls = 0; input.authorize = () => ++calls === 1 ? Promise.resolve(true) : new Promise(resolve => { release = resolve; }); }
  if (hang === "post") { ready(transport); transport.mockImplementationOnce(() => new Promise(resolve => { release = resolve; })); }
  const pending = googleDeletionTransport(input); await vi.advanceTimersByTimeAsync(GOOGLE_TRANSPORT_TIMEOUT_MS);
  const output = await pending; expect(output).toEqual({ state: "unknown", code: "transport_timeout" }); sanitized(output);
  const calls = transport.mock.calls.length; expect(transport.mock.calls[0][1].signal?.aborted).toBe(true);
  release?.(hang === "fetch" ? Response.json(instance) : hang === "tokenLookup" ? Response.json([row()]) :
    hang === "tokeninfo" ? Response.json(info) : hang === "post" ? new Response(null) : true);
  await vi.advanceTimersByTimeAsync(1); expect(transport).toHaveBeenCalledTimes(calls);
  expect(transport.mock.calls.filter(c => c[1].method === "POST")).toHaveLength(hang === "post" ? 1 : 0);
});
