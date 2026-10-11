import { afterEach, expect, it, vi } from "vitest";
import { revenuecatDeletionTransport as run, type RevenuecatTransportInput, REVENUECAT_TRANSPORT_MAX_BYTES as MAX } from "../../convex/revenuecatDeletionTransport";

const binding = { issuer: "https://clerk.example", owner: "https://clerk.example|user_test", subject: "user_test", project: "projtest", revision: "r1" };
const path = "/v2/projects/projtest/customers/user_test";
const customer = { object: "customer", id: binding.subject, project_id: binding.project };
const aliases = { object: "list", url: `${path}/aliases`, items: [], next_page: null };
const ack = { object: "customer", id: binding.subject, deleted_at: 0 };
const alias = { object: "customer.alias", id: binding.subject };
function setup(operation: RevenuecatTransportInput["operation"] = "deleteCustomer") {
  const fetch = vi.fn<RevenuecatTransportInput["fetch"]>();
  const authorize = vi.fn(async () => true);
  const input: RevenuecatTransportInput = { enabled: true, binding: { ...binding }, operation, credential: "synthetic-secret", fetch, authorize };
  return { input, fetch, authorize };
}
function queue(fetch: ReturnType<typeof setup>["fetch"], ...bodies: unknown[]) {
  for (const body of bodies) fetch.mockResolvedValueOnce(Response.json(body));
}
afterEach(() => vi.useRealTimers());

