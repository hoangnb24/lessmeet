import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { clerkDeletionTransport, CLERK_TRANSPORT_MAX_BYTES, CLERK_TRANSPORT_TIMEOUT_MS,
  type ClerkTransportInput, type ClerkOperation } from "../../convex/clerkDeletionTransport";

const binding = { issuer: "https://synthetic.clerk.accounts.dev", instance: "ins_test", subject: "user_test",
  owner: "https://synthetic.clerk.accounts.dev|user_test", revision: "config_v1" };
const instance = { object: "instance", id: "ins_test" };
const user = { object: "user", id: "user_test" };
const session = { object: "session", id: "sess_test", user_id: "user_test", status: "active" };
const missing = { errors: [{ code: "resource_not_found", message: "private upstream value" }] };
function setup(operation: ClerkOperation = "deleteUser") {
  const transport = vi.fn<ClerkTransportInput["fetch"]>();
  const authorize = vi.fn(async () => true);
  const input: ClerkTransportInput = { enabled: true, binding: { ...binding }, operation,
    ...(operation.includes("Session") ? { sessionId: "sess_test" } : {}), credential: "synthetic-secret",
    fetch: transport, appleDispositionRevision: "apple_v1", authorize };
  return { input, transport, authorize };
}
function queue(transport: ReturnType<typeof setup>["transport"], ...bodies: unknown[]) {
  for (const body of bodies) transport.mockResolvedValueOnce(Response.json(body));
}
beforeEach(() => { vi.stubGlobal("fetch", vi.fn(() => { throw new Error("Real network forbidden"); })); });
afterEach(() => { expect(fetch).not.toHaveBeenCalled(); vi.unstubAllGlobals(); vi.useRealTimers(); });

