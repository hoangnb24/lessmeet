import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "../../convex/schema";
import { internal } from "../../convex/_generated/api";
import type { Doc, Id } from "../../convex/_generated/dataModel";
import { LEASE_MS, MAX_ATTEMPTS } from "../../convex/deletionAdapter";
import { DELETION_RETENTION_MS } from "../../convex/deletionRetention";

const modules = import.meta.glob(["../../convex/**/*.{ts,js}", "!../../convex/**/*.d.ts", "!../../convex/auth.config.ts"]);
const issuer = "https://synthetic.clerk.accounts.dev", subject = "user_alice", owner = `${issuer}|${subject}`;
const instance = "ins_synthetic", project = "projsynthetic", clientId = "com.synthetic.app";
const apple = { externalAccountId: "eac_synthetic", providerUserId: "apple-synthetic", originalClientId: clientId };
const google = { externalAccountId: "eac_google", providerUserId: "google-synthetic", clientId: "synthetic.apps.googleusercontent.com" };
const rcPath = `/v2/projects/${project}/customers/${subject}`;
const a = internal.providerExecution;
const setup = () => convexTest({ schema, modules, transactionLimits: true });
type T = ReturnType<typeof setup>;
type Provider = "apple" | "revenuecat";
type Row = Doc<"deletionProviderExecutions">;
const fence = (s: Row) => ({ execution: s._id, owner: s.owner, fence: s.fence });
const row = async (t: T, execution: Id<"deletionProviderExecutions">) => (await t.run(ctx => ctx.db.get(execution)))!;
const root = async (t: T, id: Id<"deletions">) => (await t.run(ctx => ctx.db.get(id)))!;
const stage = async (t: T, id: Id<"deletions">, key: string) => (await t.run(ctx => ctx.db.query("deletionStages").withIndex("by_request_key", q => q.eq("request", id).eq("key", key)).unique()))!;
const changes = () => vi.mocked(fetch).mock.calls.filter(([, init]) => init?.method !== "GET");
function secret() {
  const b64 = (s: string) => btoa(s).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
  return [b64(JSON.stringify({ alg: "ES256", kid: "SYNTHKEY01" })), b64(JSON.stringify({ iss: "SYNTHTEAM1", sub: clientId,
    aud: "https://appleid.apple.com", iat: Date.now() / 1000, exp: Date.now() / 1000 + 3600 })), b64("x".repeat(64))].join(".");
}
beforeEach(() => {
  vi.useFakeTimers(); vi.setSystemTime(new Date("2026-09-26T00:00:00Z"));
  for (const flag of ["DELETION_AUTOMATION_ENABLED", "APPLE_DELETION_ENABLED", "REVENUECAT_DELETION_ENABLED", "CLERK_DELETION_ENABLED", "GOOGLE_DELETION_ENABLED"]) vi.stubEnv(flag, "true");
  vi.stubEnv("DELETION_EMAIL_ENABLED", "false");
  for (const [key, value] of Object.entries({ CLERK_JWT_ISSUER_DOMAIN: issuer, CLERK_CONTACT_ISSUER: issuer,
    CLERK_CONTACT_INSTANCE_ID: instance, CLERK_DELETION_CONFIG_REF: "synthetic-v1", CLERK_DELETION_SECRET_KEY: "synthetic-clerk",
    GOOGLE_DELETION_CONFIG_REF: "synthetic-v1", GOOGLE_DELETION_PROJECT_REF: "synthetic-project",
    GOOGLE_DELETION_CLIENT_ID: google.clientId, GOOGLE_DELETION_AUTHORIZED_PARTY_ID: google.clientId,
    APPLE_DELETION_CONFIG_REF: "synthetic-v1", APPLE_DELETION_CLIENT_ID: clientId, APPLE_DELETION_TEAM_ID: "SYNTHTEAM1",
    APPLE_DELETION_KEY_ID: "SYNTHKEY01", APPLE_DELETION_CLERK_SECRET_KEY: "synthetic-clerk", APPLE_DELETION_CLIENT_SECRET: secret(),
    REVENUECAT_DELETION_CONFIG_REF: "synthetic-v1", REVENUECAT_DELETION_PROJECT_ID: project, REVENUECAT_DELETION_SECRET_KEY: "synthetic-rc" })) vi.stubEnv(key, value);
  vi.stubGlobal("fetch", vi.fn(() => { throw new Error("External network forbidden"); }));
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); });
async function seed(t: T, provider: Provider = "apple") {
  const id = await t.run(async ctx => {
    const id = await ctx.db.insert("deletions", { owner, subject, requestedAt: Date.now(), updatedAt: Date.now(), localComplete: true,
      clerk: provider === "revenuecat", ...(provider === "revenuecat" ? { clerkEvidence: "clerk-case", appleEvidence: "apple-case" } : {}),
      apple: provider === "revenuecat", revenuecat: false, gemini: false, residuals: false, automationRevision: 1, discoveryComplete: true });
    for (const kind of ["apple", "clerk", "revenuecat", "gemini", "residuals"] as const) {
      const manual = provider === "revenuecat" && (kind === "apple" || kind === "clerk");
      await ctx.db.insert("deletionStages", { request: id, owner, key: kind, kind, target: subject, config: "unimplemented",
        state: manual ? "manual" : "blocked", fence: 1, attempts: 1, nextAttemptAt: Date.now(), code: manual ? "operator_evidence" : "adapter_unimplemented",
        ...(manual ? { evidence: `${kind}-case` } : {}), updatedAt: Date.now() });
    }
    return id;
  });
  return { id, args: { id, owner, provider, stageFence: 1, safetyEvidence: "private-safety-case", ...(provider === "apple" ? { apple } : {}) } };
}
async function start(t: T, provider: Provider = "apple") { const s = await seed(t, provider); return { ...s, execution: await t.mutation(a.adopt, s.args) }; }
async function flush(t: T) {
  await t.finishAllScheduledFunctions(() => vi.runOnlyPendingTimers(), 250);
  expect((await t.run(ctx => ctx.db.system.query("_scheduled_functions").collect())).filter(s => s.state.kind === "failed")).toEqual([]);
}
async function reconcile(t: T, execution: Id<"deletionProviderExecutions">) {
  const s = await row(t, execution);
  await t.mutation(a.reconcile, { ...fence(s), evidence: `${s.provider}-case`, automationRevision: (await root(t, s.request)).automationRevision! });
}
async function confirm(t: T, id: Id<"deletions">, kind: Provider | "gemini" | "residuals", complete = true) {
  await t.mutation(internal.deletion.confirm, { id, owner, stage: kind, complete, evidence: "operator-case", automationRevision: (await root(t, id)).automationRevision });
}
function remote(options: { alias?: string; continuation?: boolean; rc?: "lost" | "present" | "missing"; apple?: "lost" | "seconds" | "missing"; google?: boolean } = {}) {
  let clerkDeleted = false, rcDeleted = false;
  vi.mocked(fetch).mockImplementation(async (url, init) => {
    const u = new URL(String(url));
    if (u.origin === "https://api.clerk.com") {
      if (u.pathname === "/v1/instance") return Response.json({ object: "instance", id: instance });
      if (u.pathname === `/v1/users/${subject}`) {
        if (init?.method === "DELETE") { clerkDeleted = true; return Response.json({ object: "user", id: subject, deleted: true }); }
        return clerkDeleted ? Response.json({ errors: [{ code: "resource_not_found" }] }, { status: 404 }) : Response.json({ object: "user", id: subject,
          external_accounts: [{ object: "external_account", id: apple.externalAccountId, provider: "oauth_apple", provider_user_id: apple.providerUserId,
            verification: { status: "verified", strategy: "oauth_apple" } },
            ...(options.google ? [{ object: "external_account", id: google.externalAccountId, provider: "oauth_google",
              provider_user_id: google.providerUserId, verification: { status: "verified" } }] : [])] });
      }
      if (u.pathname === "/v1/sessions") return Response.json([]);
      if (options.google && u.pathname === `/v1/users/${subject}/oauth_access_tokens/oauth_google`) return Response.json([{
        object: "oauth_access_token", provider: "oauth_google", external_account_id: google.externalAccountId,
        provider_user_id: google.providerUserId, token: "SYNTHETIC-GOOGLE-NEVER-PERSIST",
      }]);
      if (u.pathname === `/v1/users/${subject}/oauth_access_tokens/oauth_apple`) return Response.json(options.apple === "missing" ? [] : [{
        object: "oauth_access_token", provider: "oauth_apple", external_account_id: apple.externalAccountId, provider_user_id: apple.providerUserId,
        token: "SYNTHETIC-NEVER-PERSIST", public_metadata: {}, label: null,
        // Conservative runtime freshness rule; this fixture does NOT prove live timestamp units.
        expires_at: options.apple === "seconds" ? Date.now() / 1000 + 3600 : Date.now() + 3600_000,
      }]);
    }
    if (options.google && u.origin === "https://oauth2.googleapis.com") {
      if (u.pathname === "/tokeninfo") return Response.json({ sub: google.providerUserId, aud: google.clientId,
        azp: google.clientId, expires_in: "3600", scope: "openid email profile" });
      if (u.pathname === "/revoke" && init?.method === "POST") return new Response(null, { status: 200 });
    }
    if (String(url) === "https://appleid.apple.com/auth/revoke" && init?.method === "POST") {
      if (options.apple === "lost") throw new Error("SYNTHETIC-NEVER-PERSIST");
      return new Response(null, { status: 200 });
    }
    if (u.origin === "https://api.revenuecat.com") {
      if (u.pathname === `${rcPath}/aliases`) return Response.json({ object: "list", url: `${rcPath}/aliases`,
        items: options.alias ? [{ object: "customer.alias", id: options.alias }] : [], next_page: options.continuation ? `${rcPath}/aliases?starting_after=other` : null });
      if (u.pathname === rcPath) {
        if (init?.method === "DELETE") {
          rcDeleted = options.rc !== "present";
          if (options.rc === "lost") throw new Error("SYNTHETIC-NEVER-PERSIST");
          return Response.json({ object: "customer", id: subject, deleted_at: Date.now() });
        }
        return rcDeleted || options.rc === "missing" ? Response.json({ type: "resource_missing" }, { status: 404 }) : Response.json({ object: "customer", id: subject, project_id: project });
      }
    }
    throw new Error("Unexpected mocked route");
  });
}

