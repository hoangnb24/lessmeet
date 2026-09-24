import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { CLERK_API_VERSION, readContact, sendNotification, payloadFor, SENDER, SEND_LEASE_MS, SEND_TIMEOUT_MS, WINDOW_MS } from "../../convex/notificationAdapter";

const issuer = "https://synthetic.clerk.accounts.dev", instance = "ins_synthetic", subject = "user_alice";
const contact = { issuer, instance, subject, owner: `${issuer}|${subject}` };
const providerId = "11111111-2222-3333-4444-555555555555";
const user = () => ({ object: "user", id: subject, primary_email_address_id: "id_primary", email_addresses: [
  { object: "email_address", id: "id_secondary", email_address: "ignore@example.com", verification: { status: "verified" } },
  { object: "email_address", id: "id_primary", email_address: "alice@example.com", verification: { status: "verified" } },
] });
function input() { return { config: "synthetic-route-v1", payload: payloadFor("alice@example.com"), key: "synthetic-send", firstAttemptAt: Date.now(), leaseUntil: Date.now() + SEND_LEASE_MS }; }
function contactHTTP(body: unknown = user(), id = instance) {
  vi.mocked(fetch).mockResolvedValueOnce(Response.json({ object: "instance", id })).mockResolvedValueOnce(Response.json(body));
}
beforeEach(() => {
  vi.useFakeTimers(); vi.setSystemTime(new Date("2026-09-24T00:00:00Z"));
  vi.stubEnv("DELETION_EMAIL_ENABLED", "true"); vi.stubEnv("DELETION_CONTACT_RETENTION_APPROVED", "true");
  vi.stubEnv("CLERK_CONTACT_INVENTORY_ENABLED", "true"); vi.stubEnv("CLERK_JWT_ISSUER_DOMAIN", issuer);
  vi.stubEnv("CLERK_CONTACT_ISSUER", issuer); vi.stubEnv("CLERK_CONTACT_INSTANCE_ID", instance);
  vi.stubEnv("CLERK_CONTACT_SECRET_KEY", "synthetic-clerk"); vi.stubEnv("RESEND_API_KEY", "synthetic-resend");
  vi.stubEnv("RESEND_DELETION_CONFIG_REF", "synthetic-route-v1");
  vi.stubGlobal("fetch", vi.fn(() => { throw new Error("Network forbidden"); }));
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); });