it.each([false, undefined])("disabled %s makes zero calls", async enabled => {
  const { input, fetch, authorize } = setup(); input.enabled = enabled;
  expect(await run(input)).toEqual({ state: "blocked", code: "disabled" });
  expect(fetch).not.toHaveBeenCalled(); expect(authorize).not.toHaveBeenCalled();
});
it.each([{ subject: "user_bad/path" }, { subject: "user_" }, { project: "proj../x" }, { project: "a83a" },
  { issuer: "http://clerk.example" }, { issuer: "https://clerk.example/" }, { owner: "other|user_test" }, { revision: "" }])("rejects binding %j", async patch => {
  const { input, fetch } = setup(); Object.assign(input.binding, patch);
  expect(await run(input)).toMatchObject({ state: "blocked", code: "invalid_binding" }); expect(fetch).not.toHaveBeenCalled();
});
it.each([{ items: [] }, { items: [alias] }])("fresh exact reads then authorization then queued deletion %j", async ({ items }) => {
  const { input, fetch, authorize } = setup(); queue(fetch, customer, { ...aliases, items }, ack);
  authorize.mockImplementation(async () => { expect(fetch).toHaveBeenCalledTimes(2); return true; });
  expect(await run(input)).toEqual({ state: "acknowledgement", code: "customer_delete_queued", httpStatus: 200 });
  expect(fetch.mock.calls.map(([url, init]) => [url, init.method])).toEqual([
    [`https://api.revenuecat.com${path}`, "GET"], [`https://api.revenuecat.com${path}/aliases?limit=32`, "GET"], [`https://api.revenuecat.com${path}`, "DELETE"],
  ]);
  for (const [, init] of fetch.mock.calls) expect(init).toEqual({ method: init.method, redirect: "error", signal: expect.any(AbortSignal), headers: { Authorization: "Bearer synthetic-secret", Accept: "application/json" } });
  expect(authorize).toHaveBeenCalledExactlyOnceWith();
});
it("observe is a single read without authorization", async () => {
  const { input, fetch, authorize } = setup("observeCustomer"); queue(fetch, customer);
  expect(await run(input)).toEqual({ state: "observed", code: "customer_present", httpStatus: 200 });
  expect(fetch).toHaveBeenCalledTimes(1); expect(authorize).not.toHaveBeenCalled();
});
it.each(["observeCustomer", "deleteCustomer"] as const)("typed missing %s", async operation => {
  const { input, fetch } = setup(operation); fetch.mockResolvedValueOnce(Response.json({ type: "resource_missing" }, { status: 404 }));
  expect(await run(input)).toEqual({ state: operation === "observeCustomer" ? "absence_observed" : "blocked", code: operation === "observeCustomer" ? "customer_absent" : "inventory_unavailable", httpStatus: 404 });
  expect(fetch).toHaveBeenCalledTimes(1);
});
it.each([{ id: "user_other" }, { project_id: "projother" }, { object: "list" }, { project_id: undefined }])("rejects mismatched customer %j", async patch => {
  const { input, fetch } = setup(); queue(fetch, { ...customer, ...patch });
  expect(await run(input)).toMatchObject({ code: "customer_identity_mismatch" }); expect(fetch).toHaveBeenCalledTimes(1);
});
it.each([{ items: [{ ...alias, id: "user_other" }] }, { items: [{ ...alias, id: "$RCAnonymousID:abc" }] },
  { next_page: `${path}/aliases?starting_after=user_other` }, { next_page: "https://evil.example" }, { next_page: undefined }])("manual exception without traversal %j", async patch => {
  const { input, fetch, authorize } = setup(); queue(fetch, customer, { ...aliases, ...patch });
  expect(await run(input)).toMatchObject({ state: "blocked", code: "alias_ownership_unverified" });
  expect(fetch).toHaveBeenCalledTimes(2); expect(authorize).not.toHaveBeenCalled();
});
it.each([{ object: "customer" }, { url: `${path}/aliases?limit=32` }, { url: "/v2/projects/projother/customers/user_test/aliases" },
  { items: [alias, alias] }, { items: [null] }, { items: [{ ...alias, id: "a b" }] }, { items: [{ ...alias, id: "" }] },
  { items: [{ ...alias, object: "customer" }] }, { items: Array(33).fill(alias) }, { items: {} }])("malformed aliases %j", async patch => {
  const { input, fetch } = setup(); queue(fetch, customer, { ...aliases, ...patch });
  expect(await run(input)).toMatchObject({ state: "blocked", code: "malformed_response" }); expect(fetch).toHaveBeenCalledTimes(2);
});
it.each(["missing", "false", "error"])("authorization %s prevents mutation", async mode => {
  const { input, fetch, authorize } = setup(); queue(fetch, customer, aliases);
  if (mode === "missing") delete input.authorize;
  if (mode === "false") authorize.mockResolvedValue(false);
  if (mode === "error") authorize.mockRejectedValue(new Error("synthetic-secret"));
  expect(await run(input)).toMatchObject({ state: "blocked" }); expect(fetch).toHaveBeenCalledTimes(2);
});
it.each([404, 408, 423, 429, 500, 204])("submission HTTP %s never proves absence or retries", async status => {
  const { input, fetch } = setup(); queue(fetch, customer, aliases);
  fetch.mockResolvedValueOnce(new Response(status === 204 ? null : JSON.stringify({ type: "resource_missing" }), { status }));
  expect(await run(input)).toEqual({ state: "unknown", code: "deletion_outcome_unknown", httpStatus: status }); expect(fetch).toHaveBeenCalledTimes(3);
});
it.each([{}, { ...ack, id: "other" }, { ...ack, object: "deleted" }, ...[-1, 0.5, Number.MAX_SAFE_INTEGER + 1, "0", null].map(deleted_at => ({ ...ack, deleted_at }))])("invalid ack %j remains unknown", async body => {
  const { input, fetch } = setup(); queue(fetch, customer, aliases, body);
  expect(await run(input)).toMatchObject({ state: "unknown", code: "deletion_outcome_unknown" }); expect(fetch).toHaveBeenCalledTimes(3);
});
it.each([408, 423, 429, 500, 503])("read retry hint %s is sanitized without replay", async status => {
  const { input, fetch } = setup(); fetch.mockResolvedValueOnce(Response.json({ backoff_ms: 3000, secret: "synthetic-secret" }, { status, headers: { "Retry-After": "2" } }));
  expect(await run(input)).toEqual({ state: "unknown", code: "provider_temporary", httpStatus: status, retryAfterMs: 3000 }); expect(fetch).toHaveBeenCalledTimes(1);
});
it.each(["not json", "[]", "null", "{\"type\":\"other\"}"])("malformed missing response %s", async body => {
  const { input, fetch } = setup("observeCustomer"); fetch.mockResolvedValueOnce(new Response(body, { status: 404 }));
  expect(await run(input)).toMatchObject({ state: "blocked", code: "malformed_response" });
});
it.each([0, 1])("stream byte boundary +%s", async extra => {
  const { input, fetch } = setup("observeCustomer"); fetch.mockResolvedValueOnce(new Response(JSON.stringify(customer).padEnd(MAX + extra, " ")));
  expect(await run(input)).toMatchObject(extra ? { state: "blocked", code: "response_too_large" } : { state: "observed", code: "customer_present" });
});
it("snapshots all inputs before await", async () => {
  const { input, fetch, authorize } = setup(); queue(fetch, customer, aliases, ack);
  const pending = run(input); Object.assign(input.binding, { subject: "user_other", project: "projother" });
  input.credential = "changed"; input.operation = "observeCustomer"; input.fetch = vi.fn(); input.authorize = async () => false;
  expect(await pending).toMatchObject({ code: "customer_delete_queued" }); expect(authorize).toHaveBeenCalledTimes(1);
  expect(fetch.mock.calls[2][0]).toBe(`https://api.revenuecat.com${path}`);
});
it.each(["fetch", "authorize", "stream"])("deadline guards late %s without mutation", async phase => {
  vi.useFakeTimers(); const { input, fetch, authorize } = setup(); const cancel = vi.fn();
  if (phase === "fetch") fetch.mockImplementationOnce(() => new Promise(resolve => setTimeout(() => resolve(Response.json(customer)), 21_000)));
  else if (phase === "authorize") { queue(fetch, customer, aliases); authorize.mockImplementation(() => new Promise(resolve => setTimeout(() => resolve(true), 21_000))); }
  else fetch.mockResolvedValueOnce(new Response(new ReadableStream({ cancel })));
  const pending = run(input); await vi.advanceTimersByTimeAsync(20_000);
  expect(await pending).toEqual({ state: "unknown", code: "transport_timeout" });
  await vi.advanceTimersByTimeAsync(2_000); expect(fetch).toHaveBeenCalledTimes(phase === "authorize" ? 2 : 1);
  if (phase === "stream") expect(cancel).toHaveBeenCalled();
});
it("deadline is cumulative across reads", async () => {
  vi.useFakeTimers(); const { input, fetch, authorize } = setup();
  for (const body of [customer, aliases]) fetch.mockImplementationOnce(() => new Promise(resolve => setTimeout(() => resolve(Response.json(body)), 12_000)));
  const pending = run(input); await vi.advanceTimersByTimeAsync(25_000);
  expect(await pending).toMatchObject({ code: "transport_timeout" }); expect(fetch).toHaveBeenCalledTimes(2); expect(authorize).not.toHaveBeenCalled();
});
it("hanging submission stream remains unknown and cancels", async () => {
  vi.useFakeTimers(); const { input, fetch } = setup(); queue(fetch, customer, aliases); const cancel = vi.fn();
  fetch.mockResolvedValueOnce(new Response(new ReadableStream({ cancel })));
  const pending = run(input); await vi.advanceTimersByTimeAsync(20_000);
  expect(await pending).toEqual({ state: "unknown", code: "deletion_outcome_unknown" }); expect(cancel).toHaveBeenCalled(); expect(fetch).toHaveBeenCalledTimes(3);
});
it.each([false, true])("thrown secrets never escape (submitted %s)", async submitted => {
  const { input, fetch } = setup(); if (submitted) queue(fetch, customer, aliases);
  fetch.mockRejectedValueOnce(new Error("synthetic-secret private response"));
  expect(await run(input)).toEqual({ state: "unknown", code: submitted ? "deletion_outcome_unknown" : "transport_unknown" });
  expect(fetch).toHaveBeenCalledTimes(submitted ? 3 : 1);
});
