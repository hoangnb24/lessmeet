import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "../../convex/schema";
import { internal } from "../../convex/_generated/api";
import type { Doc, Id } from "../../convex/_generated/dataModel";
import { SEND_LEASE_MS, WINDOW_MS, payloadFor } from "../../convex/notificationAdapter";
import crons from "../../convex/crons";

const modules = import.meta.glob(["../../convex/**/*.{ts,js}", "!../../convex/**/*.d.ts", "!../../convex/auth.config.ts"]);
const issuer = "https://synthetic.clerk.accounts.dev", subject = "user_alice", owner = `${issuer}|${subject}`, instance = "ins_synthetic";
const config = "synthetic-route-v1", providerId = "11111111-2222-3333-4444-555555555555";
const complete = { localComplete: true, clerk: true, apple: true, revenuecat: true, gemini: true, residuals: true };
const setup = () => convexTest({ schema, modules, transactionLimits: true });
type T = ReturnType<typeof setup>;
async function seed(t: T, changes: Partial<Doc<"deletions">> = {}) {
  return t.run(async ctx => {
    const id = await ctx.db.insert("deletions", { owner, subject, requestedAt: Date.now(), updatedAt: Date.now(), ...complete,
      automationRevision: 1, discoveryComplete: true, ...changes });
    await ctx.db.insert("deletionOutbox", { request: id, owner, revision: 1, kind: "scope_status", state: "intent", delivery: "not_configured",
      classification: "scope_complete", localComplete: true, providersComplete: true, updatedAt: Date.now() });
    return id;
  });
}
async function contact(t: T, id: Id<"deletions">, changes: Partial<Doc<"deletionContacts">> = {}) {
  return t.run(ctx => ctx.db.insert("deletionContacts", { request: id, owner, subject, issuer, instance,
    email: "alice@example.com", code: "verified_primary", capturedAt: Date.now(), ...changes }));
}
async function frozen(t: T) {
  const id = await seed(t); const c = await contact(t, id);
  const s = (await t.mutation(internal.deletionNotifications.freeze, { id, owner }))!;
  return { id, c, s };
}
async function send(t: T, id: Id<"deletionSends">) { return (await t.run(ctx => ctx.db.get(id)))!; }
async function flush(t: T) {
  await t.finishAllScheduledFunctions(() => vi.runOnlyPendingTimers(), 150);
  const jobs = await t.run(ctx => ctx.db.system.query("_scheduled_functions").collect());
  expect(jobs.filter(job => job.state.kind === "failed")).toEqual([]);
}
beforeEach(() => {
  vi.useFakeTimers(); vi.setSystemTime(new Date("2026-09-24T00:00:00Z"));
  vi.stubEnv("ACCOUNT_DELETION_ENABLED", "true"); vi.stubEnv("DELETION_AUTOMATION_ENABLED", "true");
  vi.stubEnv("DELETION_EMAIL_ENABLED", "true"); vi.stubEnv("DELETION_CONTACT_RETENTION_APPROVED", "true");
  vi.stubEnv("CLERK_CONTACT_INVENTORY_ENABLED", "true"); vi.stubEnv("CLERK_JWT_ISSUER_DOMAIN", issuer);
  vi.stubEnv("CLERK_CONTACT_ISSUER", issuer); vi.stubEnv("CLERK_CONTACT_INSTANCE_ID", instance);
  vi.stubEnv("CLERK_CONTACT_SECRET_KEY", "synthetic-clerk"); vi.stubEnv("RESEND_API_KEY", "synthetic-resend");
  vi.stubEnv("RESEND_DELETION_CONFIG_REF", config);
  vi.stubGlobal("fetch", vi.fn(() => { throw new Error("Network forbidden"); }));
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); });