describe("pinned exact-subject contact REST", () => {
  it("reads only instance and exact user; persists only verified primary, no SDK wrappers or metadata", async () => {
    contactHTTP({ ...user(), private_metadata: { private: "never saved" } });
    expect(await readContact(contact)).toEqual({ code: "verified_primary", email: "alice@example.com" });
    expect(vi.mocked(fetch).mock.calls.map(c => c[0])).toEqual(["https://api.clerk.com/v1/instance", `https://api.clerk.com/v1/users/${subject}`]);
    for (const [, options] of vi.mocked(fetch).mock.calls) expect(options).toMatchObject({ method: "GET", redirect: "error",
      headers: { Authorization: "Bearer synthetic-clerk", "Clerk-API-Version": CLERK_API_VERSION } });
  });
  it.each(["DELETION_EMAIL_ENABLED", "DELETION_CONTACT_RETENTION_APPROVED", "CLERK_CONTACT_INVENTORY_ENABLED", "CLERK_CONTACT_SECRET_KEY", "CLERK_CONTACT_ISSUER", "CLERK_CONTACT_INSTANCE_ID"])("fails closed without %s", async key => {
    vi.stubEnv(key, undefined); expect((await readContact(contact)).email).toBeUndefined(); expect(fetch).not.toHaveBeenCalled();
  });
  it.each([{ owner: `https://other.example|${subject}` }, { subject: "user_bob" }, { issuer: "https://other.example" }, { instance: "ins_other" }, { subject: "../users", owner: `${issuer}|../users` }])("blocks owner/subject/issuer/instance/path mismatch %j", async change => {
    expect(await readContact({ ...contact, ...change })).toEqual({ code: "contact_binding" }); expect(fetch).not.toHaveBeenCalled();
  });
  it("does not read a user from a key bound to another instance", async () => {
    contactHTTP(user(), "ins_other"); expect(await readContact(contact)).toEqual({ code: "contact_instance_mismatch" }); expect(fetch).toHaveBeenCalledTimes(1);
  });
  it.each([
    { ...user(), id: "user_bob" }, { data: user() }, { ...user(), primary_email_address_id: null },
    { id: subject, primaryEmailAddressId: "id_primary", emailAddresses: user().email_addresses },
  ])("rejects wrong subject and undocumented wrapper/camelCase shapes", async body => {
    contactHTTP(body); expect((await readContact(contact)).email).toBeUndefined();
  });
  it.each(["unverified", "failed", null])("never falls back to a secondary contact when primary verification is %s", async status => {
    const body = user(); body.email_addresses[1].verification.status = status as string;
    contactHTTP(body); expect(await readContact(contact)).toEqual({ code: "contact_missing_verified_primary" });
  });
  it.each(["alice@privaterelay.appleid.com", "alice@PRIVATERELAY.APPLEID.COM"])("treats relay-only %s as exception without retaining address", async email => {
    const body = user(); body.email_addresses[1].email_address = email; contactHTTP(body);
    expect(await readContact(contact)).toEqual({ code: "contact_relay_exception" });
  });
  it.each(["Alice <alice@example.com>", "a@example.com\r\nBcc: victim@example.com", "a@example.com,b@example.com"])("rejects unsafe recipient %j", async email => {
    const body = user(); body.email_addresses[1].email_address = email; contactHTTP(body);
    expect((await readContact(contact)).email).toBeUndefined();
  });
  it("rejects duplicate primary matches", async () => {
    const body = user(); body.email_addresses.push(body.email_addresses[1]); contactHTTP(body);
    expect(await readContact(contact)).toEqual({ code: "contact_missing_verified_primary" });
  });
  it.each([401, 403, 404, 429, 500, 302])("sanitizes HTTP %s without guessing absence or retries", async status => {
    vi.mocked(fetch).mockResolvedValue(new Response("secret response", { status }));
    expect(await readContact(contact)).toEqual({ code: "contact_lookup_failed" }); expect(fetch).toHaveBeenCalledTimes(1);
  });
  it("bounds contact body and timeout without persisting provider text", async () => {
    vi.mocked(fetch).mockResolvedValue(new Response("x".repeat(65537)));
    expect(await readContact(contact)).toEqual({ code: "contact_lookup_failed" });
    vi.mocked(fetch).mockImplementation(() => new Promise(() => {}));
    const pending = readContact(contact); await vi.advanceTimersByTimeAsync(SEND_TIMEOUT_MS);
    expect(await pending).toEqual({ code: "contact_lookup_failed" });
  });
});