describe("durable Apple and RevenueCat execution", () => {
  it.each(["apple", "revenuecat"] as const)("%s default-off adoption/recovery makes no network calls", async provider => {
    const t = setup(), { args } = await seed(t, provider);
    vi.stubEnv(provider === "apple" ? "APPLE_DELETION_ENABLED" : "REVENUECAT_DELETION_ENABLED", undefined);
    await expect(t.mutation(a.adopt, args)).rejects.toThrow("disabled or unbound");
    await t.mutation(a.recover, {}); await flush(t); expect(fetch).not.toHaveBeenCalled();
  });
  it.each(["apple", "revenuecat"] as const)("global gate stops %s adoption", async provider => {
    const t = setup(), { args } = await seed(t, provider); vi.stubEnv("DELETION_AUTOMATION_ENABLED", "false");
    await expect(t.mutation(a.adopt, args)).rejects.toThrow(); expect(fetch).not.toHaveBeenCalled();
  });
  it.each(["owner", "fence", "config", "local", "budget", "subject", "evidence", "client", "clerk"])("rejects invalid Apple adoption %s", async kind => {
    const t = setup(), { id, args } = await seed(t);
    if (kind === "owner") args.owner = "other|user_alice";
    if (kind === "fence") args.stageFence++;
    if (kind === "config") vi.stubEnv("CLERK_CONTACT_ISSUER", "https://other.example");
    if (kind === "local") await t.run(ctx => ctx.db.patch(id, { localComplete: false }));
    if (kind === "budget") { const s = await stage(t, id, "apple"); await t.run(ctx => ctx.db.patch(s._id, { attempts: MAX_ATTEMPTS })); }
    if (kind === "subject") await t.run(ctx => ctx.db.patch(id, { subject: "user_other" }));
    if (kind === "evidence") args.safetyEvidence = "private data forbidden";
    if (kind === "client") args.apple = { ...apple, originalClientId: "other.client" };
    if (kind === "clerk") await t.run(ctx => ctx.db.patch(id, { clerk: true }));
    await expect(t.mutation(a.adopt, args)).rejects.toThrow(); expect(fetch).not.toHaveBeenCalled();
  });
  it.each(["flag", "evidence", "fence-state"])("RC requires exact reconciled Clerk %s", async kind => {
    const t = setup(), { id, args } = await seed(t, "revenuecat");
    if (kind === "flag") await t.run(ctx => ctx.db.patch(id, { clerk: false }));
    else { const s = await stage(t, id, "clerk"); await t.run(ctx => ctx.db.patch(s._id, kind === "evidence" ? { evidence: "other" } : { state: "blocked" })); }
    await expect(t.mutation(a.adopt, args)).rejects.toThrow("Reconcile Clerk"); expect(fetch).not.toHaveBeenCalled();
  });
  it("missing Apple provenance stays manual-only and cannot bypass execution reconciliation", async () => {
    const t = setup(), { id, args } = await seed(t); delete args.apple;
    const execution = await t.mutation(a.adopt, args); await flush(t);
    expect(await row(t, execution)).toMatchObject({ state: "blocked", code: "apple_provenance_missing", attempts: 0 });
    await expect(confirm(t, id, "apple")).rejects.toThrow("exact provider execution");
    expect((await root(t, id)).apple).toBe(false); expect(fetch).not.toHaveBeenCalled();
    await reconcile(t, execution); expect((await root(t, id)).apple).toBe(true);
  });
  it.each(["seconds", "missing"] as const)("Apple token %s remains exception without revoke", async apple => {
    const t = setup(); remote({ apple }); const { id, execution } = await start(t); await flush(t);
    expect(await row(t, execution)).toMatchObject({ state: "blocked", acknowledged: false,
      code: apple === "seconds" ? "token_expiry_units_unverified" : "token_inventory_unverified" });
    expect((await root(t, id)).apple).toBe(false); expect(changes()).toHaveLength(0);
  });
  it("Apple acknowledgement does not complete or authorize Clerk until operator reconciliation", async () => {
    const t = setup(); remote({ google: true }); const { id, execution } = await start(t); await flush(t);
    expect(await row(t, execution)).toMatchObject({ state: "observed", acknowledged: true, mutationIntent: true, attempts: 1, claims: 1 });
    expect((await root(t, id)).apple).toBe(false);
    const clerkArgs = { id, owner, stageFence: 1, appleFence: (await stage(t, id, "apple")).fence, appleEvidence: "apple-case", disposition: "revocation_verified" as const };
    await expect(t.mutation(internal.clerkExecution.adopt, clerkArgs)).rejects.toThrow("Verified Apple");
    await reconcile(t, execution);
    await expect(t.mutation(internal.clerkExecution.adopt, { ...clerkArgs, appleFence: (await stage(t, id, "apple")).fence })).rejects.toThrow("Verified durable");
    await t.run(ctx => ctx.db.insert("deletionContacts", { request: id, owner, subject, issuer, instance,
      code: "verified_primary", email: "alice@example.com", capturedAt: Date.now() }));
    await t.mutation(internal.clerkExecution.adopt, { ...clerkArgs, appleFence: (await stage(t, id, "apple")).fence });
    await flush(t); expect(changes().filter(([url]) => String(url).includes("appleid"))).toHaveLength(1);
    expect(JSON.stringify(await row(t, execution))).not.toContain("SYNTHETIC-NEVER-PERSIST");
  });
  it.each([{ alias: "user_other" }, { continuation: true }, { rc: "missing" as const }])("RC fresh preflight exception %j never deletes/completes", async options => {
    const t = setup(); remote(options); const { id, execution } = await start(t, "revenuecat"); await flush(t);
    expect(await row(t, execution)).toMatchObject({ state: "blocked", acknowledged: false, absenceObserved: false,
      code: options.rc ? "inventory_unavailable" : "alias_ownership_unverified" });
    expect(changes()).toHaveLength(0); expect((await root(t, id)).revenuecat).toBe(false);
    await expect(confirm(t, id, "revenuecat")).rejects.toThrow("exact provider execution");
  });
  it.each([
    { name: "initial404", options: { rc: "missing" as const }, code: "inventory_unavailable", reads: 1 },
    { name: "alias-conflict", options: { alias: "user_other" }, code: "alias_ownership_unverified", reads: 2 },
  ])("RC $name requires exact operator evidence, not an absence callback", async ({ options, code, reads }) => {
    const t = setup(); remote(options); const { id, execution } = await start(t, "revenuecat"); await flush(t);
    const blocked = await row(t, execution);
    expect(blocked).toMatchObject({ state: "blocked", phase: "execute", code, acknowledged: false, absenceObserved: false });
    expect(vi.mocked(fetch).mock.calls.map(([url, init]) => [url, init?.method])).toEqual([
      [`https://api.revenuecat.com${rcPath}`, "GET"],
      ...(reads === 2 ? [[`https://api.revenuecat.com${rcPath}/aliases?limit=32`, "GET"]] : []),
    ]);
    expect(changes()).toHaveLength(0);
    // Resolve other synthetic stages so RevenueCat alone prevents completion.
    await confirm(t, id, "gemini"); await confirm(t, id, "residuals");
    const before = await root(t, id), beforeStage = await stage(t, id, "revenuecat");
    expect(before).toMatchObject({ apple: true, clerk: true, gemini: true, residuals: true, revenuecat: false });
    expect(await t.withIdentity({ tokenIdentifier: owner, subject }).query(internal.deletion.status, {})).toMatchObject({ providersComplete: false });
    expect(await t.run(ctx => ctx.db.query("deletionOutbox").withIndex("by_request", q => q.eq("request", id)).unique())).toMatchObject({ providersComplete: false });
    // An exact-ID absence callback is not alias/history evidence or a running claim.
    expect(await t.mutation(a.finish, { ...fence(blocked), result: { state: "absence_observed", code: "customer_absent", httpStatus: 404 } })).toBe(false);
    await expect(confirm(t, id, "revenuecat")).rejects.toThrow("exact provider execution");
    await t.mutation(a.recover, {}); await t.action(a.run, { execution }); await flush(t);
    expect(await row(t, execution)).toEqual(blocked); expect(await root(t, id)).toEqual(before);
    expect(vi.mocked(fetch).mock.calls).toHaveLength(reads); expect(changes()).toHaveLength(0);
    const args = { ...fence(blocked), automationRevision: before.automationRevision!, evidence: "synthetic-rc-history-reconciled" };
    for (const { patch, error } of [
      { patch: { owner: `${issuer}|user_other` }, error: "Verify the exact terminal provider case" },
      { patch: { fence: blocked.fence - 1 }, error: "Verify the exact terminal provider case" },
      { patch: { automationRevision: before.automationRevision! - 1 }, error: "Deletion revision changed" },
      { patch: { evidence: "" }, error: "Verify the exact terminal provider case" },
    ]) {
      await expect(t.mutation(a.reconcile, { ...args, ...patch })).rejects.toThrow(error);
      expect(await row(t, execution)).toEqual(blocked); expect(await root(t, id)).toEqual(before);
      expect(await stage(t, id, "revenuecat")).toEqual(beforeStage);
    }
    // This reference attests synthetic history/recreation handling, not live proof.
    await t.mutation(a.reconcile, args);
    const accepted = await row(t, execution);
    expect(accepted).toEqual({ ...blocked, state: "manual", fence: blocked.fence + 1, evidence: args.evidence, updatedAt: Date.now() });
    expect(await root(t, id)).toMatchObject({ revenuecat: true, revenuecatEvidence: args.evidence });
    expect(await stage(t, id, "revenuecat")).toMatchObject({ state: "manual", evidence: args.evidence, fence: beforeStage.fence + 1 });
    expect(await t.withIdentity({ tokenIdentifier: owner, subject }).query(internal.deletion.status, {})).toMatchObject({ providersComplete: true });
    expect(await t.run(ctx => ctx.db.query("deletionOutbox").withIndex("by_request", q => q.eq("request", id)).unique())).toMatchObject({ providersComplete: true });
    await t.mutation(a.recover, {}); await flush(t);
    expect(await row(t, execution)).toEqual(accepted);
    expect(vi.mocked(fetch).mock.calls).toHaveLength(reads); expect(changes()).toHaveLength(0);
  });
  it.each([undefined, "lost"] as const)("RC %s response switches to readback without destructive replay", async rc => {
    const t = setup(); remote({ rc }); const { id, args, execution } = await start(t, "revenuecat");
    await t.action(a.run, { execution });
    expect(await row(t, execution)).toMatchObject({ phase: "observe", state: "queued", acknowledged: rc !== "lost", absenceObserved: false, attempts: 0, claims: 1 });
    expect((await root(t, id)).revenuecat).toBe(false); await flush(t);
    const s = await row(t, execution);
    expect(s).toMatchObject({ state: "observed", absenceObserved: true, attempts: 1, claims: 2 });
    expect(await t.mutation(a.adopt, args)).toBe(execution); expect(await row(t, execution)).toEqual(s);
    await t.mutation(a.recover, {}); await flush(t); expect(changes()).toHaveLength(1);
    expect(vi.mocked(fetch).mock.calls.map(([u, i]) => [u, i?.method])).toEqual([
      [`https://api.revenuecat.com${rcPath}`, "GET"], [`https://api.revenuecat.com${rcPath}/aliases?limit=32`, "GET"],
      [`https://api.revenuecat.com${rcPath}`, "DELETE"], [`https://api.revenuecat.com${rcPath}`, "GET"],
    ]);
    await reconcile(t, execution); expect((await root(t, id)).revenuecat).toBe(true);
  });
  it("RC persistent presence exhausts bounded readback without budget resets or DELETE replay", async () => {
    const t = setup(); remote({ rc: "present" }); const { id, args, execution } = await start(t, "revenuecat"); await flush(t);
    const s = await row(t, execution); expect(s).toMatchObject({ state: "exhausted", attempts: MAX_ATTEMPTS, claims: MAX_ATTEMPTS + 1, acknowledged: true, absenceObserved: false });
    expect(changes()).toHaveLength(1); expect(vi.mocked(fetch).mock.calls).toHaveLength(MAX_ATTEMPTS + 3);
    expect(await t.mutation(a.adopt, args)).toBe(execution); await t.mutation(a.recover, {}); await flush(t);
    expect(await row(t, execution)).toEqual(s); expect((await root(t, id)).revenuecat).toBe(false);
  });
  it("Apple lost response is operator-only and never replays", async () => {
    const t = setup(); remote({ apple: "lost" }); const { id, execution } = await start(t); await flush(t);
    expect(await row(t, execution)).toMatchObject({ state: "blocked", acknowledged: false, mutationIntent: true, attempts: 1 });
    await t.mutation(a.recover, {}); await flush(t); expect(changes()).toHaveLength(1); expect((await root(t, id)).apple).toBe(false);
  });
  it.each(["config", "gate", "stage", "clerk"])("RC final authorization rejects changed %s", async kind => {
    const t = setup(); remote(); const { execution } = await start(t, "revenuecat"); const original = vi.mocked(fetch).getMockImplementation()!;
    vi.mocked(fetch).mockImplementation(async (url, init) => {
      if (String(url).includes("/aliases?")) {
        if (kind === "config") vi.stubEnv("REVENUECAT_DELETION_CONFIG_REF", "changed");
        if (kind === "gate") vi.stubEnv("REVENUECAT_DELETION_ENABLED", "false");
        if (kind === "stage" || kind === "clerk") await t.run(async ctx => {
          const s = (await ctx.db.get(execution))!, id = kind === "stage" ? s.stage : s.clerkStage!;
          const st = (await ctx.db.get(id))!; await ctx.db.patch(id, { fence: st.fence + 1 });
        });
      }
      return original(url, init);
    });
    await flush(t); expect(changes()).toHaveLength(0);
    expect(await row(t, execution)).toMatchObject({ state: "blocked", code: "prerequisite_changed", phase: "observe" });
  });
  it.each(["apple", "revenuecat"] as const)("expired %s intent cannot replay or accept stale callbacks", async provider => {
    const t = setup(), { execution } = await start(t, provider); const s = (await t.mutation(a.claim, { execution }))!;
    expect(await t.query(a.authorized, { ...fence(s), owner: "other" })).toBe(false);
    expect(await t.query(a.authorized, { ...fence(s), fence: s.fence + 1 })).toBe(false);
    vi.setSystemTime(Date.now() + LEASE_MS + 1); await t.mutation(a.expire, fence(s));
    expect(await row(t, execution)).toMatchObject({ state: provider === "apple" ? "blocked" : "retry", phase: provider === "apple" ? "execute" : "observe", mutationIntent: true, claims: 1 });
    expect(await t.mutation(a.finish, { ...fence(s), result: { state: "acknowledgement", code: provider === "apple" ? "apple_revocation_acknowledged" : "customer_delete_queued", httpStatus: 200 } })).toBe(false);
    remote({ rc: "missing" }); await flush(t); expect(changes()).toHaveLength(0);
  });
  it.each(["gate", "config", "stage"])("Apple rechecks %s after token read and before revoke", async kind => {
    const t = setup(); remote(); const { id, execution } = await start(t); const original = vi.mocked(fetch).getMockImplementation()!;
    vi.mocked(fetch).mockImplementation(async (url, init) => {
      const response = await original(url, init);
      if (String(url).includes("/oauth_access_tokens/")) {
        if (kind === "gate") vi.stubEnv("APPLE_DELETION_ENABLED", "false");
        if (kind === "config") vi.stubEnv("APPLE_DELETION_CONFIG_REF", "changed");
        if (kind === "stage") { const st = await stage(t, id, "apple"); await t.run(ctx => ctx.db.patch(st._id, { fence: st.fence + 1 })); }
      }
      return response;
    });
    await flush(t); expect(changes()).toHaveLength(0);
    expect(await row(t, execution)).toMatchObject({ state: "blocked", code: "prerequisite_changed", acknowledged: false });
    expect((await root(t, id)).apple).toBe(false);
  });
  it.each(["apple", "revenuecat"] as const)("post-submission %s config change rejects acknowledgement persistence", async provider => {
    const t = setup(); remote(); const { id, execution } = await start(t, provider); const original = vi.mocked(fetch).getMockImplementation()!;
    vi.mocked(fetch).mockImplementation(async (url, init) => {
      const response = await original(url, init);
      if (init?.method !== "GET") vi.stubEnv(provider === "apple" ? "APPLE_DELETION_CONFIG_REF" : "REVENUECAT_DELETION_CONFIG_REF", "changed");
      return response;
    });
    await flush(t);
    expect(await row(t, execution)).toMatchObject({ state: "blocked", code: "prerequisite_changed", acknowledged: false, mutationIntent: true });
    expect((await root(t, id))[provider]).toBe(false);
    await t.mutation(a.recover, {}); await flush(t); expect(changes()).toHaveLength(1);
  });
  it("persistence boundary sanitizes callback secrets and preserves observation-only retry hints", async () => {
    const t = setup(), { execution } = await start(t, "revenuecat");
    const s = (await t.mutation(a.claim, { execution }))!;
    await t.mutation(a.finish, { ...fence(s), result: { state: "acknowledgement", code: "SYNTHETIC-NEVER-PERSIST", httpStatus: 200 } });
    expect(await row(t, execution)).toMatchObject({ phase: "observe", acknowledged: false, code: "malformed_response", claims: 1 });
    const read = (await t.mutation(a.claim, { execution }))!;
    await t.mutation(a.finish, { ...fence(read), result: { state: "unknown", code: "provider_temporary", httpStatus: 429, retryAfterMs: 3600_000 } });
    const waiting = await row(t, execution);
    expect(waiting).toMatchObject({ state: "retry", phase: "observe", attempts: 1, claims: 2 });
    expect(waiting.due).toBeGreaterThanOrEqual(Date.now() + 3600_000);
    expect(JSON.stringify(waiting)).not.toContain("SYNTHETIC-NEVER-PERSIST"); expect(fetch).not.toHaveBeenCalled();
  });
  it("execution claim budget cannot be reset by re-adoption or recovery", async () => {
    const t = setup(), { args, execution } = await start(t, "revenuecat");
    await t.run(ctx => ctx.db.patch(execution, { phase: "observe", mutationIntent: true, attempts: MAX_ATTEMPTS - 1, claims: MAX_ATTEMPTS + 1 }));
    expect(await t.mutation(a.claim, { execution })).toBeNull();
    const exhausted = await row(t, execution);
    expect(exhausted).toMatchObject({ state: "exhausted", attempts: MAX_ATTEMPTS - 1, claims: MAX_ATTEMPTS + 1, mutationIntent: true });
    expect(await t.mutation(a.adopt, args)).toBe(execution); await t.mutation(a.recover, {}); await flush(t);
    expect(await row(t, execution)).toEqual(exhausted); expect(fetch).not.toHaveBeenCalled();
  });
  it("release of an acknowledged invalidated case preserves positive evidence without granting completion", async () => {
    const t = setup(); remote(); const { id, execution } = await start(t); await flush(t);
    const observed = await row(t, execution); expect(observed.acknowledged).toBe(true);
    await confirm(t, id, "apple", false);
    await t.mutation(a.releaseInvalidated, { ...fence(observed), stageFence: (await stage(t, id, "apple")).fence,
      automationRevision: (await root(t, id)).automationRevision!, evidence: "remote-case", remoteEffects: "reconciled" });
    expect(await row(t, execution)).toMatchObject({ state: "manual", acknowledged: true, mutationIntent: true, claims: observed.claims, attempts: observed.attempts });
    expect((await root(t, id)).apple).toBe(false); expect(changes()).toHaveLength(1);
  });
  it("rejects wrong-owner inventory and stale reconciliation revisions", async () => {
    const t = setup(); remote(); const { id, execution } = await start(t); await flush(t); const s = await row(t, execution);
    await expect(t.query(a.inventory, { id, owner: "other" })).rejects.toThrow("Exact deletion target");
    for (const patch of [{ owner: "other" }, { fence: s.fence - 1 }, { automationRevision: 0 }])
      await expect(t.mutation(a.reconcile, { ...fence(s), evidence: "case", automationRevision: (await root(t, id)).automationRevision!, ...patch })).rejects.toThrow();
    expect((await root(t, id)).apple).toBe(false);
  });
  it.each(["apple", "revenuecat"] as const)("releases invalidated %s hold without completion, preserves budgets and fences late callbacks", async provider => {
    const t = setup(), { id, execution } = await start(t, provider); const claimed = (await t.mutation(a.claim, { execution }))!;
    await confirm(t, id, provider, false);
    const args = { ...fence(claimed), stageFence: (await stage(t, id, provider)).fence,
      automationRevision: (await root(t, id)).automationRevision!, evidence: "remote-effects-case", remoteEffects: "reconciled" as const };
    await expect(t.mutation(a.releaseInvalidated, args)).rejects.toThrow("non-running");
    vi.setSystemTime(Date.now() + LEASE_MS + 1); await t.mutation(a.expire, fence(claimed));
    const expired = await row(t, execution); Object.assign(args, fence(expired), { automationRevision: (await root(t, id)).automationRevision! });
    for (const patch of [{ owner: "other" }, { fence: expired.fence - 1 }, { stageFence: args.stageFence - 1 }, { automationRevision: args.automationRevision - 1 }])
      await expect(t.mutation(a.releaseInvalidated, { ...args, ...patch })).rejects.toThrow();
    await t.mutation(a.releaseInvalidated, args);
    expect(await row(t, execution)).toMatchObject({ state: "manual", fence: expired.fence + 1, mutationIntent: expired.mutationIntent,
      acknowledged: expired.acknowledged, attempts: expired.attempts, claims: expired.claims });
    expect((await root(t, id))[provider]).toBe(false);
    expect(await t.mutation(a.finish, { ...fence(claimed), result: { state: "acknowledgement", code: "customer_delete_queued", httpStatus: 200 } })).toBe(false);
    await confirm(t, id, provider); expect((await root(t, id))[provider]).toBe(true);
    await flush(t); expect(fetch).not.toHaveBeenCalled();
  });
  it("disabled Apple backlog cannot starve ready RevenueCat recovery", async () => {
    const t = setup(); const backlog: Id<"deletionProviderExecutions">[] = [];
    for (let i = 0; i < 17; i++) backlog.push((await start(t)).execution);
    const { execution } = await start(t, "revenuecat");
    // Remove initial dispatches: progress must come from recover, not adoption scheduling.
    await t.run(async ctx => { for (const job of await ctx.db.system.query("_scheduled_functions").collect()) await ctx.scheduler.cancel(job._id); });
    vi.stubEnv("APPLE_DELETION_ENABLED", "false"); remote();
    await t.mutation(a.recover, {}); await flush(t);
    expect(await row(t, execution)).toMatchObject({ state: "observed", absenceObserved: true });
    for (const id of backlog) expect(await row(t, id)).toMatchObject({ state: "queued", claims: 0 });
    expect(vi.mocked(fetch).mock.calls.every(([url]) => String(url).startsWith("https://api.revenuecat.com/"))).toBe(true);
  });
  it.each(["apple", "revenuecat"] as const)("inconsistent flags cannot publish/notify/purge unresolved %s", async provider => {
    const t = setup(), { id, execution } = await start(t, provider);
    await t.run(async ctx => {
      await ctx.db.patch(id, { apple: true, clerk: true, revenuecat: true, gemini: true, residuals: true, completedAt: Date.now() - DELETION_RETENTION_MS, purgeAt: Date.now() });
      for (const st of await ctx.db.query("deletionStages").withIndex("by_request_key", q => q.eq("request", id)).collect()) await ctx.db.patch(st._id, { state: "manual", evidence: "inconsistent" });
    });
    await confirm(t, id, "residuals");
    expect(await t.withIdentity({ tokenIdentifier: owner, subject }).query(internal.deletion.status, {})).toMatchObject({ providersComplete: false });
    expect(await t.run(ctx => ctx.db.query("deletionOutbox").withIndex("by_request", q => q.eq("request", id)).unique())).toMatchObject({ providersComplete: false });
    vi.stubEnv("DELETION_EMAIL_ENABLED", "true"); vi.stubEnv("DELETION_CONTACT_RETENTION_APPROVED", "true");
    vi.stubEnv("RESEND_DELETION_CONFIG_REF", "synthetic-route");
    await t.run(ctx => ctx.db.insert("deletionContacts", { request: id, owner, subject, issuer, instance, email: "alice@example.com", code: "verified_primary", capturedAt: Date.now() }));
    expect(await t.mutation(internal.deletionNotifications.freeze, { id, owner })).toBeNull();
    // Reintroduce an expired deadline to exercise purge's own independent guard.
    await t.run(ctx => ctx.db.patch(id, { completedAt: Date.now() - DELETION_RETENTION_MS, purgeAt: Date.now() }));
    await t.mutation(internal.deletionRetention.purgeExpired, {});
    expect(await row(t, execution)).not.toBeNull(); expect((await root(t, id)).purgeAt).toBeUndefined(); expect(fetch).not.toHaveBeenCalled();
  });
  it("complete mock Apple -> Google -> Clerk -> RC -> operator residuals enqueues only, then purges manual rows", async () => {
    const t = setup(); remote({ google: true }); const { id, execution: appleExecution } = await start(t); await flush(t); await reconcile(t, appleExecution);
    await t.run(ctx => ctx.db.insert("deletionContacts", { request: id, owner, subject, issuer, instance,
      code: "verified_primary", email: "alice@example.com", capturedAt: Date.now() }));
    const clerkExecution = await t.mutation(internal.clerkExecution.adopt, { id, owner, stageFence: 1,
      appleFence: (await stage(t, id, "apple")).fence, appleEvidence: "apple-case", disposition: "revocation_verified" });
    await flush(t); const clerk = (await t.run(ctx => ctx.db.get(clerkExecution)))!;
    expect(clerk).toMatchObject({ googleComplete: true });
    expect((await root(t, id)).googleStatus).toBe("acknowledged");
    await t.mutation(internal.clerkExecution.reconcile, { execution: clerkExecution, owner, fence: clerk.fence, evidence: "clerk-case" });
    const rcExecution = await t.mutation(a.adopt, { id, owner, provider: "revenuecat", stageFence: 1, safetyEvidence: "rc-quiescence-case" });
    await flush(t); await reconcile(t, rcExecution);
    for (const kind of ["gemini", "residuals"] as const) await confirm(t, id, kind);
    expect(await t.withIdentity({ tokenIdentifier: owner, subject }).query(internal.deletion.status, {})).toMatchObject({ providersComplete: true });
    const completed = await root(t, id); expect(completed.purgeAt).toBe(completed.completedAt! + DELETION_RETENTION_MS);
    expect(await t.run(ctx => ctx.db.query("deletionOutbox").unique())).toMatchObject({ classification: "scope_complete", providersComplete: true });
    vi.stubEnv("DELETION_EMAIL_ENABLED", "true"); vi.stubEnv("DELETION_CONTACT_RETENTION_APPROVED", "true"); vi.stubEnv("RESEND_DELETION_CONFIG_REF", "synthetic-route");
    const send = await t.mutation(internal.deletionNotifications.freeze, { id, owner }); expect(send).not.toBeNull();
    expect(await t.run(ctx => ctx.db.get(send!))).toMatchObject({ state: "queued", attempts: 0, delivery: "pending" });
    vi.stubEnv("DELETION_EMAIL_ENABLED", "false"); // Never dispatch a notification, even to a mock provider.
    const other = await t.run(ctx => ctx.db.insert("deletions", { owner: "other|user_bob", subject: "user_bob", requestedAt: Date.now(), updatedAt: Date.now(),
      localComplete: false, apple: false, clerk: false, revenuecat: false, gemini: false, residuals: false }));
    vi.setSystemTime(completed.purgeAt!); await t.mutation(internal.deletionRetention.purgeExpired, {}); await flush(t);
    for (const key of [id, appleExecution, rcExecution, clerkExecution, send!]) expect(await t.run(ctx => ctx.db.get(key))).toBeNull();
    expect(await t.run(ctx => ctx.db.get(other))).not.toBeNull();
    const receipts = await t.run(ctx => ctx.db.query("deletionReceipts").collect()); expect(receipts).toHaveLength(1); expect(JSON.stringify(receipts)).not.toContain(subject);
    expect(changes().map(([url]) => String(url))).toEqual([
      "https://appleid.apple.com/auth/revoke", "https://oauth2.googleapis.com/revoke",
      `https://api.clerk.com/v1/users/${subject}`, `https://api.revenuecat.com${rcPath}`,
    ]);
    expect(vi.mocked(fetch).mock.calls.some(([url]) => String(url).includes("resend"))).toBe(false);
  });
});
