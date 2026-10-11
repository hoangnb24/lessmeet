import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "../../convex/schema";
import { internal } from "../../convex/_generated/api";
import type { Doc, Id } from "../../convex/_generated/dataModel";
import { LEASE_MS } from "../../convex/deletionAdapter";
import { DELETION_RETENTION_MS } from "../../convex/deletionRetention";
// Clerk-specific tests use a proved Google prerequisite. Google tests exercise the real transport.
vi.mock("../../convex/googleDeletionTransport", () => ({ googleDeletionTransport: vi.fn(async (input) =>
  input.operation === "inventory" ? { state: "inventory", code: "google_inventory_observed", httpStatus: 200,
    accounts: [{ externalAccountId: "ext_google", providerUserId: "google_user" }] } :
    await input.authorize() ? { state: "acknowledgement", code: "google_revoke_acknowledged", httpStatus: 200 } :
      { state: "blocked", code: "authorization_withdrawn" }) }));

const modules = import.meta.glob(["../../convex/**/*.{ts,js}", "!../../convex/**/*.d.ts", "!../../convex/auth.config.ts"]);
const issuer = "https://synthetic.clerk.accounts.dev", subject = "user_alice", owner = `${issuer}|${subject}`, instance = "ins_synthetic";
const a = internal.clerkExecution;
const setup = () => convexTest({ schema, modules, transactionLimits: true });
type T = ReturnType<typeof setup>;
type Row = Doc<"deletionClerkExecutions">;
const fence = (s: Row) => ({ execution: s._id, owner: s.owner, fence: s.fence });
const absent = () => Response.json({ errors: [{ code: "resource_not_found" }] }, { status: 404 });
beforeEach(() => {
  vi.useFakeTimers(); vi.setSystemTime(new Date("2026-09-26T00:00:00Z"));
  vi.stubEnv("DELETION_AUTOMATION_ENABLED", "true"); vi.stubEnv("CLERK_DELETION_ENABLED", "true");
  vi.stubEnv("CLERK_JWT_ISSUER_DOMAIN", issuer); vi.stubEnv("CLERK_CONTACT_ISSUER", issuer);
  vi.stubEnv("CLERK_CONTACT_INSTANCE_ID", instance); vi.stubEnv("CLERK_DELETION_CONFIG_REF", "synthetic-v1");
  vi.stubEnv("CLERK_DELETION_SECRET_KEY", "synthetic-secret");
  vi.stubEnv("GOOGLE_DELETION_ENABLED", "true"); vi.stubEnv("GOOGLE_DELETION_CONFIG_REF", "google-v1");
  vi.stubEnv("GOOGLE_DELETION_CLIENT_ID", "synthetic.apps.googleusercontent.com");
  vi.stubEnv("GOOGLE_DELETION_AUTHORIZED_PARTY_ID", "synthetic.apps.googleusercontent.com"); vi.stubEnv("GOOGLE_DELETION_PROJECT_REF", "synthetic-project");
  vi.stubEnv("DELETION_EMAIL_ENABLED", "false"); vi.stubEnv("DELETION_CONTACT_RETENTION_APPROVED", "true");
  vi.stubEnv("CLERK_CONTACT_INVENTORY_ENABLED", "true"); vi.stubEnv("CLERK_CONTACT_SECRET_KEY", "synthetic-contact");
  vi.stubGlobal("fetch", vi.fn(() => { throw new Error("External network forbidden"); }));
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); });
async function seed(t: T, withContact = true) {
  const id = await t.run(async ctx => {
    const id = await ctx.db.insert("deletions", { owner, subject, requestedAt: Date.now(), updatedAt: Date.now(), localComplete: true,
      clerk: false, apple: true, appleEvidence: "apple-case", revenuecat: false, gemini: false, residuals: false, automationRevision: 1, discoveryComplete: true });
    for (const kind of ["clerk", "apple"] as const) await ctx.db.insert("deletionStages", { request: id, owner, key: kind, kind, target: subject,
      config: "unimplemented", state: kind === "apple" ? "manual" : "blocked", fence: kind === "apple" ? 3 : 1, attempts: 1, nextAttemptAt: Date.now(),
      code: kind === "apple" ? "operator_evidence" : "adapter_unimplemented", ...(kind === "apple" ? { evidence: "apple-case" } : {}), updatedAt: Date.now() });
    if (withContact) await ctx.db.insert("deletionContacts", { request: id, owner, subject, issuer, instance,
      code: "verified_primary", email: "alice@example.com", capturedAt: Date.now() });
    return id;
  });
  return { id, args: { id, owner, stageFence: 1, appleFence: 3, appleEvidence: "apple-case", disposition: "revocation_verified" as const } };
}
async function start(t: T) { const s = await seed(t); return { ...s, execution: await t.mutation(a.adopt, s.args) }; }
async function row(t: T, execution: Id<"deletionClerkExecutions">) { return (await t.run(ctx => ctx.db.get(execution)))!; }
async function flush(t: T) {
  await t.finishAllScheduledFunctions(() => vi.runOnlyPendingTimers(), 200);
  expect((await t.run(ctx => ctx.db.system.query("_scheduled_functions").collect())).filter(x => x.state.kind === "failed")).toEqual([]);
}
function provider(options: { count?: number; mutation?: "lost" | "malformed" | "notApplied"; sessionLost?: boolean } = {}) {
  let deleted = false;
  const statuses = new Map(Array.from({ length: options.count ?? 1 }, (_, i) => [`sess_${i}`, "active"]));
  vi.mocked(fetch).mockImplementation(async (url, init) => {
    const u = new URL(String(url));
    if (u.pathname === "/v1/instance") return Response.json({ object: "instance", id: instance });
    if (u.pathname === `/v1/users/${subject}`) {
      if (init?.method === "DELETE") {
        if (options.mutation !== "notApplied") deleted = true;
        if (options.mutation === "lost") throw new Error("lost response");
        if (options.mutation === "malformed") return Response.json({ secret: "NEVER-PERSIST" });
        return Response.json({ object: "user", id: subject, deleted: true });
      }
      return deleted ? absent() : Response.json({ object: "user", id: subject });
    }
    if (u.pathname === "/v1/sessions") {
      const offset = Number(u.searchParams.get("offset"));
      return Response.json([...statuses].slice(offset, offset + 32).map(([id, status]) => ({ object: "session", id, user_id: subject, status, private: "NEVER-PERSIST" })));
    }
    const match = /^\/v1\/sessions\/(sess_\d+)(\/revoke)?$/.exec(u.pathname);
    if (match) {
      if (match[2]) {
        statuses.set(match[1], "revoked");
        if (options.sessionLost) throw new Error("lost session response");
      }
      return Response.json({ object: "session", id: match[1], user_id: subject, status: statuses.get(match[1]) });
    }
    throw new Error("Unexpected route");
  });
  return { statuses, removeUser: () => { deleted = true; } };
}
const mutations = () => vi.mocked(fetch).mock.calls.filter(([, init]) => init?.method !== "GET");

