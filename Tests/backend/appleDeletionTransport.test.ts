import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { appleDeletionTransport, APPLE_TRANSPORT_TIMEOUT_MS, APPLE_TRANSPORT_MAX_BYTES,
  type AppleTransportInput } from "../../convex/appleDeletionTransport";

const now = 1_800_000_000_000;
const binding = { issuer: "https://synthetic.clerk.accounts.dev", instance: "ins_test", subject: "user_test",
  owner: "https://synthetic.clerk.accounts.dev|user_test", revision: "config_v1", clientId: "com.synthetic.signin",
  teamId: "TEAM123456", keyId: "KEY1234567", externalAccountId: "eac_test", providerUserId: "apple.synthetic",
  provenanceEvidence: "case_v1" };
const account = { object: "external_account", id: "eac_test", provider: "apple", provider_user_id: "apple.synthetic",
  verification: { status: "verified", strategy: "oauth_apple" } };
const user = { object: "user", id: "user_test", external_accounts: [account] };
const instance = { object: "instance", id: "ins_test" };
const token = { object: "oauth_access_token", external_account_id: "eac_test", provider_user_id: "apple.synthetic",
  provider: "apple", token: "synthetic-access&=token", expires_at: now + 3_600_000, public_metadata: {}, label: null };
const encode = (x: unknown) => Buffer.from(JSON.stringify(x)).toString("base64url");
function secret(h: Record<string, unknown> = {}, p: Record<string, unknown> = {}) {
  return `${encode({ alg: "ES256", kid: binding.keyId, ...h })}.${encode({ iss: binding.teamId, sub: binding.clientId,
    aud: "https://appleid.apple.com", iat: now / 1000, exp: now / 1000 + 3600, ...p })}.${Buffer.alloc(64, 1).toString("base64url")}`;
}
function setup() {
  const transport = vi.fn<AppleTransportInput["fetch"]>();
  const authorize = vi.fn(async () => true);
  const input: AppleTransportInput = { enabled: true, binding: { ...binding }, clerkCredential: "synthetic-clerk-secret",
    clientSecret: secret(), fetch: transport, authorize };
  return { input, transport, authorize };
}
function queue(t: ReturnType<typeof setup>["transport"], u: unknown = user, tokens: unknown = [token]) {
  t.mockResolvedValueOnce(Response.json(instance)).mockResolvedValueOnce(Response.json(u))
    .mockResolvedValueOnce(Response.json(tokens)).mockResolvedValueOnce(new Response(null, { status: 200 }));
}
beforeEach(() => { vi.useFakeTimers(); vi.setSystemTime(now); vi.stubGlobal("fetch", vi.fn(() => { throw Error("Network forbidden"); })); });
afterEach(() => { expect(fetch).not.toHaveBeenCalled(); vi.unstubAllGlobals(); vi.useRealTimers(); });
it("acknowledges exact form request without returning secrets or completion", async () => {
  const { input, transport, authorize } = setup(); queue(transport);
  const r = await appleDeletionTransport(input);
  expect(r).toEqual({ state: "acknowledgement", code: "apple_revocation_acknowledged", httpStatus: 200 });
  expect(transport.mock.calls.map(c => c[0])).toEqual(["https://api.clerk.com/v1/instance",
    "https://api.clerk.com/v1/users/user_test", "https://api.clerk.com/v1/users/user_test/oauth_access_tokens/oauth_apple?limit=2&offset=0&paginated=false",
    "https://appleid.apple.com/auth/revoke"]);
  for (const [, init] of transport.mock.calls.slice(0, 3)) expect(init).toMatchObject({ method: "GET", redirect: "error",
    headers: { Authorization: `Bearer ${input.clerkCredential}`, "Clerk-API-Version": "2026-05-12" } });
  const post = transport.mock.calls[3][1];
  expect(post).toMatchObject({ method: "POST", redirect: "error", headers: { "Content-Type": "application/x-www-form-urlencoded" } });
  expect(Object.fromEntries(new URLSearchParams(post.body as string))).toEqual({ client_id: binding.clientId,
    client_secret: input.clientSecret, token: token.token, token_type_hint: "access_token" });
  expect(authorize.mock.calls).toEqual([[], []]);
  expect(JSON.stringify(r)).not.toMatch(/synthetic|token|complete/);
});
it.each([undefined, false, "true"])("disabled %s makes no calls", async enabled => {
  const { input, transport } = setup(); input.enabled = enabled as boolean;
  expect(await appleDeletionTransport(input)).toEqual({ state: "blocked", code: "disabled" }); expect(transport).not.toHaveBeenCalled();
});
it.each([{ owner: "wrong" }, { issuer: "http://wrong" }, { issuer: "https://a/path" }, { instance: "ins_/x" },
  { subject: "user_x?y" }, { revision: "" }, { provenanceEvidence: "" }, { clientId: "com.x?y" },
  { teamId: "bad" }, { keyId: "bad" }, { externalAccountId: "../x" }, { providerUserId: "" }])("invalid binding %j", async patch => {
  const { input, transport } = setup(); input.binding = { ...binding, ...patch };
  expect(await appleDeletionTransport(input)).toMatchObject({ code: "invalid_binding" }); expect(transport).not.toHaveBeenCalled();
});
it.each([{ alg: "HS256" }, { kid: "OTHER12345" }, { crit: ["b64"] }])("invalid secret header %j", async h => {
  const { input, transport } = setup(); input.clientSecret = secret(h);
  expect(await appleDeletionTransport(input)).toMatchObject({ code: "invalid_client_secret" }); expect(transport).not.toHaveBeenCalled();
});
it.each([{ iss: "OTHER12345" }, { sub: "com.other" }, { aud: ["https://appleid.apple.com"] }, { iat: now / 1000 + 1 },
  { exp: now / 1000 + 60 }, { exp: now / 1000 + 15_777_001 }, { iat: "1800000000" }, { exp: null }])("invalid secret claims %j", async p => {
  const { input, transport } = setup(); input.clientSecret = secret({}, p);
  expect(await appleDeletionTransport(input)).toMatchObject({ code: "invalid_client_secret" }); expect(transport).not.toHaveBeenCalled();
});
it.each(["", "a.b.c", "a.b", `${encode({})}.${encode({})}.!`, "x".repeat(8193)])("malformed secret %s", async value => {
  const { input, transport } = setup(); input.clientSecret = value;
  expect(await appleDeletionTransport(input)).toMatchObject({ state: "blocked" }); expect(transport).not.toHaveBeenCalled();
});
it.each([[], [account, account], [{ ...account, id: "eac_other" }], [{ ...account, provider_user_id: "other" }],
  [{ ...account, verification: null }], [{ ...account, verification: { status: "unverified", strategy: "oauth_apple" } }],
  [{ ...account, verification: { status: "verified", strategy: "oauth_token_apple" } }], [null]].map(accounts => ({ accounts })))("rejects links %j", async ({ accounts }) => {
  const { input, transport, authorize } = setup(); queue(transport, { ...user, external_accounts: accounts });
  expect(await appleDeletionTransport(input)).toMatchObject({ state: "blocked" });
  expect(transport).toHaveBeenCalledTimes(2); expect(authorize).not.toHaveBeenCalled();
});
it.each([[], [token, token], { data: [token] }, [null], [{ ...token, token: undefined, id_token: "not-access" }],
  [{ ...token, external_account_id: "eac_other" }], [{ ...token, provider_user_id: "other" }], [{ ...token, provider: "google" }],
  [{ ...token, public_metadata: null }], [{ ...token, scopes: [42] }], [{ ...token, label: undefined }],
  [{ ...token, token_secret: "wrong" }], [{ ...token, token: "" }]].map(tokens => ({ tokens })))("rejects tokens %j", async ({ tokens }) => {
  const { input, transport } = setup(); queue(transport, user, tokens);
  expect(await appleDeletionTransport(input)).toMatchObject({ state: "blocked" }); expect(transport).toHaveBeenCalledTimes(3);
});
it.each([null, undefined, -1, 1.5, now / 1000 - 1, now / 1000 + 3600, now - 1, now + 60_000])("fails closed expiry %s", async expires_at => {
  const { input, transport } = setup(); queue(transport, user, [{ ...token, expires_at }]);
  expect(await appleDeletionTransport(input)).toMatchObject({ state: "blocked" }); expect(transport).toHaveBeenCalledTimes(3);
});
it.each([0, 1])("withdrawn authorization at boundary %s", async boundary => {
  const { input, transport, authorize } = setup(); queue(transport);
  if (boundary) authorize.mockResolvedValueOnce(true);
  authorize.mockResolvedValueOnce(false);
  expect(await appleDeletionTransport(input)).toMatchObject({ code: "authorization_withdrawn" });
  expect(transport).toHaveBeenCalledTimes(2 + boundary);
});
it.each([0, 1, 2])("404 at GET %s never succeeds", async step => {
  const { input, transport } = setup();
  for (const b of [instance, user].slice(0, step)) transport.mockResolvedValueOnce(Response.json(b));
  transport.mockResolvedValueOnce(Response.json({ errors: [{ code: "resource_not_found", message: token.token }] }, { status: 404 }));
  expect(await appleDeletionTransport(input)).toEqual({ state: "blocked", code: "clerk_response_rejected", httpStatus: 404 });
  expect(transport).toHaveBeenCalledTimes(step + 1);
});
it.each(["{}", " ", "private error"])("nonempty Apple 200 %s is unknown", async body => {
  const { input, transport } = setup(); queue(transport); transport.mockReset();
  transport.mockResolvedValueOnce(Response.json(instance)).mockResolvedValueOnce(Response.json(user))
    .mockResolvedValueOnce(Response.json([token])).mockResolvedValueOnce(new Response(body));
  expect(await appleDeletionTransport(input)).toEqual({ state: "unknown", code: "apple_acknowledgement_body_unexpected", httpStatus: 200 });
});
it.each([400, 401, 404, 429, 500, 204, 302])("Apple status %s never completes", async status => {
  const { input, transport } = setup();
  transport.mockResolvedValueOnce(Response.json(instance)).mockResolvedValueOnce(Response.json(user))
    .mockResolvedValueOnce(Response.json([token])).mockResolvedValueOnce(new Response(null, { status }));
  expect(await appleDeletionTransport(input)).toEqual({ state: status === 400 ? "blocked" : "unknown", code: "apple_response_rejected", httpStatus: status });
  expect(transport).toHaveBeenCalledTimes(4);
});
it("snapshots mutable binding, credentials and callbacks", async () => {
  const { input, transport, authorize } = setup(); queue(transport);
  const originalSecret = input.clientSecret;
  authorize.mockImplementationOnce(async () => {
    Object.assign(input.binding, { clientId: "com.other", externalAccountId: "eac_other", owner: "other" });
    input.clientSecret = "changed"; input.clerkCredential = "changed";
    input.fetch = async () => { throw Error("changed"); }; input.authorize = async () => false;
    return true;
  });
  expect(await appleDeletionTransport(input)).toMatchObject({ state: "acknowledgement" });
  expect(new URLSearchParams(transport.mock.calls[3][1].body as string).get("client_secret")).toBe(originalSecret);
  expect(authorize).toHaveBeenCalledTimes(2);
});
it.each([0, 1])("late authorization %s cannot dispatch subsequent calls", async boundary => {
  const { input, transport, authorize } = setup(); queue(transport);
  let release!: (v: boolean) => void;
  if (boundary) authorize.mockResolvedValueOnce(true);
  authorize.mockImplementationOnce(() => new Promise(resolve => { release = resolve; }));
  const pending = appleDeletionTransport(input);
  await vi.advanceTimersByTimeAsync(APPLE_TRANSPORT_TIMEOUT_MS);
  expect(await pending).toEqual({ state: "unknown", code: "transport_timeout" });
  release(true); await vi.advanceTimersByTimeAsync(1);
  expect(transport).toHaveBeenCalledTimes(2 + boundary);
});
it("post timeout stays unknown with no retry", async () => {
  const { input, transport } = setup();
  transport.mockResolvedValueOnce(Response.json(instance)).mockResolvedValueOnce(Response.json(user))
    .mockResolvedValueOnce(Response.json([token])).mockImplementationOnce(() => new Promise(() => {}));
  const pending = appleDeletionTransport(input); await vi.advanceTimersByTimeAsync(APPLE_TRANSPORT_TIMEOUT_MS);
  expect(await pending).toEqual({ state: "unknown", code: "transport_timeout" }); expect(transport).toHaveBeenCalledTimes(4);
  expect(transport.mock.calls[3][1].signal?.aborted).toBe(true);
});
it("late GET cannot reach token retrieval or POST", async () => {
  const { input, transport } = setup(); let release!: (r: Response) => void;
  transport.mockImplementationOnce(() => new Promise(resolve => { release = resolve; }));
  const pending = appleDeletionTransport(input); await vi.advanceTimersByTimeAsync(APPLE_TRANSPORT_TIMEOUT_MS);
  expect(await pending).toMatchObject({ state: "unknown" }); release(Response.json(instance));
  await vi.advanceTimersByTimeAsync(1); expect(transport).toHaveBeenCalledTimes(1);
});
it("body read is bounded by cumulative deadline", async () => {
  const { input, transport } = setup();
  transport.mockResolvedValueOnce(new Response(new ReadableStream({ start() {} })));
  const pending = appleDeletionTransport(input); await vi.advanceTimersByTimeAsync(APPLE_TRANSPORT_TIMEOUT_MS);
  expect(await pending).toMatchObject({ code: "transport_timeout" }); expect(transport).toHaveBeenCalledTimes(1);
});
it("cumulative response bytes cannot exceed 64KiB", async () => {
  const { input, transport } = setup();
  transport.mockResolvedValueOnce(Response.json({ ...instance, ignored: "x".repeat(APPLE_TRANSPORT_MAX_BYTES - 100) }))
    .mockResolvedValueOnce(Response.json(user));
  expect(await appleDeletionTransport(input)).toMatchObject({ code: "response_too_large" }); expect(transport).toHaveBeenCalledTimes(2);
});
it("does not return thrown secrets", async () => {
  const { input, transport } = setup(); transport.mockRejectedValueOnce(Error(input.clientSecret + token.token));
  expect(await appleDeletionTransport(input)).toEqual({ state: "unknown", code: "transport_unknown" });
});
it.each(["credential", "fetch", "authorize"])("rejects missing dependency %s", async dependency => {
  const { input, transport } = setup();
  if (dependency === "credential") input.clerkCredential = "secret\nvalue";
  if (dependency === "fetch") input.fetch = undefined as unknown as AppleTransportInput["fetch"];
  if (dependency === "authorize") input.authorize = undefined as unknown as AppleTransportInput["authorize"];
  expect(await appleDeletionTransport(input)).toMatchObject({ state: "blocked" }); expect(transport).not.toHaveBeenCalled();
});
it.each(["instance", "user"])("rejects mismatched %s", async target => {
  const { input, transport } = setup();
  transport.mockResolvedValueOnce(Response.json(target === "instance" ? { ...instance, id: "ins_other" } : instance));
  if (target === "user") transport.mockResolvedValueOnce(Response.json({ ...user, id: "user_other" }));
  expect(await appleDeletionTransport(input)).toMatchObject({ state: "blocked" });
  expect(transport).toHaveBeenCalledTimes(target === "instance" ? 1 : 2);
});
it("client secret expiring during authorization prevents token GET", async () => {
  const { input, transport, authorize } = setup(); queue(transport);
  input.clientSecret = secret({}, { exp: now / 1000 + 65 });
  authorize.mockImplementationOnce(async () => { vi.setSystemTime(now + 6000); return true; });
  expect(await appleDeletionTransport(input)).toMatchObject({ code: "invalid_client_secret" }); expect(transport).toHaveBeenCalledTimes(2);
});
it("token expiry is rechecked after the final authorization", async () => {
  const { input, transport, authorize } = setup(); queue(transport, user, [{ ...token, expires_at: now + 65_000 }]);
  authorize.mockResolvedValueOnce(true).mockImplementationOnce(async () => { vi.setSystemTime(now + 6000); return true; });
  expect(await appleDeletionTransport(input)).toMatchObject({ code: "token_expiry_units_unverified" }); expect(transport).toHaveBeenCalledTimes(3);
});
it("cumulative callback delays share one deadline", async () => {
  const { input, transport, authorize } = setup(); queue(transport);
  authorize.mockImplementation(() => new Promise(resolve => setTimeout(() => resolve(true), 11_000)));
  const pending = appleDeletionTransport(input); await vi.advanceTimersByTimeAsync(20_000);
  expect(await pending).toMatchObject({ code: "transport_timeout" });
  await vi.advanceTimersByTimeAsync(3000); expect(transport).toHaveBeenCalledTimes(3);
});
it("thrown authorization error is sanitized", async () => {
  const { input, transport, authorize } = setup(); queue(transport);
  authorize.mockRejectedValueOnce(Error(input.clientSecret));
  expect(await appleDeletionTransport(input)).toEqual({ state: "blocked", code: "authorization_check_failed" });
  expect(transport).toHaveBeenCalledTimes(2);
});
it.each(["not JSON", "[]", "null"])("malformed instance %s blocks", async raw => {
  const { input, transport } = setup(); transport.mockResolvedValueOnce(new Response(raw));
  expect(await appleDeletionTransport(input)).toMatchObject({ state: "blocked" }); expect(transport).toHaveBeenCalledTimes(1);
});
it("invalid UTF8 blocks before subsequent calls", async () => {
  const { input, transport } = setup(); transport.mockResolvedValueOnce(new Response(new Uint8Array([255])));
  expect(await appleDeletionTransport(input)).toMatchObject({ code: "malformed_response" }); expect(transport).toHaveBeenCalledTimes(1);
});
it("Apple body timeout remains unknown", async () => {
  const { input, transport } = setup();
  transport.mockResolvedValueOnce(Response.json(instance)).mockResolvedValueOnce(Response.json(user))
    .mockResolvedValueOnce(Response.json([token])).mockResolvedValueOnce(new Response(new ReadableStream({ start() {} })));
  const pending = appleDeletionTransport(input); await vi.advanceTimersByTimeAsync(20_000);
  expect(await pending).toMatchObject({ state: "unknown", code: "transport_timeout" }); expect(transport).toHaveBeenCalledTimes(4);
});