it.each([undefined, false, "true"])("disabled input %s makes zero calls", async enabled => {
  const { input, transport, authorize } = setup();
  input.enabled = enabled as boolean;
  expect(await clerkDeletionTransport(input)).toEqual({ state: "blocked", code: "disabled" });
  expect(transport).not.toHaveBeenCalled(); expect(authorize).not.toHaveBeenCalled();
});
it.each([
  { issuer: "http://synthetic.clerk.accounts.dev" }, { issuer: "https://evil.test/path" },
  { instance: "ins_bad/route" }, { subject: "user_bad?key=x" }, { subject: "other" },
  { owner: "https://other.test|user_test" }, { revision: "" }, { revision: "bad/revision" },
])("invalid binding %j makes zero calls", async patch => {
  const { input, transport } = setup(); input.binding = { ...binding, ...patch };
  expect(await clerkDeletionTransport(input)).toMatchObject({ state: "blocked", code: "invalid_binding" });
  expect(transport).not.toHaveBeenCalled();
});
it.each(["../sess_test", "sess_test?x=y", "sess_", "sess_bad/path"])("rejects session route %s", async sessionId => {
  const { input, transport } = setup("revokeSession"); input.sessionId = sessionId;
  expect(await clerkDeletionTransport(input)).toMatchObject({ code: "invalid_target" }); expect(transport).not.toHaveBeenCalled();
});
it.each(["apple", "callback", "credential", "transport", "operation", "extraSession"])("missing/invalid %s has no network", async bad => {
  const { input, transport } = setup();
  if (bad === "apple") input.appleDispositionRevision = undefined;
  if (bad === "callback") input.authorize = undefined;
  if (bad === "credential") input.credential = "bad\nsecret";
  if (bad === "transport") input.fetch = undefined as unknown as ClerkTransportInput["fetch"];
  if (bad === "operation") input.operation = "banUser" as ClerkOperation;
  if (bad === "extraSession") input.sessionId = "sess_test";
  expect(await clerkDeletionTransport(input)).toMatchObject({ state: "blocked" }); expect(transport).not.toHaveBeenCalled();
});
it.each(["verifyInstance", "getUser", "getSession", "deleteUser", "revokeSession"] as const)("%s exact wire, pinned version, no body/retries", async operation => {
  const { input, transport, authorize } = setup(operation);
  const isSession = operation.includes("Session");
  queue(transport, instance, isSession ? session : user, isSession ? { ...session, status: "revoked" } : { object: "user", deleted: true });
  const r = await clerkDeletionTransport(input);
  expect(r.state).toBe(operation === "deleteUser" ? "acknowledgement" : operation === "revokeSession" ? "session_revoked" : "observed");
  const routes = ["instance"];
  if (operation !== "verifyInstance") routes.push(isSession ? "sessions/sess_test" : "users/user_test");
  if (operation === "deleteUser") routes.push("users/user_test");
  if (operation === "revokeSession") routes.push("sessions/sess_test/revoke");
  expect(transport.mock.calls.map(c => c[0])).toEqual(routes.map(p => `https://api.clerk.com/v1/${p}`));
  for (const [index, [, init]] of transport.mock.calls.entries()) {
    expect(init).toEqual({ method: index === 2 ? operation === "deleteUser" ? "DELETE" : "POST" : "GET",
      redirect: "error", signal: expect.any(AbortSignal), headers: { Authorization: "Bearer synthetic-secret",
        "Clerk-API-Version": "2026-05-12", Accept: "application/json" } });
  }
  expect(authorize).toHaveBeenCalledTimes(routes.length === 3 ? 1 : 0);
  expect(JSON.stringify(r)).not.toMatch(/synthetic-secret|user_test|ins_test/);
});
it.each([undefined, "user_test"])("DELETE permits optional id %s and schema string object", async id => {
  const { input, transport } = setup(); queue(transport, instance, user, { object: "unconstrained_schema_string", deleted: true, ...(id ? { id } : {}) });
  expect(await clerkDeletionTransport(input)).toMatchObject({ state: "acknowledgement", code: "user_delete_acknowledged_observation_required" });
  expect(transport).toHaveBeenCalledTimes(3); // Observation is deliberately a later worker operation.
});
it.each([{ id: "user_other" }, { id: null }, { deleted: false }, { object: 123 }])("blocks invalid DELETE acknowledgement %j", async patch => {
  const { input, transport } = setup(); queue(transport, instance, user, { object: "user", deleted: true, ...patch });
  expect(await clerkDeletionTransport(input)).toMatchObject({ state: "blocked", code: "invalid_delete_acknowledgement" });
});
it.each(["instance", "user", "session", "sessionStatus"])("blocks %s mismatch before mutation", async mismatch => {
  const { input, transport, authorize } = setup(mismatch.startsWith("session") ? "revokeSession" : "deleteUser");
  queue(transport, mismatch === "instance" ? { ...instance, id: "ins_other" } : instance,
    mismatch === "user" ? { ...user, id: "user_other" } : mismatch === "sessionStatus" ? { ...session, status: "invented" } : { ...session, user_id: "user_other" });
  expect(await clerkDeletionTransport(input)).toMatchObject({ state: "blocked" });
  expect(authorize).not.toHaveBeenCalled(); expect(transport.mock.calls.every(c => c[1].method === "GET")).toBe(true);
});
it.each([{ id: "sess_other" }, { user_id: "user_other" }, { object: "other" }, { status: "active" }])("revoke response %j never proves revocation", async patch => {
  const { input, transport } = setup("revokeSession"); queue(transport, instance, session, { ...session, status: "revoked", ...patch });
  expect(await clerkDeletionTransport(input)).toMatchObject({ state: "blocked" });
});
it.each(["getUser", "deleteUser", "getSession", "revokeSession"] as const)("%s typed404 is absence only", async operation => {
  for (const mutation404 of [false, true]) {
    if (mutation404 && operation.startsWith("get")) continue;
    const { input, transport } = setup(operation); queue(transport, instance);
    if (mutation404) queue(transport, operation.includes("Session") ? session : user);
    transport.mockResolvedValueOnce(Response.json(missing, { status: 404 }));
    expect(await clerkDeletionTransport(input)).toEqual({ state: "absence_observed", code: operation.includes("Session") ? "session_absent_not_revoked" : "user_absent", httpStatus: 404 });
    expect(transport).toHaveBeenCalledTimes(mutation404 ? 3 : 2);
  }
});
it.each([{}, { errors: [{ code: "other" }] }, { errors: [missing.errors[0], missing.errors[0]] }])("generic404 %j is not absence", async body => {
  const { input, transport } = setup(); queue(transport, instance); transport.mockResolvedValueOnce(Response.json(body, { status: 404 }));
  expect(await clerkDeletionTransport(input)).toMatchObject({ state: "blocked", code: "malformed_response" });
});
it("instance404 cannot become user absence", async () => {
  const { input, transport } = setup(); transport.mockResolvedValueOnce(Response.json(missing, { status: 404 }));
  expect(await clerkDeletionTransport(input)).toMatchObject({ state: "blocked", code: "provider_rejected" });
});
it.each([204, 302, 400, 401, 403, 409, 422, 408, 429, 500, 503])("HTTP %s sanitized, no retries", async status => {
  const { input, transport } = setup(); queue(transport, instance, user);
  transport.mockResolvedValueOnce(new Response(null, { status }));
  expect(await clerkDeletionTransport(input)).toMatchObject({ state: status === 408 || status === 429 || status >= 500 ? "unknown" : "blocked", httpStatus: status });
  expect(transport).toHaveBeenCalledTimes(3);
});
it.each(["null", "[]", "private non-json", "{}"])("malformed body %s", async body => {
  const { input, transport } = setup(); transport.mockResolvedValueOnce(new Response(body));
  expect(await clerkDeletionTransport(input)).toMatchObject({ state: "blocked" }); expect(transport).toHaveBeenCalledTimes(1);
});
it("withdrawal and rejected authorization prevent submission", async () => {
  for (const rejected of [false, true]) {
    const { input, transport, authorize } = setup(); queue(transport, instance, user);
    if (rejected) authorize.mockRejectedValueOnce(new Error("secret")); else authorize.mockResolvedValueOnce(false);
    expect(await clerkDeletionTransport(input)).toMatchObject({ state: "blocked", code: rejected ? "authorization_check_failed" : "authorization_withdrawn" });
    expect(transport).toHaveBeenCalledTimes(2);
  }
});
it("authorization is immediately before destructive fetch and receives immutable snapshot", async () => {
  const { input, transport } = setup(); const events: string[] = [];
  transport.mockImplementation(async (_url, init) => {
    events.push(init.method!); return Response.json(events.length === 1 ? instance : events.length === 2 ? user : { object: "user", deleted: true });
  });
  input.authorize = async context => {
    events.push("authorize"); expect(Object.isFrozen(context)).toBe(true); expect(Object.isFrozen(context.binding)).toBe(true);
    expect(context.binding).toEqual(binding); expect(context.appleDispositionRevision).toBe("apple_v1");
    expect(context).not.toHaveProperty("credential"); return true;
  };
  const promise = clerkDeletionTransport(input);
  input.binding = { ...binding, subject: "user_other" }; input.appleDispositionRevision = "changed";
  expect(await promise).toMatchObject({ state: "acknowledgement" }); expect(events).toEqual(["GET", "GET", "authorize", "DELETE"]);
});
it("large streamed response is cancelled without accumulating unbounded bytes", async () => {
  const { input, transport } = setup(); const cancel = vi.fn(); let chunks = 0;
  transport.mockResolvedValueOnce(new Response(new ReadableStream({ pull(c) { chunks++; c.enqueue(new Uint8Array(8192)); }, cancel })));
  expect(await clerkDeletionTransport(input)).toMatchObject({ state: "blocked", code: "response_too_large" });
  expect(cancel).toHaveBeenCalled(); expect(chunks).toBeLessThanOrEqual(CLERK_TRANSPORT_MAX_BYTES / 8192 + 2);
});
it.each(["fetch", "body", "authorization"])("%s timeout prevents late destructive submission", async hang => {
  vi.useFakeTimers(); const { input, transport } = setup(); let release!: (value: any) => void;
  if (hang === "fetch") transport.mockImplementationOnce(() => new Promise(resolve => { release = resolve; }));
  if (hang === "body") transport.mockResolvedValueOnce(new Response(new ReadableStream({ start() {} })));
  if (hang === "authorization") { queue(transport, instance, user); input.authorize = () => new Promise(resolve => { release = resolve; }); }
  const pending = clerkDeletionTransport(input); await vi.advanceTimersByTimeAsync(CLERK_TRANSPORT_TIMEOUT_MS);
  expect(await pending).toEqual({ state: "unknown", code: "transport_timeout" });
  expect(transport.mock.calls[0][1].signal?.aborted).toBe(true);
  if (release) release(hang === "fetch" ? Response.json(instance) : true);
  await vi.advanceTimersByTimeAsync(1);
  expect(transport.mock.calls.every(c => c[1].method === "GET")).toBe(true);
});
it("late mutation acknowledgement cannot replace timeout or trigger observation", async () => {
  vi.useFakeTimers(); const { input, transport } = setup(); queue(transport, instance, user);
  let release!: (value: Response) => void;
  transport.mockImplementationOnce(() => new Promise(resolve => { release = resolve; }));
  const pending = clerkDeletionTransport(input); await vi.advanceTimersByTimeAsync(CLERK_TRANSPORT_TIMEOUT_MS);
  expect(await pending).toEqual({ state: "unknown", code: "transport_timeout" });
  release(Response.json({ object: "user", deleted: true })); await vi.advanceTimersByTimeAsync(1);
  expect(transport).toHaveBeenCalledTimes(3);
});
it("transport rejection never echoes credential/upstream text", async () => {
  const { input, transport } = setup(); transport.mockRejectedValueOnce(new Error("synthetic-secret private upstream"));
  expect(await clerkDeletionTransport(input)).toEqual({ state: "unknown", code: "transport_unknown" });
});
it.each(["instanceObject", "userObject", "sessionId", "sessionObject"])("rejects %s shape/identity mismatch", async mismatch => {
  const { input, transport } = setup(mismatch.startsWith("session") ? "getSession" : "getUser");
  queue(transport, mismatch === "instanceObject" ? { ...instance, object: "user" } : instance,
    mismatch === "userObject" ? { ...user, object: "session" } : mismatch === "sessionId" ? { ...session, id: "sess_other" } : { ...session, object: "user" });
  expect(await clerkDeletionTransport(input)).toMatchObject({ state: "blocked" });
});
it.each(["missing", "utf8", "brokenStream"])("rejects %s body safely", async kind => {
  const { input, transport } = setup("getUser");
  const body = kind === "missing" ? null : kind === "utf8" ? new Uint8Array([0xff]) :
    new ReadableStream({ start(c) { c.error(new Error("synthetic-secret")); } });
  transport.mockResolvedValueOnce(new Response(body));
  expect(await clerkDeletionTransport(input)).toMatchObject({ state: kind === "brokenStream" ? "unknown" : "blocked" });
});
it.each([0, 1])("response byte limit boundary +%s", async excess => {
  const { input, transport } = setup("verifyInstance");
  const body = JSON.stringify(instance).padEnd(CLERK_TRANSPORT_MAX_BYTES + excess, " ");
  transport.mockResolvedValueOnce(new Response(body));
  expect(await clerkDeletionTransport(input)).toMatchObject(excess ? { state: "blocked", code: "response_too_large" } : { state: "observed" });
});
it("read primitives need neither Apple disposition nor authorization callback", async () => {
  const { input, transport } = setup("getSession"); delete input.authorize; delete input.appleDispositionRevision;
  queue(transport, instance, session); expect(await clerkDeletionTransport(input)).toMatchObject({ state: "observed" });
});
it("authorization truthy non-boolean fails closed", async () => {
  const { input, transport } = setup(); queue(transport, instance, user);
  input.authorize = async () => "true" as unknown as boolean;
  expect(await clerkDeletionTransport(input)).toMatchObject({ code: "authorization_withdrawn" }); expect(transport).toHaveBeenCalledTimes(2);
});
it("total timeout covers successive reads, not a fresh budget for each request", async () => {
  vi.useFakeTimers(); const { input, transport } = setup();
  transport.mockImplementationOnce(() => new Promise(resolve => setTimeout(() => resolve(Response.json(instance)), 12_000)));
  transport.mockImplementationOnce(() => new Promise(resolve => setTimeout(() => resolve(Response.json(user)), 12_000)));
  const pending = clerkDeletionTransport(input); await vi.advanceTimersByTimeAsync(20_000);
  expect(await pending).toMatchObject({ state: "unknown", code: "transport_timeout" });
  await vi.advanceTimersByTimeAsync(5_000); expect(transport).toHaveBeenCalledTimes(2);
});
it("hanging destructive response body stays unknown and is cancelled", async () => {
  vi.useFakeTimers(); const { input, transport } = setup(); queue(transport, instance, user); const cancel = vi.fn();
  transport.mockResolvedValueOnce(new Response(new ReadableStream({ start() {}, cancel })));
  const pending = clerkDeletionTransport(input); await vi.advanceTimersByTimeAsync(20_000);
  expect(await pending).toMatchObject({ state: "unknown", code: "transport_timeout" });
  expect(cancel).toHaveBeenCalled(); expect(transport).toHaveBeenCalledTimes(3);
});