describe("durable frozen notification", () => {
  it.each(["CLERK_CONTACT_INVENTORY_ENABLED", "DELETION_CONTACT_RETENTION_APPROVED"])("capture is separately default-off without %s", async key => {
    vi.stubEnv(key, undefined); const t = setup();
    await t.withIdentity({ tokenIdentifier: owner, subject, email: "untrusted@example.com" }).mutation(internal.deletion.request, {});
    await flush(t); await t.mutation(internal.deletionNotifications.recover, {}); await flush(t);
    expect(await t.run(ctx => ctx.db.query("deletionContacts").collect())).toEqual([]);
    expect(await t.run(ctx => ctx.db.query("deletionSends").collect())).toEqual([]); expect(fetch).not.toHaveBeenCalled();
  });
  it("captures a durable immutable contact at intake with sends off, surviving signout", async () => {
    vi.stubEnv("DELETION_EMAIL_ENABLED", "false");
    vi.mocked(fetch).mockImplementation(async (url, init) => {
      if (init?.method !== "GET") throw new Error("Sending forbidden");
      if (url === "https://api.clerk.com/v1/instance") return Response.json({ object: "instance", id: instance });
      if (url === `https://api.clerk.com/v1/users/${subject}`) return Response.json({ object: "user", id: subject,
        primary_email_address_id: "primary", email_addresses: [{ object: "email_address", id: "primary", email_address: "alice@example.com", verification: { status: "verified" } }] });
      throw new Error("Unexpected route");
    });
    const t = setup();
    await t.withIdentity({ tokenIdentifier: owner, subject, email: "untrusted@example.com" }).mutation(internal.deletion.request, {});
    await flush(t);
    const d = (await t.run(ctx => ctx.db.query("deletions").unique()))!;
    const saved = (await t.run(ctx => ctx.db.query("deletionContacts").unique()))!;
    expect(saved).toMatchObject({ request: d._id, owner, subject, issuer, instance, code: "verified_primary", email: "alice@example.com" });
    await expect(t.query(internal.deletion.status, {})).rejects.toThrow("Sign in");
    await t.action(internal.deletionNotifications.captureContact, { id: d._id, owner });
    await t.mutation(internal.deletionNotifications.saveContact, { id: d._id, owner, subject, issuer, instance, code: "verified_primary", email: "replacement@example.com" });
    await t.mutation(internal.deletionNotifications.freeze, { id: d._id, owner });
    await t.mutation(internal.deletionNotifications.recover, {}); await flush(t);
    expect(await t.run(ctx => ctx.db.get(saved._id))).toEqual(saved);
    expect(await t.run(ctx => ctx.db.query("deletionSends").collect())).toEqual([]);
    expect(await t.query(internal.deletionNotifications.inventory, { id: d._id, owner })).toMatchObject({ availability: "email_disabled", completionEligible: false });
    expect(JSON.stringify(await t.query(internal.deletionNotifications.inventory, { id: d._id, owner }))).not.toContain(saved.email);
    expect(fetch).toHaveBeenCalledTimes(2);
  });
  it("couples actual intake/contact, independent synthetic Google proof, flags, intent and scheduled send", async () => {
    vi.mocked(fetch).mockImplementation(async (url) => {
      if (url === "https://api.clerk.com/v1/instance") return Response.json({ object: "instance", id: instance });
      if (url === `https://api.clerk.com/v1/users/${subject}`) return Response.json({ object: "user", id: subject,
        primary_email_address_id: "primary", email_addresses: [{ object: "email_address", id: "primary", email_address: "alice@example.com", verification: { status: "verified" } }], private_metadata: { never: "persist" } });
      if (url === "https://api.resend.com/emails") return Response.json({ id: providerId });
      throw new Error("Unexpected route");
    });
    const t = setup(), alice = t.withIdentity({ tokenIdentifier: owner, subject, email: "untrusted@example.com" });
    await alice.mutation(internal.deletion.request, {}); await flush(t);
    const d = (await t.run(ctx => ctx.db.query("deletions").unique()))!;
    expect(await t.run(ctx => ctx.db.query("deletionSends").collect())).toEqual([]);
    expect(await t.query(internal.deletionNotifications.inventory, { id: d._id, owner })).toMatchObject({ contact: { code: "verified_primary" }, completionEligible: false });
    // Independent synthetic prerequisite. This suite does not prove Google revoke.
    await t.run(ctx => ctx.db.patch(d._id, { googleStatus: "acknowledged", googleEvidence: "synthetic-google" }));
    for (const stage of ["clerk", "apple", "revenuecat", "gemini", "residuals"] as const) {
      const current = (await t.run(ctx => ctx.db.get(d._id)))!;
      await t.mutation(internal.deletion.confirm, { id: d._id, owner, stage, complete: true, evidence: "synthetic-case", automationRevision: current.automationRevision });
      await flush(t);
      if (stage !== "residuals") expect(await t.run(ctx => ctx.db.query("deletionSends").collect())).toEqual([]);
    }
    const s = (await t.run(ctx => ctx.db.query("deletionSends").unique()))!;
    expect(s).toMatchObject({ state: "pending", delivery: "pending", providerId, recipient: "alice@example.com", config, completion: complete, attempts: 1 });
    expect(JSON.stringify(s)).not.toContain("untrusted"); expect(JSON.stringify(s)).not.toContain("private_metadata");
    expect(await alice.query(internal.deletion.status, {})).toEqual({ userId: subject, requested: true, localComplete: true, providersComplete: true, requestedAt: d.requestedAt, googleStatus: "acknowledged" });
    expect(await t.run(ctx => ctx.db.query("deletionOutbox").unique())).toMatchObject({ state: "intent", delivery: "not_configured" });
    await t.mutation(internal.deletionNotifications.freeze, { id: d._id, owner }); await t.mutation(internal.deletionNotifications.recover, {}); await flush(t);
    expect(vi.mocked(fetch).mock.calls.filter(c => c[0] === "https://api.resend.com/emails")).toHaveLength(1);
    const inventory = await t.query(internal.deletionNotifications.inventory, { id: d._id, owner });
    expect(JSON.stringify(inventory)).not.toContain("alice@example.com");
  });
  it.each(Object.keys(complete) as Array<keyof typeof complete>)("requires authoritative %s, not a forged complete intent", async flag => {
    const t = setup(), id = await seed(t, { [flag]: false }); await contact(t, id);
    expect(await t.mutation(internal.deletionNotifications.freeze, { id, owner })).toBeNull(); expect(fetch).not.toHaveBeenCalled();
  });
  it.each(["queued", "running", "retry", "blocked", "exhausted"] as const)("does not send with unresolved %s stage", async state => {
    const t = setup(), id = await seed(t); await contact(t, id);
    await t.run(ctx => ctx.db.insert("deletionStages", { request: id, owner, key: "clerk", kind: "clerk", target: subject, config: "unconfigured",
      state, fence: 0, attempts: 0, nextAttemptAt: Date.now(), updatedAt: Date.now() }));
    expect(await t.mutation(internal.deletionNotifications.freeze, { id, owner })).toBeNull();
  });
  it("does not infer completion with outstanding work or unfinished discovery", async () => {
    const t = setup(), id = await seed(t); await contact(t, id);
    const w = await t.run(ctx => ctx.db.insert("deletionWork", { owner, kind: "upload", startedAt: Date.now(), finished: false, ambiguous: true }));
    expect(await t.mutation(internal.deletionNotifications.freeze, { id, owner })).toBeNull();
    await t.run(async ctx => { await ctx.db.delete(w); await ctx.db.patch(id, { discoveryComplete: false }); });
    expect(await t.mutation(internal.deletionNotifications.freeze, { id, owner })).toBeNull();
  });
  it("missing contact and config remain explicit, not JWT email or fallback", async () => {
    const t = setup(), id = await seed(t);
    expect(await t.mutation(internal.deletionNotifications.freeze, { id, owner })).toBeNull();
    expect(await t.query(internal.deletionNotifications.inventory, { id, owner })).toMatchObject({ availability: "contact_missing", send: null });
    await contact(t, id); vi.stubEnv("RESEND_DELETION_CONFIG_REF", undefined);
    expect(await t.mutation(internal.deletionNotifications.freeze, { id, owner })).toBeNull();
    expect(await t.query(internal.deletionNotifications.inventory, { id, owner })).toMatchObject({ availability: "send_config_missing" });
  });
  it.each([{ owner: "other|user_alice" }, { subject: "user_bob" }, { issuer: "https://other.example" }, { instance: "ins_other" },
    { email: "a@privaterelay.appleid.com" }, { code: "unverified" }])("rejects mismatched contact %j", async change => {
    const t = setup(), id = await seed(t); await contact(t, id, change);
    expect(await t.mutation(internal.deletionNotifications.freeze, { id, owner })).toBeNull();
  });
  it("isolates internal inventory, contact lookup and freeze by exact owner", async () => {
    const t = setup(), id = await seed(t);
    await expect(t.mutation(internal.deletionNotifications.freeze, { id, owner: "other" })).rejects.toThrow("Exact deletion target");
    await expect(t.query(internal.deletionNotifications.inventory, { id, owner: "other" })).rejects.toThrow("Exact deletion target");
    await expect(t.action(internal.deletionNotifications.captureContact, { id, owner: "other" })).rejects.toThrow("Exact deletion target");
    expect(fetch).not.toHaveBeenCalled();
  });
  it("freezes once transactionally and cannot repoint contact, payload or key", async () => {
    const t = setup(), { id, c, s } = await frozen(t), before = await send(t, s);
    expect(await Promise.all([t.mutation(internal.deletionNotifications.freeze, { id, owner }), t.mutation(internal.deletionNotifications.freeze, { id, owner })])).toEqual([s, s]);
    await t.mutation(internal.deletionNotifications.saveContact, { id, owner, subject, issuer, instance, email: "new@example.com", code: "verified_primary" });
    expect((await t.run(ctx => ctx.db.get(c)))?.email).toBe("alice@example.com");
    expect(await send(t, s)).toEqual(before);
    expect(await t.run(ctx => ctx.db.query("deletionSends").collect())).toHaveLength(1);
  });
  it("persists relay and missing-contact exceptions without personal response bodies", async () => {
    const t = setup(), id = await seed(t);
    vi.mocked(fetch).mockResolvedValueOnce(Response.json({ object: "instance", id: instance })).mockResolvedValueOnce(Response.json({ object: "user", id: subject,
      primary_email_address_id: "primary", email_addresses: [{ object: "email_address", id: "primary", email_address: "a@privaterelay.appleid.com", verification: { status: "verified" } }] }));
    await t.action(internal.deletionNotifications.captureContact, { id, owner }); await flush(t);
    expect(await t.query(internal.deletionNotifications.inventory, { id, owner })).toMatchObject({ contact: { code: "contact_relay_exception" }, send: null });
    expect(JSON.stringify(await t.run(ctx => ctx.db.query("deletionContacts").collect()))).not.toContain("privaterelay");
  });
  it("fences capture when binding changes while its HTTP lookup is in flight", async () => {
    const t = setup(), id = await seed(t);
    let release!: (r: Response) => void;
    vi.mocked(fetch).mockResolvedValueOnce(Response.json({ object: "instance", id: instance })).mockImplementationOnce(() => new Promise(resolve => { release = resolve; }));
    const action = t.action(internal.deletionNotifications.captureContact, { id, owner });
    await vi.waitFor(() => expect(release).toBeTypeOf("function"));
    vi.stubEnv("CLERK_CONTACT_INSTANCE_ID", "ins_changed");
    release(Response.json({ object: "user", id: subject, primary_email_address_id: "p", email_addresses: [{ object: "email_address", id: "p", email_address: "alice@example.com", verification: { status: "verified" } }] }));
    await action; await flush(t);
    expect(await t.query(internal.deletionNotifications.inventory, { id, owner })).toMatchObject({ contact: { code: "contact_binding" }, send: null });
  });
});