describe("Resend REST without delivery fiction", () => {
  it("sends exact frozen body/key and records API acceptance only", async () => {
    const request = input(); vi.mocked(fetch).mockResolvedValue(Response.json({ id: providerId }));
    expect(await sendNotification(request)).toEqual({ state: "pending", code: "provider_accepted_delivery_pending", providerId });
    expect(fetch).toHaveBeenCalledWith("https://api.resend.com/emails", expect.objectContaining({ method: "POST", redirect: "error", body: request.payload,
      headers: { Authorization: "Bearer synthetic-resend", "Content-Type": "application/json", "Idempotency-Key": request.key } }));
    expect(JSON.parse(request.payload)).toMatchObject({ from: SENDER, to: ["alice@example.com"] });
  });
  it.each(["DELETION_EMAIL_ENABLED", "DELETION_CONTACT_RETENTION_APPROVED", "RESEND_DELETION_CONFIG_REF", "RESEND_API_KEY"])("does not send without %s", async key => {
    vi.stubEnv(key, undefined); expect((await sendNotification(input())).state).toBe("exception"); expect(fetch).not.toHaveBeenCalled();
  });
  it("does not adopt a changed configuration reference", async () => {
    expect((await sendNotification({ ...input(), config: "another-account" })).code).toBe("send_config_mismatch"); expect(fetch).not.toHaveBeenCalled();
  });
  it.each([WINDOW_MS, WINDOW_MS - SEND_TIMEOUT_MS, WINDOW_MS + 1])("does not dispatch at unsafe dedupe age %s", async age => {
    const request = input(); request.firstAttemptAt -= age;
    expect((await sendNotification(request)).code).toBe("send_window_expired"); expect(fetch).not.toHaveBeenCalled();
  });
  it("rejects delayed actions whose lease no longer covers transport", async () => {
    const request = input(); request.leaseUntil = Date.now() + SEND_TIMEOUT_MS;
    expect((await sendNotification(request)).code).toBe("send_window_expired"); expect(fetch).not.toHaveBeenCalled();
  });
  it.each([408, 429, 500, 503])("retries HTTP %s with longer Retry-After", async status => {
    vi.mocked(fetch).mockResolvedValue(new Response("sensitive", { status, headers: { "Retry-After": "7200" } }));
    expect(await sendNotification(input())).toEqual({ state: "retry", code: "send_temporary", retryAfterMs: 7200000 });
  });
  it("honors HTTP-date Retry-After", async () => {
    vi.mocked(fetch).mockResolvedValue(new Response(null, { status: 429, headers: { "Retry-After": new Date(Date.now() + 600000).toUTCString() } }));
    expect((await sendNotification(input())).retryAfterMs).toBe(600000);
  });
  it.each([400, 401, 403, 404, 422, 302, 201, 204])("blocks undocumented or rejected HTTP %s", async status => {
    vi.mocked(fetch).mockResolvedValue(new Response(null, { status }));
    expect(await sendNotification(input())).toEqual({ state: "exception", code: "send_rejected" });
  });
  it("distinguishes concurrent 409 from changed-payload conflict", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(Response.json({ name: "concurrent_idempotent_requests" }, { status: 409 }))
      .mockResolvedValueOnce(Response.json({ name: "invalid_idempotent_request", message: "secret" }, { status: 409 }));
    expect(await sendNotification(input())).toEqual({ state: "retry", code: "send_concurrent" });
    expect(await sendNotification(input())).toEqual({ state: "exception", code: "send_conflict" });
  });
  it.each([{}, { id: "sensitive malformed provider id" }, { data: { id: providerId } }])("keeps malformed success ambiguous", async body => {
    vi.mocked(fetch).mockResolvedValue(Response.json(body));
    expect(await sendNotification(input())).toEqual({ state: "retry", code: "send_unknown" });
  });
  it("bounds fetch, body and oversized JSON; errors never leak", async () => {
    vi.mocked(fetch).mockResolvedValue(new Response("x".repeat(65537)));
    expect((await sendNotification(input())).code).toBe("send_unknown");
    vi.mocked(fetch).mockImplementation(() => new Promise(() => {}));
    const pending = sendNotification(input()); await vi.advanceTimersByTimeAsync(SEND_TIMEOUT_MS);
    expect(await pending).toEqual({ state: "retry", code: "send_unknown" });
    vi.mocked(fetch).mockResolvedValue(new Response(new ReadableStream({ start() {} })));
    const body = sendNotification(input()); await vi.advanceTimersByTimeAsync(SEND_TIMEOUT_MS);
    expect(await body).toEqual({ state: "retry", code: "send_unknown" });
  });
  it("swallows rejected body cancellation without leaking provider text", async () => {
    vi.mocked(fetch).mockResolvedValue(new Response(new ReadableStream({ cancel() { throw new Error("private cancellation"); } }), { status: 503 }));
    expect(await sendNotification(input())).toEqual({ state: "retry", code: "send_temporary" });
  });
});
