import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "../../convex/schema";
import { internal } from "../../convex/_generated/api";
import type { Doc, Id } from "../../convex/_generated/dataModel";
import { preflightConfig, aliasPath } from "../../convex/preflightAdapter";
import { LEASE_MS, MAX_ATTEMPTS } from "../../convex/deletionAdapter";
import { MAX_CLAIMS, MAX_PAGES, PAGE_SIZE } from "../../convex/preflightContract";
import { PREFLIGHT_RETENTION_MS } from "../../convex/deletionPreflight";
import crons from "../../convex/crons";

const modules = import.meta.glob(["../../convex/**/*.{ts,js}", "!../../convex/**/*.d.ts", "!../../convex/auth.config.ts"]);
const issuer = "https://synthetic.clerk.accounts.dev", subject = "user_alice", owner = `${issuer}|${subject}`, instance = "ins_synthetic", project = "projSynthetic";
const setup = () => convexTest({ schema, modules, transactionLimits: true });
type T = ReturnType<typeof setup>;
type Row = Doc<"deletionPreflights">;
const a = internal.deletionPreflight;
const fence = (s: Row) => ({ id: s._id, owner: s.owner, subject: s.subject, config: s.config, fence: s.fence, cursor: s.cursor });
async function seed(t: T, changes: Partial<Doc<"deletions">> = {}) {
  return t.run(ctx => ctx.db.insert("deletions", { owner, subject, requestedAt: Date.now(), updatedAt: Date.now(),
    localComplete: true, clerk: false, apple: false, revenuecat: false, gemini: false, residuals: false,
    automationRevision: 1, discoveryComplete: true, ...changes }));
}
async function rows(t: T, id: Id<"deletions">) { return (await t.query(a.inventory, { id, owner })).observations; }
async function receipts(t: T, id: Id<"deletions">) { return (await t.query(a.inventory, { id, owner })).receipts; }
async function one(t: T, id: Id<"deletionPreflights">) { return (await t.run(ctx => ctx.db.get(id)))!; }
async function start(t: T) {
  const id = await seed(t); await t.mutation(a.start, { id, owner });
  const all = await rows(t, id);
  return { id, clerk: all.find(s => s.provider === "clerk")!, rc: all.find(s => s.provider === "revenuecat")! };
}
async function flush(t: T) {
  await t.finishAllScheduledFunctions(() => vi.runOnlyPendingTimers(), 200);
  const jobs = await t.run(ctx => ctx.db.system.query("_scheduled_functions").collect());
  expect(jobs.filter(job => job.state.kind === "failed")).toEqual([]);
}
function mockInventory(options: { apple?: boolean; sessions?: number; aliases?: string[]; repeating?: boolean } = {}) {
  vi.mocked(fetch).mockImplementation(async url => {
    const u = new URL(String(url));
    if (u.pathname === "/v1/instance") return Response.json({ object: "instance", id: instance });
    if (u.pathname === `/v1/users/${subject}`) return Response.json({ object: "user", id: subject,
      external_accounts: options.apple ? [{ object: "external_account", id: "eac_apple", provider: "oauth_apple", provider_user_id: "apple.123", email_address: "NEVER" }] : [], private_metadata: { secret: "NEVER" } });
    if (u.pathname === "/v1/sessions") {
      const offset = options.repeating ? 0 : Number(u.searchParams.get("offset"));
      return Response.json(Array.from({ length: Math.max(0, Math.min(PAGE_SIZE, (options.sessions ?? 0) - offset)) }, (_, i) => ({
        object: "session", id: `sess_${offset + i}`, user_id: subject, status: "active", latest_activity: { ip_address: "NEVER" } })));
    }
    if (u.pathname === `/v2/projects/${project}/customers/${subject}`) return Response.json({ object: "customer", id: subject, project_id: project, attributes: { secret: "NEVER" } });
    if (u.pathname === aliasPath(project, subject)) {
      const ids = options.aliases ?? [subject]; const prior = u.searchParams.get("starting_after");
      const offset = prior ? ids.indexOf(prior) + 1 : 0, page = ids.slice(offset, offset + PAGE_SIZE);
      return Response.json({ object: "list", items: page.map(id => ({ object: "customer.alias", id })), url: u.pathname,
        next_page: offset + page.length < ids.length ? `${u.pathname}?starting_after=${encodeURIComponent(page.at(-1)!)}&limit=32` : null });
    }
    throw new Error("Unexpected route");
  });
}
beforeEach(() => {
  vi.useFakeTimers(); vi.setSystemTime(new Date("2026-09-24T00:00:00Z"));
  for (const key of ["ACCOUNT_DELETION_ENABLED", "DELETION_AUTOMATION_ENABLED", "DELETION_PREFLIGHT_ENABLED", "DELETION_PREFLIGHT_RETENTION_APPROVED", "REVENUECAT_PREFLIGHT_PROJECT_VERIFIED"]) vi.stubEnv(key, "true");
  vi.stubEnv("DELETION_EMAIL_ENABLED", undefined); vi.stubEnv("CLERK_JWT_ISSUER_DOMAIN", issuer); vi.stubEnv("CLERK_CONTACT_ISSUER", issuer);
  vi.stubEnv("CLERK_CONTACT_INSTANCE_ID", instance); vi.stubEnv("CLERK_PREFLIGHT_CONFIG_REF", "clerk-v1"); vi.stubEnv("CLERK_CONTACT_SECRET_KEY", "synthetic-clerk");
  vi.stubEnv("REVENUECAT_PREFLIGHT_PROJECT_ID", project); vi.stubEnv("REVENUECAT_PREFLIGHT_CONFIG_REF", "rc-v1"); vi.stubEnv("REVENUECAT_PREFLIGHT_SECRET_KEY", "synthetic-rc");
  vi.stubGlobal("fetch", vi.fn(() => { throw new Error("Network forbidden"); }));
});
afterEach(() => {
  for (const [url, init] of vi.mocked(fetch).mock.calls) {
    expect(init?.method).toBe("GET"); expect(init?.redirect).toBe("error");
    const u = new URL(String(url));
    expect(u.origin === "https://api.clerk.com" ? /^\/v1\/(instance|users\/user_[A-Za-z0-9]+|sessions)$/.test(u.pathname) :
      u.origin === "https://api.revenuecat.com" && /^\/v2\/projects\/proj[A-Za-z0-9]+\/customers\/user_[A-Za-z0-9]+(\/aliases)?$/.test(u.pathname)).toBe(true);
    expect(u.searchParams.has("status")).toBe(false);
  }
  vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals(); vi.unstubAllEnvs();
});
describe("durable bounded provider preflight", () => {
  it.each(["DELETION_PREFLIGHT_ENABLED", "DELETION_PREFLIGHT_RETENTION_APPROVED", "DELETION_AUTOMATION_ENABLED"])("is default-off without %s", async key => {
    vi.stubEnv(key, undefined); const t = setup(), id = await seed(t);
    await t.mutation(a.start, { id, owner }); await t.mutation(a.recover, {}); await flush(t);
    expect(await rows(t, id)).toEqual([]); expect(fetch).not.toHaveBeenCalled();
  });
  it("requires an initialized accepted automation request", async () => {
    const t = setup(), id = await seed(t, { automationRevision: undefined });
    await t.mutation(a.start, { id, owner }); await flush(t); expect(await rows(t, id)).toEqual([]);
  });
  it("integrates with actual intake while preserving public status and all provider flags", async () => {
    mockInventory({ sessions: 35 }); const t = setup(); const alice = t.withIdentity({ tokenIdentifier: owner, subject });
    await alice.mutation(internal.deletion.request, {}); await flush(t);
    const d = (await t.run(ctx => ctx.db.query("deletions").unique()))!;
    const observed = await rows(t, d._id);
    expect(observed).toHaveLength(2); expect(observed.every(s => s.state === "observed" && s.inventoryComplete)).toBe(true);
    expect(observed.find(s => s.provider === "clerk")?.sessions).toHaveLength(35);
    expect(d).toMatchObject({ localComplete: true, clerk: false, apple: false, revenuecat: false, gemini: false, residuals: false });
    expect(await alice.query(internal.deletion.status, {})).toEqual({ userId: subject, requested: true, localComplete: true, providersComplete: false, requestedAt: d.requestedAt, googleStatus: "pending" });
    expect(await t.run(ctx => ctx.db.query("deletionOutbox").unique())).toMatchObject({ classification: "exceptions", providersComplete: false });
    expect(await t.run(ctx => ctx.db.query("deletionSends").collect())).toEqual([]);
    expect(await t.run(ctx => ctx.db.query("deletionContacts").collect())).toEqual([]);
    expect(JSON.stringify(observed)).not.toContain("NEVER");
  });
  it("leaves existing frozen sender/contact, intent and request byte-for-byte unchanged", async () => {
    mockInventory(); const t = setup(); const id = await seed(t);
    const c = await t.run(ctx => ctx.db.insert("deletionContacts", { request: id, owner, subject, issuer, instance, code: "verified_primary", email: "alice@example.com", capturedAt: Date.now() }));
    const o = await t.run(ctx => ctx.db.insert("deletionOutbox", { request: id, owner, revision: 1, kind: "scope_status", state: "intent", delivery: "not_configured", classification: "exceptions", localComplete: true, providersComplete: false, updatedAt: Date.now() }));
    const s = await t.run(ctx => ctx.db.insert("deletionSends", { request: id, owner, subject, intent: o, revision: 1, recipient: "alice@example.com", contact: c,
      completion: { localComplete: true, clerk: true, apple: true, revenuecat: true, gemini: true, residuals: true }, config: "frozen", payload: "frozen", key: "frozen", createdAt: Date.now(),
      state: "pending", delivery: "pending", code: "provider_accepted_delivery_pending", attempts: 1, fence: 1, due: Date.now() }));
    const before = await t.run(async ctx => Promise.all([ctx.db.get(id), ctx.db.get(c), ctx.db.get(o), ctx.db.get(s)]));
    await t.mutation(a.start, { id, owner }); await flush(t);
    expect(await t.run(async ctx => Promise.all([ctx.db.get(id), ctx.db.get(c), ctx.db.get(o), ctx.db.get(s)]))).toEqual(before);
  });
  it("blocks linked Apple provenance without fetching any token", async () => {
    mockInventory({ apple: true }); const t = setup(), { id } = await start(t); await flush(t);
    expect((await rows(t, id)).find(s => s.provider === "clerk")).toMatchObject({ state: "blocked", inventoryComplete: true, code: "apple_provenance_unverified", externalAccounts: [{ id: "eac_apple", provider: "oauth_apple", providerUserId: "apple.123" }] });
  });
  it("collects all bounded aliases but never treats membership as ownership", async () => {
    const ids = [subject, ...Array.from({ length: 35 }, (_, i) => `$RCAnonymousID:${i}`)];
    mockInventory({ aliases: ids }); const t = setup(), { id } = await start(t); await flush(t);
    const rc = (await rows(t, id)).find(s => s.provider === "revenuecat")!;
    expect(rc).toMatchObject({ state: "blocked", inventoryComplete: true, code: "alias_ownership_unverified", pages: 2, aliases: ids });
  });
  it("blocks another named owner alias as well as anonymous aliases", async () => {
    mockInventory({ aliases: [subject, "user_bob"] }); const t = setup(), { rc } = await start(t); await flush(t);
    expect(await one(t, rc._id)).toMatchObject({ state: "blocked", code: "alias_ownership_unverified" });
  });
  it("does not invent historical Apple applicability from missing identity", async () => {
    mockInventory(); const normal = vi.mocked(fetch).getMockImplementation()!;
    vi.mocked(fetch).mockImplementation(async (url, init) => String(url).includes(`/users/${subject}`) ? Response.json({ errors: [{ code: "resource_not_found" }] }, { status: 404 }) : normal(url, init));
    const t = setup(), { id, clerk } = await start(t); await flush(t);
    expect(await one(t, clerk._id)).toMatchObject({ state: "blocked", inventoryComplete: false, code: "resource_absent_inventory_unavailable" });
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ clerk: false, apple: false, revenuecat: false });
  });
  it("keeps mid-pagination absence blocked with partial observations", async () => {
    mockInventory({ aliases: [subject, ...Array.from({ length: 40 }, (_, i) => `alias${i}`)] }); const normal = vi.mocked(fetch).getMockImplementation()!;
    vi.mocked(fetch).mockImplementation(async (url, init) => String(url).includes("starting_after=") ? Response.json({ type: "resource_missing" }, { status: 404 }) : normal(url, init));
    const t = setup(), { rc } = await start(t); await flush(t);
    expect(await one(t, rc._id)).toMatchObject({ state: "blocked", inventoryComplete: false, code: "resource_absent_inventory_unavailable", pages: 1 });
    expect((await one(t, rc._id)).aliases).toHaveLength(32);
  });
  it.each(["CLERK_CONTACT_ISSUER", "REVENUECAT_PREFLIGHT_PROJECT_VERIFIED"])("freezes missing %s as a blocker, never silently rearms", async key => {
    vi.stubEnv(key, undefined); const t = setup(), { id } = await start(t); const before = await rows(t, id);
    vi.stubEnv(key, key === "CLERK_CONTACT_ISSUER" ? issuer : "true");
    await t.mutation(a.start, { id, owner }); expect(await rows(t, id)).toEqual(before);
    expect(before.some(s => s.state === "blocked" && s.code === "config_unverified")).toBe(true);
  });
  it("isolates start and inventory by exact owner", async () => {
    const t = setup(), id = await seed(t);
    await expect(t.mutation(a.start, { id, owner: "other" })).rejects.toThrow("Exact deletion target");
    await expect(t.query(a.inventory, { id, owner: "other" })).rejects.toThrow("Exact deletion target"); expect(fetch).not.toHaveBeenCalled();
  });
  it("rejects an owner not equal to pinned issuer|subject", async () => {
    const t = setup(), id = await seed(t, { owner: "https://other.example|user_alice" });
    await t.mutation(a.start, { id, owner: "https://other.example|user_alice" }); await flush(t);
    expect((await t.run(ctx => ctx.db.query("deletionPreflights").collect())).every(s => s.code === "identity_mismatch")).toBe(true); expect(fetch).not.toHaveBeenCalled();
  });
  it("creates only one frozen row per provider under concurrent starts", async () => {
    const t = setup(), id = await seed(t); await Promise.all([t.mutation(a.start, { id, owner }), t.mutation(a.start, { id, owner })]);
    expect(await rows(t, id)).toHaveLength(2);
  });
  it("claims once and rejects stale, cross-owner or changed-cursor results", async () => {
    const t = setup(), { clerk } = await start(t);
    const claims = await Promise.all([t.mutation(a.claim, { id: clerk._id }), t.mutation(a.claim, { id: clerk._id })]);
    expect(claims.filter(Boolean)).toHaveLength(1); const s = claims.find(Boolean)!;
    for (const change of [{ owner: "other" }, { subject: "user_bob" }, { config: "other" }, { fence: s.fence + 1 }, { cursor: "32" }]) {
      expect(await t.mutation(a.finish, { ...fence(s), ...change, result: { state: "page", code: "inventory_observed", externalAccounts: [] } })).toBe(false);
    }
    expect((await one(t, clerk._id)).phase).toBe("user");
  });
  it.each(["owner", "subject", "requestedAt"] as const)("fences changed deletion %s before claim", async field => {
    const t = setup(), { id, clerk } = await start(t);
    await t.run(ctx => ctx.db.patch(id, field === "requestedAt" ? { requestedAt: 0 } : { [field]: "other" }));
    expect(await t.mutation(a.claim, { id: clerk._id })).toBeNull(); expect((await one(t, clerk._id)).state).toBe("blocked"); expect(fetch).not.toHaveBeenCalled();
  });
  it("fences project/config changes between pages without retargeting", async () => {
    const t = setup(), { rc } = await start(t); const s = (await t.mutation(a.claim, { id: rc._id }))!;
    await t.mutation(a.finish, { ...fence(s), result: { state: "page", code: "inventory_observed" } });
    vi.stubEnv("REVENUECAT_PREFLIGHT_PROJECT_ID", "projOther");
    expect(await t.mutation(a.claim, { id: rc._id })).toBeNull();
    expect(await one(t, rc._id)).toMatchObject({ config: rc.config, state: "blocked", code: "config_changed" });
  });
  it("fences config changes during HTTP without storing returned identity", async () => {
    const t = setup(), { clerk } = await start(t);
    vi.mocked(fetch).mockImplementation(async url => {
      if (String(url).endsWith("/instance")) return Response.json({ object: "instance", id: instance });
      vi.stubEnv("CLERK_PREFLIGHT_CONFIG_REF", "changed");
      return Response.json({ object: "user", id: subject, external_accounts: [{ object: "external_account", id: "eac_apple", provider: "oauth_apple", provider_user_id: "apple.123" }] });
    });
    await t.action(a.run, { id: clerk._id });
    expect(await one(t, clerk._id)).toMatchObject({ state: "blocked", code: "config_changed", externalAccounts: [] });
  });
  it("fences delayed old HTTP after lease loss and a new claim", async () => {
    const t = setup(), { clerk } = await start(t); let release!: (r: Response) => void;
    let entered!: () => void; const waiting = new Promise<void>(resolve => { entered = resolve; });
    vi.mocked(fetch).mockImplementation(async url => String(url).endsWith("/instance") ? Response.json({ object: "instance", id: instance }) : new Promise<Response>(resolve => { release = resolve; entered(); }));
    const action = t.action(a.run, { id: clerk._id });
    await waiting;
    expect(release).toBeTypeOf("function"); const s = await one(t, clerk._id);
    // Move wall time only; do not run the action's timeout or scheduled watchdog yet.
    vi.setSystemTime(Date.now() + LEASE_MS);
    await t.mutation(a.expire, { id: s._id, fence: s.fence });
    const expired = await one(t, clerk._id); vi.setSystemTime(expired.due);
    const replacement = (await t.mutation(a.claim, { id: s._id }))!;
    release(Response.json({ object: "user", id: subject, external_accounts: [] })); await action;
    expect(await one(t, clerk._id)).toEqual(replacement);
  });
  it("rejects overlapping offset pages instead of silently skipping changed inventory", async () => {
    mockInventory({ sessions: 40, repeating: true }); const t = setup(), { clerk } = await start(t); await flush(t);
    expect(await one(t, clerk._id)).toMatchObject({ state: "blocked", code: "pagination_changed", inventoryComplete: false, pages: 1 });
  });
  it.each(["clerk", "revenuecat"] as const)("bounds %s page count", async provider => {
    mockInventory({ sessions: 10_000, aliases: Array.from({ length: 1000 }, (_, i) => `alias${i}`) }); const t = setup(), s = await start(t); await flush(t);
    const row = await one(t, (provider === "clerk" ? s.clerk : s.rc)._id);
    expect(row).toMatchObject({ state: "blocked", code: "pagination_limit", inventoryComplete: false }); expect(row.pages).toBe(MAX_PAGES - 1);
    expect(row.sessions.length + row.aliases.length).toBe((MAX_PAGES - 1) * PAGE_SIZE);
  });
  it("sanitizes forged internal findings rather than persisting error prose", async () => {
    const t = setup(), { clerk } = await start(t); const s = (await t.mutation(a.claim, { id: clerk._id }))!;
    await t.mutation(a.finish, { ...fence(s), result: { state: "blocked", code: "secret NEVER" } });
    expect(await one(t, clerk._id)).toMatchObject({ state: "blocked", code: "malformed_response" }); expect(JSON.stringify(await one(t, clerk._id))).not.toContain("NEVER");
  });
  it.each([
    { state: "page" as const, code: "inventory_observed", aliases: [subject] },
    { state: "page" as const, code: "inventory_observed", externalAccounts: [], next: "32" },
    { state: "retry" as const, code: "inventory_observed" },
    { state: "retry" as const, code: "provider_temporary", retryAfterMs: -1 },
    { state: "blocked" as const, code: "provider_rejected", aliases: [subject] },
  ])("rejects phase-incompatible/non-sanitized result %#", async result => {
    const t = setup(), { clerk } = await start(t); const s = (await t.mutation(a.claim, { id: clerk._id }))!;
    await t.mutation(a.finish, { ...fence(s), result }); expect((await one(t, clerk._id)).code).toBe("malformed_response");
  });
  it("persists Retry-After and retries the same phase/cursor", async () => {
    const t = setup(), { rc } = await start(t); const s = (await t.mutation(a.claim, { id: rc._id }))!;
    await t.mutation(a.finish, { ...fence(s), result: { state: "retry", code: "provider_temporary", retryAfterMs: 10 * 3600_000 } });
    const retry = await one(t, rc._id); expect(retry).toMatchObject({ state: "retry", cursor: "", phase: "customer", attempts: 1 });
    expect(retry.due).toBe(Date.now() + 10 * 3600_000); expect(await t.mutation(a.claim, { id: rc._id })).toBeNull();
  });
  it("exhausts transient failures through actual scheduled retries", async () => {
    vi.mocked(fetch).mockImplementation(async () => Response.json({ message: "NEVER" }, { status: 503 }));
    const t = setup(), { id } = await start(t); await flush(t);
    const all = await rows(t, id); expect(all.every(s => s.state === "exhausted" && s.attempts === MAX_ATTEMPTS && !s.inventoryComplete)).toBe(true);
    expect(fetch).toHaveBeenCalledTimes(MAX_ATTEMPTS * 2);
    await t.mutation(a.recover, {}); await t.mutation(a.start, { id, owner }); await flush(t); expect(fetch).toHaveBeenCalledTimes(MAX_ATTEMPTS * 2);
  });
  it("exhausts abandoned leases and never accepts expired success", async () => {
    const t = setup(), { clerk } = await start(t);
    for (let i = 0; i < MAX_ATTEMPTS; i++) {
      const s = (await t.mutation(a.claim, { id: clerk._id }))!;
      vi.setSystemTime(s.leaseUntil!);
      expect(await t.mutation(a.finish, { ...fence(s), result: { state: "page", code: "inventory_observed", externalAccounts: [] } })).toBe(false);
      await t.mutation(a.expire, { id: s._id, fence: s.fence }); vi.setSystemTime((await one(t, s._id)).due);
    }
    expect(await one(t, clerk._id)).toMatchObject({ state: "exhausted", code: "lease_expired_unknown", attempts: MAX_ATTEMPTS, inventoryComplete: false });
    expect(await t.mutation(a.claim, { id: clerk._id })).toBeNull();
  });
  it("bounds total claims even across successful pages", async () => {
    const t = setup(), { rc } = await start(t); await t.run(ctx => ctx.db.patch(rc._id, { claims: MAX_CLAIMS }));
    expect(await t.mutation(a.claim, { id: rc._id })).toBeNull(); expect((await one(t, rc._id)).state).toBe("exhausted");
  });
  it("recovers an abandoned claim through the committed watchdog", async () => {
    mockInventory(); const t = setup(), { clerk } = await start(t);
    await t.mutation(a.claim, { id: clerk._id }); // No action/finish: simulate worker loss.
    await flush(t);
    expect(await one(t, clerk._id)).toMatchObject({ state: "observed", inventoryComplete: true, claims: 3 });
  });
  it("recovers overdue running work through backup cron", async () => {
    mockInventory(); const t = setup(), { clerk } = await start(t);
    const s = (await t.mutation(a.claim, { id: clerk._id }))!;
    // Cancel only the synthetic watchdog to exercise the cron fallback itself.
    const cancelled = await t.run(async ctx => {
      const jobs = await ctx.db.system.query("_scheduled_functions").collect();
      const watchdogs = jobs.filter(job => job.name.includes("deletionPreflight:expire"));
      for (const job of watchdogs) await ctx.scheduler.cancel(job._id);
      return watchdogs.length;
    });
    expect(cancelled).toBe(1);
    vi.setSystemTime(s.leaseUntil!); await t.mutation(a.recover, {}); await flush(t);
    expect(await one(t, clerk._id)).toMatchObject({ state: "observed", inventoryComplete: true, claims: 3 });
  });
  it("blocks duplicate aliases across otherwise valid pages", async () => {
    mockInventory(); const normal = vi.mocked(fetch).getMockImplementation()!;
    vi.mocked(fetch).mockImplementation(async (url, init) => {
      const u = new URL(String(url));
      if (!u.pathname.endsWith("/aliases")) return normal(url, init);
      return Response.json({ object: "list", url: u.pathname, items: [{ object: "customer.alias", id: subject }],
        next_page: u.searchParams.has("starting_after") ? null : `${u.pathname}?starting_after=${subject}` });
    });
    const t = setup(), { rc } = await start(t); await flush(t);
    expect(await one(t, rc._id)).toMatchObject({ state: "blocked", inventoryComplete: false, code: "pagination_changed", aliases: [subject] });
  });
  it("compacts provider identifiers after thirty inactive days and never rearms the frozen snapshot", async () => {
    mockInventory({ apple: true, sessions: 2, aliases: [subject, "$RCAnonymousID:retained-until-purge"] });
    const t = setup(), { id } = await start(t); await flush(t);
    const before = await rows(t, id);
    expect(before.some(s => s.externalAccounts.length > 0)).toBe(true);
    expect(before.some(s => s.sessions.length > 0)).toBe(true);
    expect(before.some(s => s.aliases.length > 1)).toBe(true);
    expect(await receipts(t, id)).toEqual([]);

    const deadline = Math.max(...before.map(s => s.purgeAt!));
    expect(deadline - Math.max(...before.map(s => s.updatedAt))).toBe(PREFLIGHT_RETENTION_MS);
    vi.setSystemTime(deadline - 1);
    expect(await t.mutation(a.purgeExpired, {})).toBe(0);
    vi.setSystemTime(deadline);
    expect(await t.mutation(a.purgeExpired, {})).toBe(2);

    const inventory = await t.query(a.inventory, { id, owner });
    expect(inventory.observations).toEqual([]);
    expect(inventory.receipts).toHaveLength(2);
    expect(inventory.receipts.map(r => r.provider).sort()).toEqual(["clerk", "revenuecat"]);
    expect(JSON.stringify(inventory.receipts)).not.toMatch(/eac_|sess_|RCAnonymousID|providerUserId|cursor|config/);
    await t.mutation(a.start, { id, owner });
    expect(await rows(t, id)).toEqual([]);
    expect(await receipts(t, id)).toHaveLength(2);
  });
  it("purges while activation gates are off and bounds each compaction batch", async () => {
    const t = setup();
    for (let i = 0; i < 17; i++) {
      const rowSubject = `user_${i}`, rowOwner = `${issuer}|${rowSubject}`;
      const id = await seed(t, { owner: rowOwner, subject: rowSubject });
      await t.run(ctx => ctx.db.insert("deletionPreflights", { request: id, requestedAt: Date.now(), owner: rowOwner, subject: rowSubject, provider: "revenuecat",
        config: "frozen", phase: "aliases", cursor: `alias${i}`, state: "blocked", code: "alias_ownership_unverified", inventoryComplete: true,
        fence: 1, attempts: 0, claims: 1, pages: 1, due: Date.now(), createdAt: Date.now(), updatedAt: Date.now(), purgeAt: Date.now() - 1,
        externalAccounts: [], sessions: [], aliases: [`alias${i}`], cursors: [`alias${i}`] }));
    }
    vi.stubEnv("DELETION_AUTOMATION_ENABLED", undefined);
    vi.stubEnv("DELETION_PREFLIGHT_ENABLED", undefined);
    vi.stubEnv("DELETION_PREFLIGHT_RETENTION_APPROVED", undefined);
    expect(await t.mutation(a.purgeExpired, {})).toBe(16);
    expect(await t.run(ctx => ctx.db.query("deletionPreflights").collect())).toHaveLength(1);
    expect(await t.run(ctx => ctx.db.query("deletionPreflightReceipts").collect())).toHaveLength(16);
    expect(await t.mutation(a.purgeExpired, {})).toBe(1);
    expect(await t.run(ctx => ctx.db.query("deletionPreflights").collect())).toEqual([]);
    expect(JSON.stringify(await t.run(ctx => ctx.db.query("deletionPreflightReceipts").collect()))).not.toContain("alias0");
  });
  it("backfills or immediately compacts legacy rows without a purge deadline", async () => {
    const t = setup(), id = await seed(t);
    const old = Date.now() - PREFLIGHT_RETENTION_MS;
    await t.run(ctx => ctx.db.insert("deletionPreflights", { request: id, requestedAt: old, owner, subject, provider: "revenuecat",
      config: "legacy", phase: "aliases", cursor: "legacy-alias", state: "blocked", code: "alias_ownership_unverified", inventoryComplete: true,
      fence: 1, attempts: 0, claims: 1, pages: 1, due: old, createdAt: old, updatedAt: old,
      externalAccounts: [], sessions: [], aliases: ["legacy-alias"], cursors: ["legacy-alias"] }));
    vi.stubEnv("DELETION_PREFLIGHT_ENABLED", undefined);
    expect(await t.mutation(a.purgeExpired, {})).toBe(1);
    expect(await rows(t, id)).toEqual([]);
    expect(await receipts(t, id)).toMatchObject([{ provider: "revenuecat", code: "alias_ownership_unverified" }]);
    expect(JSON.stringify(await receipts(t, id))).not.toContain("legacy-alias");
  });
  it("pauses queued work on disable and recovers it without resetting the snapshot", async () => {
    mockInventory(); const t = setup(), { id } = await start(t); vi.stubEnv("DELETION_PREFLIGHT_ENABLED", undefined); await flush(t);
    expect((await rows(t, id)).every(s => s.state === "queued" && s.claims === 0)).toBe(true); expect(fetch).not.toHaveBeenCalled();
    vi.stubEnv("DELETION_PREFLIGHT_ENABLED", "true"); await t.mutation(a.recover, {}); await flush(t);
    expect((await rows(t, id)).every(s => s.state === "observed")).toBe(true);
  });
  it("blocks disabled in-flight results without inventing completion", async () => {
    const t = setup(), { clerk } = await start(t), s = (await t.mutation(a.claim, { id: clerk._id }))!;
    vi.stubEnv("DELETION_PREFLIGHT_ENABLED", undefined);
    expect(await t.query(a.authorized, fence(s))).toBe(false);
    await t.mutation(a.finish, { ...fence(s), result: { state: "page", code: "inventory_observed", externalAccounts: [] } });
    expect(await one(t, clerk._id)).toMatchObject({ state: "blocked", inventoryComplete: false });
  });
  it("registers cron and bounds due recovery to sixteen rows per state", async () => {
    expect(JSON.stringify(crons)).toContain("recover deletion preflight");
    expect(JSON.stringify(crons)).toContain("purge deletion preflight identifiers");
    const t = setup(), ids: Id<"deletionPreflights">[] = [];
    for (let i = 0; i < 35; i++) {
      const id = await seed(t, { owner: `${issuer}|user_${i}`, subject: `user_${i}` });
      ids.push(await t.run(ctx => ctx.db.insert("deletionPreflights", { request: id, requestedAt: Date.now(), owner: `${issuer}|user_${i}`, subject: `user_${i}`, provider: "revenuecat",
        config: preflightConfig("revenuecat")!, phase: "customer", cursor: "", state: "queued", code: "inventory_observed", inventoryComplete: false,
        fence: 0, attempts: 0, claims: 0, pages: 0, due: Date.now(), createdAt: Date.now(), updatedAt: Date.now(), externalAccounts: [], sessions: [], aliases: [], cursors: [] })));
    }
    vi.mocked(fetch).mockImplementation(async () => Response.json({ type: "resource_missing" }, { status: 404 }));
    await t.mutation(a.recover, {}); await flush(t); expect(fetch).toHaveBeenCalledTimes(16);
    await t.mutation(a.recover, {}); await flush(t); expect(fetch).toHaveBeenCalledTimes(32);
    await t.mutation(a.recover, {}); await flush(t); expect(fetch).toHaveBeenCalledTimes(35);
    expect((await Promise.all(ids.map(id => one(t, id)))).every(s => s.state === "blocked" && !s.inventoryComplete)).toBe(true);
  });
});