describe("bounded send claims, recovery and races", () => {
  it("recovery is bounded to 32 due rows per state; later cron makes progress", async () => {
    const t = setup();
    for (let i = 0; i < 35; i++) await frozen(t);
    // Simulate loss of original dispatch jobs while preserving the durable send rows.
    await t.run(async ctx => {
      for (const job of await ctx.db.system.query("_scheduled_functions").collect()) await ctx.scheduler.cancel(job._id);
    });
    vi.mocked(fetch).mockImplementation(async () => Response.json({ id: providerId }));
    await t.mutation(internal.deletionNotifications.recover, {});
    expect((await t.run(ctx => ctx.db.system.query("_scheduled_functions").collect())).filter(job => job.state.kind === "pending")).toHaveLength(32);
    await flush(t); expect(fetch).toHaveBeenCalledTimes(32);
    await t.mutation(internal.deletionNotifications.recover, {}); await flush(t); expect(fetch).toHaveBeenCalledTimes(35);
  });
  it("queue delay before first claim does not consume deduplication, but unsafe claim boundary stops", async () => {
    const t = setup(), { s } = await frozen(t);
    vi.setSystemTime(Date.now() + 7 * WINDOW_MS);
    const claim = (await t.mutation(internal.deletionNotifications.claim, { id: s, owner }))!;
    expect(claim.firstAttemptAt).toBe(Date.now());
    vi.setSystemTime(claim.firstAttemptAt + WINDOW_MS - SEND_LEASE_MS);
    expect(await t.mutation(internal.deletionNotifications.claim, { id: s, owner })).toBeNull();
    expect(await send(t, s)).toMatchObject({ code: "send_window_expired", attempts: 1 }); await flush(t); expect(fetch).not.toHaveBeenCalled();
  });
  it("missing sender credential terminates safely and cannot be rearmed with a new key", async () => {
    const t = setup(), { id, s } = await frozen(t); vi.stubEnv("RESEND_API_KEY", undefined);
    await flush(t); expect(await send(t, s)).toMatchObject({ state: "exception", code: "send_secret_missing" });
    vi.stubEnv("RESEND_API_KEY", "new-synthetic-key");
    expect(await t.mutation(internal.deletionNotifications.freeze, { id, owner })).toBe(s);
    await t.mutation(internal.deletionNotifications.recover, {}); await flush(t); expect(fetch).not.toHaveBeenCalled();
  });
  it("allows only one concurrent claim, rejects wrong owner and stale acknowledgement", async () => {
    const t = setup(), { s } = await frozen(t);
    expect(await t.mutation(internal.deletionNotifications.claim, { id: s, owner: "other" })).toBeNull();
    const claims = await Promise.all([t.mutation(internal.deletionNotifications.claim, { id: s, owner }), t.mutation(internal.deletionNotifications.claim, { id: s, owner })]);
    expect(claims.filter(Boolean)).toHaveLength(1); const active = claims.find(Boolean)!;
    await t.mutation(internal.deletionNotifications.finish, { id: s, owner, fence: active.fence - 1, state: "pending", code: "provider_accepted_delivery_pending", providerId });
    expect((await send(t, s)).state).toBe("running");
  });
  it("recovers eight abandoned leases without resetting first-attempt window or frozen bytes", async () => {
    const t = setup(), { s } = await frozen(t), original = await send(t, s);
    for (let attempt = 1; attempt <= 8; attempt++) {
      const claim = await t.mutation(internal.deletionNotifications.claim, { id: s, owner });
      expect(claim?.attempts).toBe(attempt); vi.setSystemTime(Date.now() + SEND_LEASE_MS);
    }
    expect(await t.mutation(internal.deletionNotifications.claim, { id: s, owner })).toBeNull();
    expect(await send(t, s)).toMatchObject({ state: "exception", code: "send_attempts_exhausted", attempts: 8, payload: original.payload, key: original.key, firstAttemptAt: original.createdAt });
    await flush(t); expect(fetch).not.toHaveBeenCalled();
  });
  it("recovers due jobs through bounded cron, ends pending, never resends accepted mail", async () => {
    const t = setup(), { s } = await frozen(t);
    vi.mocked(fetch).mockResolvedValue(Response.json({ id: providerId }));
    await t.mutation(internal.deletionNotifications.recover, {}); await t.mutation(internal.deletionNotifications.recover, {}); await flush(t);
    expect(fetch).toHaveBeenCalledTimes(1); expect(await send(t, s)).toMatchObject({ state: "pending", delivery: "pending", providerId });
    vi.setSystemTime(Date.now() + WINDOW_MS * 2); await t.mutation(internal.deletionNotifications.recover, {}); await flush(t);
    expect(fetch).toHaveBeenCalledTimes(1); expect(crons).toHaveProperty("crons.recover deletion notifications");
  });
  it("retries same payload/key eight times, honors longer Retry-After then exhausts", async () => {
    const t = setup(), { s } = await frozen(t); const times: number[] = [];
    vi.mocked(fetch).mockImplementation(async () => { times.push(Date.now()); return new Response(null, { status: 503, headers: { "Retry-After": "7200" } }); });
    await flush(t); expect(fetch).toHaveBeenCalledTimes(8);
    for (let i = 1; i < times.length; i++) expect(times[i] - times[i - 1]).toBeGreaterThanOrEqual(7200000);
    expect(new Set(vi.mocked(fetch).mock.calls.map(c => c[1]?.body)).size).toBe(1);
    expect(new Set(vi.mocked(fetch).mock.calls.map(c => new Headers(c[1]?.headers).get("Idempotency-Key"))).size).toBe(1);
    expect(await send(t, s)).toMatchObject({ state: "exception", code: "send_attempts_exhausted", attempts: 8, delivery: "pending" });
  });
  it("a retry after transport ambiguity can be accepted without claiming delivery", async () => {
    const t = setup(), { s } = await frozen(t);
    vi.mocked(fetch).mockRejectedValueOnce(new Error("private provider text")).mockResolvedValueOnce(Response.json({ id: providerId }));
    await flush(t); expect(await send(t, s)).toMatchObject({ state: "pending", delivery: "pending", attempts: 2, providerId });
    expect(JSON.stringify(await send(t, s))).not.toContain("private provider text");
  });
  it("refuses Retry-After beyond the deduplication window with no future send", async () => {
    const t = setup(), { s } = await frozen(t);
    vi.mocked(fetch).mockResolvedValue(new Response(null, { status: 429, headers: { "Retry-After": "86400" } }));
    await flush(t); expect(fetch).toHaveBeenCalledTimes(1);
    expect(await send(t, s)).toMatchObject({ state: "exception", code: "send_window_expired", attempts: 1 });
  });
  it("expired ambiguous claim is never retried beyond 24h, even after a gate pause", async () => {
    const t = setup(), { s } = await frozen(t);
    await t.mutation(internal.deletionNotifications.claim, { id: s, owner });
    vi.stubEnv("DELETION_EMAIL_ENABLED", "false"); vi.setSystemTime(Date.now() + WINDOW_MS);
    await flush(t); expect(fetch).not.toHaveBeenCalled();
    vi.stubEnv("DELETION_EMAIL_ENABLED", "true"); await t.mutation(internal.deletionNotifications.recover, {}); await flush(t);
    expect(await send(t, s)).toMatchObject({ state: "exception", code: "send_window_expired", attempts: 1 }); expect(fetch).not.toHaveBeenCalled();
  });
  it.each(["config", "recipient", "payload", "key", "completion", "revision"])("blocks pre-dispatch change of %s", async field => {
    const t = setup(), { id, c, s } = await frozen(t);
    if (field === "config") vi.stubEnv("RESEND_DELETION_CONFIG_REF", "other-route");
    if (field === "recipient") await t.run(ctx => ctx.db.patch(c, { email: "changed@example.com" }));
    if (field === "payload") await t.run(ctx => ctx.db.patch(s, { payload: payloadFor("changed@example.com") }));
    if (field === "key") await t.run(ctx => ctx.db.patch(s, { key: "changed-key" }));
    if (field === "completion") await t.run(ctx => ctx.db.patch(id, { residuals: false }));
    if (field === "revision") await t.run(ctx => ctx.db.patch(id, { automationRevision: 2 }));
    await flush(t); expect(fetch).not.toHaveBeenCalled(); expect((await send(t, s)).state).toBe("exception");
  });
  it("manual completion withdrawal while HTTP is in flight is an exception, not undoable delivery", async () => {
    const t = setup(), { id, s } = await frozen(t); let release!: (r: Response) => void;
    vi.mocked(fetch).mockImplementation(() => new Promise(resolve => { release = resolve; }));
    const action = t.action(internal.deletionNotifications.dispatch, { id: s, owner });
    await vi.waitFor(() => expect(release).toBeTypeOf("function"));
    await t.mutation(internal.deletion.confirm, { id, owner, stage: "residuals", complete: false, evidence: "synthetic-withdrawal", automationRevision: 1 });
    release(Response.json({ id: providerId })); await action; await flush(t);
    expect(await send(t, s)).toMatchObject({ state: "exception", code: "send_binding_or_completion_changed", delivery: "pending", providerId });
    expect(fetch).toHaveBeenCalledTimes(1);
  });
  it("late expired worker cannot overwrite a newer claim result", async () => {
    const t = setup(), { s } = await frozen(t);
    const old = (await t.mutation(internal.deletionNotifications.claim, { id: s, owner }))!;
    vi.setSystemTime(Date.now() + SEND_LEASE_MS);
    const current = (await t.mutation(internal.deletionNotifications.claim, { id: s, owner }))!;
    await t.mutation(internal.deletionNotifications.finish, { id: s, owner, fence: current.fence, state: "pending", code: "provider_accepted_delivery_pending", providerId });
    await t.mutation(internal.deletionNotifications.finish, { id: s, owner, fence: old.fence, state: "retry", code: "send_unknown" });
    expect(await send(t, s)).toMatchObject({ state: "pending", attempts: 2, fence: current.fence, providerId }); await flush(t); expect(fetch).not.toHaveBeenCalled();
  });
});