describe("durable Clerk execution", () => {
  it.each(["missing", "owner", "subject", "issuer", "instance", "relay", "unverified", "invalid", "no-email"])("rejects unusable durable contact: %s", async kind => {
    const t = setup(), { id, args } = await seed(t, kind !== "missing");
    if (kind !== "missing") await t.run(async ctx => {
      const c = (await ctx.db.query("deletionContacts").withIndex("by_request", q => q.eq("request", id)).unique())!;
      const changes = { owner: { owner: "other|user_alice" }, subject: { subject: "user_other" }, issuer: { issuer: "https://other.example" },
        instance: { instance: "ins_other" }, relay: { email: "alice@privaterelay.appleid.com" }, unverified: { code: "contact_missing_verified_primary" },
        invalid: { email: "Alice <alice@example.com>" }, "no-email": { email: undefined } };
      await ctx.db.patch(c._id, changes[kind as keyof typeof changes]);
    });
    await expect(t.mutation(a.adopt, args)).rejects.toThrow("Capture the exact account contact or record a manual exception");
    expect(await t.query(a.inventory, { id, owner })).toBeNull();
    expect(fetch).not.toHaveBeenCalled();
  });
  it("cannot adopt during contact lookup; adopts only after the bound contact commits, with no sends", async () => {
    const t = setup(), { id, args } = await seed(t, false);
    let release!: (r: Response) => void;
    vi.mocked(fetch).mockImplementation(async (url, init) => {
      if (init?.method !== "GET") throw new Error("Destructive call forbidden during capture");
      if (url === "https://api.clerk.com/v1/instance") return Response.json({ object: "instance", id: instance });
      if (url === `https://api.clerk.com/v1/users/${subject}`) return new Promise(resolve => { release = resolve; });
      throw new Error("Unexpected route");
    });
    const capture = t.action(internal.deletionNotifications.captureContact, { id, owner });
    await vi.waitFor(() => expect(release).toBeTypeOf("function"));
    await expect(t.mutation(a.adopt, args)).rejects.toThrow("Verified durable");
    release(Response.json({ object: "user", id: subject, primary_email_address_id: "p", email_addresses: [
      { object: "email_address", id: "p", email_address: "alice@example.com", verification: { status: "verified" } },
    ] }));
    await capture;
    const contact = (await t.run(ctx => ctx.db.query("deletionContacts").unique()))!;
    expect(contact).toMatchObject({ owner, subject, issuer, instance, code: "verified_primary" });
    provider({ count: 0 }); const execution = await t.mutation(a.adopt, args); await flush(t);
    expect(await row(t, execution)).toMatchObject({ state: "observed", userAbsenceObserved: true });
    expect(await t.run(ctx => ctx.db.get(contact._id))).toEqual(contact);
    expect(await t.run(ctx => ctx.db.query("deletionSends").collect())).toEqual([]);
    expect(vi.mocked(fetch).mock.calls.every(([url]) => String(url).startsWith("https://api.clerk.com/v1/"))).toBe(true);
  });
  it.each(["missing", "owner", "instance", "relay"])("rechecks contact %s at the last DELETE authorization", async kind => {
    const t = setup(); provider({ count: 0 }); const { id, execution } = await start(t);
    const original = vi.mocked(fetch).getMockImplementation()!; let reads = 0;
    vi.mocked(fetch).mockImplementation(async (url, init) => {
      if (String(url).endsWith(`/users/${subject}`) && init?.method === "GET" && ++reads === 2) await t.run(async ctx => {
        const c = (await ctx.db.query("deletionContacts").withIndex("by_request", q => q.eq("request", id)).unique())!;
        if (kind === "missing") await ctx.db.delete(c._id);
        else await ctx.db.patch(c._id, kind === "owner" ? { owner: "other|user_alice" } :
          kind === "instance" ? { instance: "ins_other" } : { email: "alice@privaterelay.appleid.com" });
      });
      return original(url, init);
    });
    await flush(t);
    expect(mutations()).toEqual([]);
    expect(await row(t, execution)).toMatchObject({ state: "blocked", code: "contact_required_manual_exception", phase: "observeUser" });
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ clerk: false });
  });
  it("blocks a destructive claim if the contact disappears before the worker starts", async () => {
    const t = setup(), { id, execution } = await start(t);
    await t.run(async ctx => {
      const c = (await ctx.db.query("deletionContacts").withIndex("by_request", q => q.eq("request", id)).unique())!;
      await ctx.db.delete(c._id); await ctx.db.patch(execution, { phase: "deleteUser" });
    });
    expect(await t.mutation(a.claim, { execution })).toBeNull();
    expect(await row(t, execution)).toMatchObject({ state: "blocked", code: "contact_required_manual_exception", mutationUncertain: false });
    await flush(t); expect(fetch).not.toHaveBeenCalled();
  });
  it("historical ambiguous DELETE can observe and reconcile without contact or replay", async () => {
    const t = setup(); provider({ count: 0, mutation: "notApplied" }); const { id, args, execution } = await start(t); await flush(t);
    await t.run(async ctx => {
      const c = (await ctx.db.query("deletionContacts").withIndex("by_request", q => q.eq("request", id)).unique())!;
      await ctx.db.delete(c._id);
    });
    expect(await t.mutation(a.adopt, args)).toBe(execution); // Existing historical adoption is a readback, not a new execution.
    const s = await row(t, execution); expect(s.phase).toBe("observeUser");
    vi.mocked(fetch).mockImplementation(async (url, init) => {
      if (init?.method !== "GET") throw new Error("Historical mutation replay forbidden");
      if (url === "https://api.clerk.com/v1/instance") return Response.json({ object: "instance", id: instance });
      if (url === `https://api.clerk.com/v1/users/${subject}`) return absent();
      throw new Error("Unexpected route");
    });
    await t.mutation(a.observeAgain, fence(s)); await flush(t);
    await t.mutation(a.reconcile, { ...fence(await row(t, execution)), evidence: "historical-scope-case" });
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ clerk: true });
    expect(await t.run(ctx => ctx.db.query("deletionContacts").collect())).toEqual([]);
    expect(mutations()).toHaveLength(1);
  });
  it.each([false, true])("releases a reopened Clerk stage without fabricating completion (running=%s)", async active => {
    const t = setup(), { id, execution } = await start(t);
    const old = active ? (await t.mutation(a.claim, { execution }))! : await row(t, execution);
    await t.mutation(internal.deletion.confirm, { id, owner, stage: "clerk", complete: false, evidence: "reopened-case",
      automationRevision: (await t.run(ctx => ctx.db.get(id)))!.automationRevision });
    const stage = (await t.run(ctx => ctx.db.get(old.stage)))!;
    let args = { ...fence(old), stageFence: stage.fence, automationRevision: (await t.run(ctx => ctx.db.get(id)))!.automationRevision!,
      evidence: "remote-effects-case", remoteEffects: "reconciled" as const };
    if (active) {
      await expect(t.mutation(a.releaseInvalidated, args)).rejects.toThrow("non-running");
      vi.setSystemTime(Date.now() + LEASE_MS + 1); await t.mutation(a.expire, fence(old));
      args = { ...args, ...fence(await row(t, execution)), automationRevision: (await t.run(ctx => ctx.db.get(id)))!.automationRevision! };
    }
    await expect(t.mutation(a.releaseInvalidated, { ...args, owner: "other|user_alice" })).rejects.toThrow();
    await expect(t.mutation(a.releaseInvalidated, { ...args, stageFence: stage.fence - 1 })).rejects.toThrow();
    await expect(t.mutation(a.releaseInvalidated, { ...args, automationRevision: args.automationRevision - 1 })).rejects.toThrow();
    const before = await row(t, execution);
    await t.mutation(a.releaseInvalidated, args);
    expect(await row(t, execution)).toMatchObject({ state: "manual", claims: before.claims, attempts: before.attempts,
      userDeleteAcknowledged: false, userAbsenceObserved: false });
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ clerk: false });
    expect(await t.mutation(a.finish, { ...fence(old), result: { state: "acknowledgement", code: "user_delete_acknowledged_observation_required", httpStatus: 200 } })).toBe(false);
    await t.mutation(internal.deletion.confirm, { id, owner, stage: "clerk", complete: true, evidence: "completion-case",
      automationRevision: (await t.run(ctx => ctx.db.get(id)))!.automationRevision });
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ clerk: true });
    await flush(t); expect(fetch).not.toHaveBeenCalled();
  });

  it("runs fresh inventory, per-session revocation, delete and absence; completion requires explicit reconciliation", async () => {
    const t = setup(); provider({ count: 33 }); const { id, args, execution } = await start(t);
    expect(await t.mutation(a.adopt, args)).toBe(execution);
    await flush(t);
    let s = await row(t, execution);
    expect(s).toMatchObject({ state: "observed", inventoryComplete: true, userAbsenceObserved: true, userDeleteAcknowledged: true, sessionIndex: 33 });
    expect(s.sessions.every(x => x.evidence === "exact_session_revoked")).toBe(true);
    expect(mutations()).toHaveLength(34);
    expect(JSON.stringify(s)).not.toContain("NEVER-PERSIST");
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ clerk: false });
    await expect(t.mutation(internal.deletion.confirm, { id, owner, stage: "clerk", complete: true, evidence: "bypass",
      automationRevision: (await t.run(ctx => ctx.db.get(id)))!.automationRevision })).rejects.toThrow("exact Clerk execution reconciliation");
    await t.mutation(a.reconcile, { ...fence(s), evidence: "operator-case" });
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ clerk: true, clerkEvidence: "operator-case" });
    s = await row(t, execution); expect(s.state).toBe("manual");
  });

  it.each([undefined, "false"])("is default-off (%s) with no network", async flag => {
    const t = setup(), { args } = await seed(t); vi.stubEnv("CLERK_DELETION_ENABLED", flag);
    await expect(t.mutation(a.adopt, args)).rejects.toThrow("disabled or unbound");
    await t.mutation(a.recover, {}); await flush(t); expect(fetch).not.toHaveBeenCalled();
  });
  it.each(["owner", "stageFence", "appleFence", "appleEvidence", "appleFlag", "manualClerk", "budget", "config"])("rejects invalid adoption: %s", async kind => {
    const t = setup(), { id, args } = await seed(t);
    if (kind === "owner") args.owner = "https://other.clerk.accounts.dev|user_alice";
    if (kind === "stageFence") args.stageFence++;
    if (kind === "appleFence") args.appleFence++;
    if (kind === "appleEvidence") args.appleEvidence = "other-case";
    if (kind === "appleFlag") await t.run(ctx => ctx.db.patch(id, { apple: false }));
    if (kind === "config") vi.stubEnv("CLERK_CONTACT_ISSUER", "https://other.example");
    if (kind === "manualClerk" || kind === "budget") await t.run(async ctx => {
      const stage = (await ctx.db.query("deletionStages").withIndex("by_request_key", q => q.eq("request", id).eq("key", "clerk")).unique())!;
      await ctx.db.patch(stage._id, kind === "budget" ? { attempts: 8 } : { state: "manual", evidence: "prior-case" });
    });
    await expect(t.mutation(a.adopt, args)).rejects.toThrow(); expect(fetch).not.toHaveBeenCalled();
  });
  it.each(["lost", "malformed"] as const)("observes after %s DELETE response instead of replaying it", async mutation => {
    const t = setup(); provider({ count: 0, mutation }); const { execution } = await start(t); await flush(t);
    expect(await row(t, execution)).toMatchObject({ state: "observed", userAbsenceObserved: true, userDeleteAcknowledged: false });
    expect(mutations()).toHaveLength(1);
  });
  it("observes a lost session revoke result and preserves terminal-vs-revoked distinction", async () => {
    const t = setup(); provider({ sessionLost: true }); const { execution } = await start(t); await flush(t);
    expect((await row(t, execution)).sessions[0]).toMatchObject({ status: "revoked", evidence: "terminal_observed_not_revocation" });
    expect(mutations()).toHaveLength(2);
  });
  it("does not replay an acknowledged DELETE when user still exists; operator may request another GET", async () => {
    const t = setup(), remote = provider({ count: 0, mutation: "notApplied" }); const { execution } = await start(t); await flush(t);
    let s = await row(t, execution); expect(s).toMatchObject({ state: "blocked", phase: "observeUser", code: "user_mutation_unresolved" });
    await t.mutation(a.observeAgain, fence(s)); await flush(t); s = await row(t, execution);
    expect(s.state).toBe("blocked"); expect(s.attempts).toBe(2); expect(mutations()).toHaveLength(1);
    remote.removeUser(); await t.mutation(a.observeAgain, fence(s)); await flush(t);
    expect(await row(t, execution)).toMatchObject({ state: "observed", attempts: 3 }); expect(mutations()).toHaveLength(1);
  });
  it("bounds inventory without revoking anything when no terminal page was observed", async () => {
    const t = setup(); provider({ count: 256 }); const { execution } = await start(t); await flush(t);
    expect(await row(t, execution)).toMatchObject({ state: "blocked", code: "inventory_limit", inventoryComplete: false }); expect(mutations()).toEqual([]);
  });
  it.each(["config", "apple", "stage", "gate"])("rechecks %s immediately before DELETE and at commit", async kind => {
    const t = setup(); provider({ count: 0 }); const { id, execution } = await start(t);
    const original = vi.mocked(fetch).getMockImplementation()!;
    let reads = 0;
    vi.mocked(fetch).mockImplementation(async (url, init) => {
      if (String(url).endsWith(`/users/${subject}`) && init?.method === "GET" && ++reads === 2) {
        if (kind === "config") vi.stubEnv("CLERK_DELETION_CONFIG_REF", "changed");
        if (kind === "gate") vi.stubEnv("CLERK_DELETION_ENABLED", "false");
        if (kind === "apple" || kind === "stage") await t.run(async ctx => {
          const s = (await ctx.db.get(execution))!;
          const target = kind === "apple" ? s.appleStage : s.stage;
          const old = (await ctx.db.get(target))!; await ctx.db.patch(target, { fence: old.fence + 1 });
        });
      }
      return original(url, init);
    });
    await flush(t); expect(mutations()).toEqual([]);
    expect(await row(t, execution)).toMatchObject({ state: "blocked", code: "prerequisite_changed", phase: "observeUser" });
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ clerk: false });
  });
  it.each(["deleteUser", "revokeSession"] as const)("expired %s intent recovers through observation; stale finish rejected", async phase => {
    const t = setup(), { execution } = await start(t);
    await t.run(async ctx => {
      const s = (await ctx.db.get(execution))!;
      await ctx.db.patch(s.request, { googleStatus: "acknowledged", googleEvidence: "google-proof" });
      await ctx.db.patch(execution, { phase, googleComplete: true, googleEvidence: "google-proof",
        googleAccounts: [{ externalAccountId: "ext_google", providerUserId: "google_user", acknowledged: true, evidence: "google-ack" }],
        inventoryComplete: true, sessions: [{ id: "sess_0", status: "active" }] });
    });
    const claim = (await t.mutation(a.claim, { execution }))!;
    expect(claim.mutationUncertain).toBe(true);
    vi.setSystemTime(Date.now() + LEASE_MS + 1);
    await t.mutation(a.expire, fence(claim));
    expect(await row(t, execution)).toMatchObject({ state: "retry", phase: phase === "deleteUser" ? "observeUser" : "observeSession", mutationUncertain: true });
    expect(await t.mutation(a.finish, { ...fence(claim), result: { state: "acknowledgement", code: "user_delete_acknowledged_observation_required", httpStatus: 200 } })).toBe(false);
    expect(fetch).not.toHaveBeenCalled();
  });
  it("cannot read another owner's execution or accept completion before bounded observation", async () => {
    const t = setup(), { id, execution } = await start(t), s = await row(t, execution);
    await expect(t.query(a.inventory, { id, owner: "other|user_alice" })).rejects.toThrow("Exact deletion target");
    await expect(t.mutation(a.reconcile, { ...fence(s), evidence: "case" })).rejects.toThrow("exact observed");
  });
  it("keeps unresolved execution even if completion flags and retention deadline are inconsistent", async () => {
    const t = setup(), { id, execution } = await start(t);
    await t.run(ctx => ctx.db.patch(id, { clerk: true, revenuecat: true, gemini: true, residuals: true,
      completedAt: Date.now() - DELETION_RETENTION_MS, purgeAt: Date.now() }));
    await t.mutation(internal.deletionRetention.purgeExpired, {});
    expect(await row(t, execution)).not.toBeNull(); expect((await t.run(ctx => ctx.db.get(id)))!.purgeAt).toBeUndefined();
  });
  it("purges reconciled execution with the completed ledger and preserves another owner", async () => {
    const t = setup(); provider({ count: 0 }); const { id, execution } = await start(t); await flush(t);
    await t.mutation(a.reconcile, { ...fence(await row(t, execution)), evidence: "case" });
    const other = await t.run(ctx => ctx.db.insert("deletions", { owner: "other|user_bob", subject: "user_bob", requestedAt: Date.now(), updatedAt: Date.now(),
      localComplete: false, clerk: false, apple: false, revenuecat: false, gemini: false, residuals: false }));
    for (const stage of ["revenuecat", "gemini", "residuals"] as const) await t.mutation(internal.deletion.confirm,
      { id, owner, stage, complete: true, evidence: "case", automationRevision: (await t.run(ctx => ctx.db.get(id)))!.automationRevision });
    vi.setSystemTime(Date.now() + DELETION_RETENTION_MS);
    vi.stubEnv("CLERK_DELETION_ENABLED", "false");
    await t.mutation(internal.deletionRetention.purgeExpired, {}); await flush(t);
    expect(await t.run(ctx => ctx.db.get(id))).toBeNull(); expect(await t.run(ctx => ctx.db.get(execution))).toBeNull();
    expect(await t.run(ctx => ctx.db.get(other))).not.toBeNull();
    const receipts = await t.run(ctx => ctx.db.query("deletionReceipts").collect()); expect(receipts).toHaveLength(1);
    expect(JSON.stringify(receipts)).not.toContain(subject);
  });
});
