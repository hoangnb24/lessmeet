import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "../../convex/schema";
import { internal } from "../../convex/_generated/api";
import type { Doc, Id } from "../../convex/_generated/dataModel";
import { LEASE_MS } from "../../convex/deletionAdapter";

const modules = import.meta.glob(["../../convex/**/*.{ts,js}", "!../../convex/**/*.d.ts", "!../../convex/auth.config.ts"]);
const setup = () => convexTest({ schema, modules, transactionLimits: true });
type T = ReturnType<typeof setup>;
type Row = Doc<"deletionClerkExecutions">;
const a = internal.clerkExecution;
const issuer = "https://synthetic.clerk.accounts.dev", subject = "user_alice", owner = `${issuer}|${subject}`;
const instance = "ins_synthetic", client = "synthetic.apps.googleusercontent.com";
const accounts = [{ externalAccountId: "ext_a", providerUserId: "google_a" }, { externalAccountId: "ext_b", providerUserId: "google_b" }];
const fence = (s: Row) => ({ execution: s._id, owner, fence: s.fence });
const row = async (t: T, id: Id<"deletionClerkExecutions">) => (await t.run(ctx => ctx.db.get(id)))!;
beforeEach(() => {
  vi.useFakeTimers(); vi.setSystemTime(new Date("2026-10-05T00:00:00Z"));
  for (const key of ["DELETION_AUTOMATION_ENABLED", "CLERK_DELETION_ENABLED", "GOOGLE_DELETION_ENABLED"]) vi.stubEnv(key, "true");
  vi.stubEnv("CLERK_JWT_ISSUER_DOMAIN", issuer); vi.stubEnv("CLERK_CONTACT_ISSUER", issuer);
  vi.stubEnv("CLERK_CONTACT_INSTANCE_ID", instance); vi.stubEnv("CLERK_DELETION_CONFIG_REF", "clerk-v1");
  vi.stubEnv("CLERK_DELETION_SECRET_KEY", "synthetic-secret"); vi.stubEnv("GOOGLE_DELETION_CONFIG_REF", "google-v1");
  vi.stubEnv("GOOGLE_DELETION_CLIENT_ID", client); vi.stubEnv("GOOGLE_DELETION_AUTHORIZED_PARTY_ID", client);
  vi.stubEnv("GOOGLE_DELETION_PROJECT_REF", "synthetic-project");
  vi.stubGlobal("fetch", vi.fn(() => { throw new Error("Live network forbidden"); }));
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllEnvs(); vi.unstubAllGlobals(); });
async function seed(t: T) {
  const id = await t.run(async ctx => {
    const id = await ctx.db.insert("deletions", { owner, subject, requestedAt: Date.now(), updatedAt: Date.now(), localComplete: true,
      clerk: false, apple: true, appleEvidence: "apple-case", revenuecat: false, gemini: false, residuals: false,
      automationRevision: 1, discoveryComplete: true });
    for (const kind of ["clerk", "apple"] as const) await ctx.db.insert("deletionStages", { request: id, owner, key: kind, kind, target: subject,
      config: "unimplemented", state: kind === "apple" ? "manual" : "blocked", fence: kind === "apple" ? 3 : 1, attempts: 1,
      nextAttemptAt: Date.now(), code: kind === "apple" ? "operator_evidence" : "adapter_unimplemented",
      ...(kind === "apple" ? { evidence: "apple-case" } : {}), updatedAt: Date.now() });
    await ctx.db.insert("deletionContacts", { request: id, owner, subject, issuer, instance, code: "verified_primary",
      email: "alice@example.com", capturedAt: Date.now() });
    return id;
  });
  const args = { id, owner, stageFence: 1, appleFence: 3, appleEvidence: "apple-case", disposition: "revocation_verified" as const };
  return { id, args };
}
async function start(t: T) { const s = await seed(t); return { ...s, execution: await t.mutation(a.adopt, s.args) }; }
async function flush(t: T) {
  await t.finishAllScheduledFunctions(() => vi.runOnlyPendingTimers(), 200);
  expect((await t.run(ctx => ctx.db.system.query("_scheduled_functions").collect())).filter(s => s.state.kind === "failed")).toEqual([]);
}
function provider(options: { count?: number; revoke?: "unknown" | "rejected"; lookup?: "unknown"; inventory?: "unknown" | "malformed"; drift?: boolean } = {}) {
  let deleted = false, ack = 0;
  const selected = accounts.slice(0, options.count ?? 1), events: string[] = [];
  const metadata = () => selected.map(a => ({ object: "external_account", provider: "oauth_google", id: a.externalAccountId,
    provider_user_id: options.drift && ack ? `${a.providerUserId}_changed` : a.providerUserId, verification: { status: "verified" } }));
  vi.mocked(fetch).mockImplementation(async (url, init) => {
    const u = new URL(String(url)); events.push(`${init?.method} ${u.pathname}`);
    if (u.pathname === "/v1/instance") return Response.json({ object: "instance", id: instance });
    if (u.pathname === `/v1/users/${subject}`) {
      if (init?.method === "DELETE") { deleted = true; return Response.json({ object: "user", id: subject, deleted: true }); }
      if (deleted) return Response.json({ errors: [{ code: "resource_not_found" }] }, { status: 404 });
      if (options.inventory === "unknown") throw new Error("lost read");
      return Response.json({ object: "user", id: subject, external_accounts: options.inventory === "malformed" ? null : metadata() });
    }
    if (u.pathname.includes("/oauth_access_tokens/")) {
      if (options.lookup) throw new Error("lookup lost");
      return Response.json(selected.map(a => ({ object: "oauth_access_token", provider: "oauth_google", external_account_id: a.externalAccountId,
        provider_user_id: a.providerUserId, token: `token_${a.providerUserId}` })));
    }
    if (u.pathname === "/tokeninfo") return Response.json({ sub: u.searchParams.get("access_token")!.replace("token_", ""),
      aud: client, azp: client, expires_in: 3600, scope: "openid email profile" });
    if (u.pathname === "/revoke") {
      if (options.revoke === "unknown") throw new Error("POST response lost");
      if (options.revoke === "rejected") return new Response("", { status: 400 });
      ack++; return new Response("", { status: 200 });
    }
    if (u.pathname === "/v1/sessions") return Response.json([]);
    throw new Error("Unexpected mocked route");
  });
  return events;
}
const lookups = () => vi.mocked(fetch).mock.calls.filter(([url]) => String(url).includes("oauth_access_tokens"));
const mutations = () => vi.mocked(fetch).mock.calls.filter(([, init]) => init?.method !== "GET");

describe("Google prerequisite execution", () => {
  it("acknowledges one account before any Clerk mutation, with no token lookup after acknowledgement", async () => {
    const count = 1;
    const t = setup(), events = provider({ count }), { id, execution } = await start(t); await flush(t);
    const s = await row(t, execution);
    expect(s).toMatchObject({ state: "observed", googleComplete: true, googleIndex: count, userAbsenceObserved: true });
    expect(s.googleAccounts!.every(a => a.acknowledged)).toBe(true);
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ googleRequired: true, googleStatus: "acknowledged", googleEvidence: s.googleEvidence });
    const deletion = events.indexOf(`DELETE /v1/users/${subject}`);
    expect(events.filter(e => e === "POST /revoke")).toHaveLength(count);
    expect(events.lastIndexOf("POST /revoke")).toBeLessThan(deletion);
    expect(events.slice(events.indexOf("POST /revoke") + 1).some(e => e.includes("oauth_access_tokens"))).toBe(false);
    expect(events.slice(deletion + 1)).toEqual(["GET /v1/instance", `GET /v1/users/${subject}`]);
    expect(JSON.stringify(s)).not.toContain("token_");
  });
  it("multiple Google accounts stop before token lookup and cannot discard known targets through read recovery", async () => {
    const t = setup(); provider({ count: 2 }); const { id, execution } = await start(t); await flush(t);
    const s = await row(t, execution);
    expect(s).toMatchObject({ phase: "inventoryGoogle", state: "blocked", code: "google_multiple_accounts_operator_required" });
    expect(s.googleAccounts).toHaveLength(2);
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ googleStatus: "exception", clerk: false });
    provider({ count: 1 });
    await expect(t.mutation(a.observeGoogleAgain, fence(s))).rejects.toThrow();
    await expect(t.mutation(a.resolveGoogle, { ...fence(s), stageFence: s.stageFence, googleConfig: s.googleConfig!,
      evidence: "one-target-only", disposition: "revocation_verified", target: accounts[0] })).rejects.toThrow();
    await t.mutation(a.recover, {}); await flush(t);
    expect(lookups()).toEqual([]); expect(mutations()).toEqual([]);
    expect((await row(t, execution)).googleAccounts).toHaveLength(2);
  });
  it.each(["queued", "blocked"] as const)("old multiaccount %s state cannot fetch remaining tokens after an acknowledgement", async state => {
    const t = setup(), { execution } = await start(t);
    await t.run(ctx => ctx.db.patch(execution, { state, phase: "revokeGoogle", googleIndex: 1,
      code: "google_revoke_unresolved", mutationUncertain: state === "blocked",
      googleAccounts: [{ ...accounts[0], acknowledged: true, evidence: "prior-ack" }, { ...accounts[1], acknowledged: false }] }));
    const s = await row(t, execution);
    if (state === "queued") expect(await t.mutation(a.claim, { execution })).toBeNull();
    else await expect(t.mutation(a.resolveGoogle, { ...fence(s), stageFence: s.stageFence, googleConfig: s.googleConfig!,
      evidence: "second-target", disposition: "revocation_verified", target: accounts[1] })).rejects.toThrow();
    await flush(t); expect(fetch).not.toHaveBeenCalled();
  });
  it("empty inventory waits for operator evidence, not automatic non-applicability", async () => {
    const t = setup(); provider({ count: 0 }); const { id, execution } = await start(t); await flush(t);
    expect(await row(t, execution)).toMatchObject({ phase: "inventoryGoogle", state: "blocked", googleAccounts: [], googleComplete: false });
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ googleStatus: "pending" });
    expect(mutations()).toEqual([]); expect(lookups()).toEqual([]);
  });
  it.each(["unknown", "rejected"] as const)("%s revoke stops downstream and never replays", async revoke => {
    const t = setup(); provider({ revoke }); const { id, execution } = await start(t); await flush(t);
    const s = await row(t, execution);
    expect(s).toMatchObject({ phase: "revokeGoogle", state: "blocked", mutationUncertain: true, googleComplete: false });
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ googleStatus: "exception" });
    await t.mutation(a.recover, {}); await flush(t);
    await expect(t.mutation(a.observeGoogleAgain, fence(s))).rejects.toThrow();
    expect(mutations()).toHaveLength(1); expect(lookups()).toHaveLength(1);
  });
  it("unknown token lookup never retries lookup or submits POST", async () => {
    const t = setup(); provider({ lookup: "unknown" }); const { execution } = await start(t); await flush(t);
    expect(await row(t, execution)).toMatchObject({ phase: "revokeGoogle", state: "blocked" });
    await t.mutation(a.recover, {}); await flush(t); expect(lookups()).toHaveLength(1); expect(mutations()).toEqual([]);
  });
  it("expired revoke rejects stale acknowledgement and remains an exception", async () => {
    const t = setup(), { id, execution } = await start(t);
    await t.run(ctx => ctx.db.patch(execution, { phase: "revokeGoogle", googleAccounts: [{ ...accounts[0], acknowledged: false }] }));
    const s = (await t.mutation(a.claim, { execution }))!;
    vi.setSystemTime(Date.now() + LEASE_MS + 1); await t.mutation(a.expire, fence(s));
    expect(await t.mutation(a.finishGoogle, { ...fence(s), result: { state: "acknowledgement", code: "google_revoke_acknowledged", httpStatus: 200 } })).toBe(false);
    expect(await row(t, execution)).toMatchObject({ state: "blocked", phase: "revokeGoogle", mutationUncertain: true });
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ googleStatus: "exception" });
    await flush(t); expect(fetch).not.toHaveBeenCalled();
  });
  it("inventory drift after acknowledgement clears proof and prevents Clerk deletion", async () => {
    const t = setup(); provider({ drift: true }); const { id, execution } = await start(t); await flush(t);
    expect(await row(t, execution)).toMatchObject({ state: "blocked", phase: "verifyGoogleInventory", googleComplete: false });
    expect((await t.run(ctx => ctx.db.get(id)))!.googleEvidence).toBeUndefined();
    expect(mutations()).toHaveLength(1); expect(lookups()).toHaveLength(1);
  });
  it.each(["GOOGLE_DELETION_ENABLED", "GOOGLE_DELETION_CLIENT_ID", "GOOGLE_DELETION_AUTHORIZED_PARTY_ID", "GOOGLE_DELETION_PROJECT_REF", "GOOGLE_DELETION_CONFIG_REF"])("new adoption requires trusted %s", async key => {
    const t = setup(), { args } = await seed(t); vi.stubEnv(key, "");
    await expect(t.mutation(a.adopt, args)).rejects.toThrow("Google execution is disabled or unbound"); expect(fetch).not.toHaveBeenCalled();
  });
  it.each(["config", "gate", "stage", "apple", "contact", "phase", "fence", "identity", "target"])("checks exact %s before token lookup", async kind => {
    const t = setup(); provider(); const { id, execution } = await start(t);
    const original = vi.mocked(fetch).getMockImplementation()!;
    let reads = 0;
    vi.mocked(fetch).mockImplementation(async (url, init) => {
      if (String(url).endsWith(`/users/${subject}`) && ++reads === 3) {
        if (kind === "config") vi.stubEnv("GOOGLE_DELETION_CONFIG_REF", "changed");
        else if (kind === "gate") vi.stubEnv("GOOGLE_DELETION_ENABLED", "false");
        else await t.run(async ctx => {
          const s = (await ctx.db.get(execution))!;
          if (kind === "stage" || kind === "apple") { const target = kind === "stage" ? s.stage : s.appleStage;
            const stage = (await ctx.db.get(target))!; await ctx.db.patch(target, { fence: stage.fence + 1 }); }
          else if (kind === "contact") await ctx.db.delete((await ctx.db.query("deletionContacts").unique())!._id);
          else if (kind === "phase") await ctx.db.patch(execution, { phase: "inventoryGoogle" });
          else if (kind === "fence") await ctx.db.patch(execution, { fence: s.fence + 1 });
          else if (kind === "target") await ctx.db.patch(execution, { googleAccounts: [{ ...accounts[1], acknowledged: false }] });
          else await ctx.db.patch(id, { subject: "user_other" });
        });
      }
      return original(url, init);
    });
    await flush(t); expect(lookups()).toEqual([]); expect(mutations()).toEqual([]);
    expect((await t.run(ctx => ctx.db.get(id)))!.googleEvidence).toBeUndefined();
  });
  it.each(["inventoryGoogle", "verifyGoogleInventory"] as const)("read-only %s recovery preserves budgets and never looks up tokens", async phase => {
    const t = setup(); provider({ inventory: "malformed" }); const { execution } = await start(t);
    await t.run(ctx => ctx.db.patch(execution, { phase, ...(phase === "verifyGoogleInventory" ? {
      googleAccounts: [{ ...accounts[0], acknowledged: true, evidence: "google-ack" }], googleIndex: 1 } : {}) }));
    await flush(t); const old = await row(t, execution); expect(old.state).toBe("blocked");
    vi.stubEnv("GOOGLE_DELETION_CONFIG_REF", "changed");
    await expect(t.mutation(a.observeGoogleAgain, fence(old))).rejects.toThrow();
    vi.stubEnv("GOOGLE_DELETION_CONFIG_REF", "google-v1");
    await t.mutation(a.observeGoogleAgain, fence(old));
    const queued = await row(t, execution); expect(queued.attempts).toBe(old.attempts); expect(queued.claims).toBe(old.claims);
    await flush(t); expect(lookups()).toEqual([]); expect(mutations()).toEqual([]);
    expect((await row(t, execution)).attempts).toBe(old.attempts + 1);
  });
  it("unknown inventory retries within the bounded read budget without mutation", async () => {
    const t = setup(); provider({ inventory: "unknown" }); const { execution } = await start(t);
    await t.run(ctx => ctx.db.patch(execution, { phase: "inventoryGoogle" }));
    await flush(t); expect(await row(t, execution)).toMatchObject({ state: "exhausted", attempts: 8, claims: 8 });
    expect(lookups()).toEqual([]); expect(mutations()).toEqual([]);
  });
  it("checks unchanged metadata again at the Clerk authorization boundary", async () => {
    const t = setup(); provider(); const { id, execution } = await start(t);
    const original = vi.mocked(fetch).getMockImplementation()!; let reads = 0;
    vi.mocked(fetch).mockImplementation(async (url, init) => {
      const response = await original(url, init);
      if (String(url).endsWith(`/users/${subject}`) && init?.method === "GET" && ++reads === 7) {
        const body = await response.json(); body.external_accounts[0].provider_user_id = "changed"; return Response.json(body);
      }
      return response;
    });
    await flush(t); expect(await row(t, execution)).toMatchObject({ state: "blocked", googleComplete: false });
    const d = (await t.run(ctx => ctx.db.get(id)))!; expect(d.googleStatus).toBe("exception"); expect(d.googleEvidence).toBeUndefined();
    expect(mutations().map(([url]) => String(url))).toEqual(["https://oauth2.googleapis.com/revoke"]);
    expect(lookups()).toHaveLength(1);
  });
  it.each(["owner", "fence", "stageFence", "googleConfig", "evidence", "target", "disposition"])("operator resolution rejects wrong %s", async kind => {
    const t = setup(); provider({ revoke: "unknown" }); const { execution } = await start(t); await flush(t);
    const s = await row(t, execution);
    const args = { ...fence(s), stageFence: s.stageFence, googleConfig: s.googleConfig!, evidence: "operator-case",
      disposition: "revocation_verified" as "revocation_verified" | "historical_non_applicability_verified", target: accounts[0] };
    if (kind === "owner") args.owner = "other";
    if (kind === "fence") args.fence++;
    if (kind === "stageFence") args.stageFence++;
    if (kind === "googleConfig") args.googleConfig = "other";
    if (kind === "evidence") args.evidence = "token/private";
    if (kind === "target") args.target = accounts[1];
    if (kind === "disposition") args.disposition = "historical_non_applicability_verified";
    await expect(t.mutation(a.resolveGoogle, args)).rejects.toThrow(); expect(await row(t, execution)).toEqual(s);
  });
  it("operator resolves only the ambiguous target and does not replay its lookup or POST", async () => {
    const t = setup(); provider({ revoke: "unknown" }); const { id, execution } = await start(t); await flush(t);
    const s = await row(t, execution);
    provider();
    await t.mutation(a.resolveGoogle, { ...fence(s), stageFence: s.stageFence, googleConfig: s.googleConfig!, evidence: "target-a-case",
      disposition: "revocation_verified", target: accounts[0] });
    const queued = await row(t, execution); expect(queued.googleIndex).toBe(1); expect(queued.googleAccounts!.map(a => a.acknowledged)).toEqual([true]);
    expect(queued.phase).toBe("verifyGoogleInventory");
    expect(queued.attempts).toBe(s.attempts); expect(queued.claims).toBe(s.claims);
    await flush(t); expect(await row(t, execution)).toMatchObject({ state: "observed", googleComplete: true });
    const verified = await row(t, execution);
    expect(verified.googleAccounts![0].evidence).toBe("target-a-case");
    expect(verified.googleEvidence).toMatch(/^google_/);
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ googleStatus: "acknowledged" });
    expect(lookups()).toHaveLength(1);
    expect(mutations().filter(([url]) => String(url).endsWith("/revoke"))).toHaveLength(1);
  });
  it("only observed empty inventory can receive historical non-applicability", async () => {
    const t = setup(); provider({ count: 0 }); const { id, execution } = await start(t); await flush(t);
    const s = await row(t, execution);
    await t.mutation(a.resolveGoogle, { ...fence(s), stageFence: s.stageFence, googleConfig: s.googleConfig!, evidence: "historical-case",
      disposition: "historical_non_applicability_verified" });
    await flush(t); const done = await row(t, execution);
    expect(done).toMatchObject({ state: "observed", googleNotApplicable: true, googleComplete: true, googleOperatorEvidence: "historical-case" });
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ googleStatus: "not_applicable", googleEvidence: done.googleEvidence });
    expect(lookups()).toEqual([]); expect(mutations()).toHaveLength(1);
  });
  it.each(["deleteUser", "revokeSession"] as const)("legacy %s without Google proof cannot dispatch", async phase => {
    const t = setup(), { id, args, execution } = await start(t);
    await t.run(async ctx => {
      await ctx.db.patch(execution, { phase, googleConfig: undefined, googleComplete: undefined });
      await ctx.db.patch(id, { googleRequired: undefined, googleStatus: undefined });
    });
    vi.stubEnv("GOOGLE_DELETION_ENABLED", "false"); expect(await t.mutation(a.adopt, args)).toBe(execution);
    await flush(t); expect((await row(t, execution)).state).toBe("blocked"); expect(fetch).not.toHaveBeenCalled();
  });
  it("legacy read-only observation and reconciliation remain allowed without Google proof", async () => {
    const t = setup(), { id, execution } = await start(t);
    await t.run(async ctx => {
      await ctx.db.patch(execution, { state: "blocked", phase: "observeUser", googleConfig: undefined, googleComplete: undefined,
        inventoryComplete: true, mutationUncertain: true });
      await ctx.db.patch(id, { googleRequired: undefined, googleStatus: undefined });
    });
    vi.stubEnv("GOOGLE_DELETION_ENABLED", "false");
    vi.mocked(fetch).mockImplementation(async url => String(url).endsWith("/instance") ? Response.json({ object: "instance", id: instance }) :
      Response.json({ errors: [{ code: "resource_not_found" }] }, { status: 404 }));
    await t.mutation(a.observeAgain, fence(await row(t, execution))); await flush(t);
    await t.mutation(a.reconcile, { ...fence(await row(t, execution)), evidence: "historical-clerk-case" });
    const d = (await t.run(ctx => ctx.db.get(id)))!; expect(d.clerk).toBe(true); expect(d.googleEvidence).toBeUndefined();
    expect(lookups()).toEqual([]); expect(mutations()).toEqual([]);
  });
  it.each(["config", "gate", "stage", "contact", "evidence", "target"])("withdrawn %s at the final Google POST guard prevents dispatch", async kind => {
    const t = setup(); provider(); const { id, execution } = await start(t);
    const original = vi.mocked(fetch).getMockImplementation()!;
    vi.mocked(fetch).mockImplementation(async (url, init) => {
      if (String(url).includes("/tokeninfo?")) {
        if (kind === "config") vi.stubEnv("GOOGLE_DELETION_CLIENT_ID", "changed.apps.googleusercontent.com");
        else if (kind === "gate") vi.stubEnv("GOOGLE_DELETION_ENABLED", "false");
        else await t.run(async ctx => {
          const s = (await ctx.db.get(execution))!;
          if (kind === "stage") await ctx.db.patch(s.stage, { fence: s.stageFence + 1 });
          else if (kind === "contact") await ctx.db.delete((await ctx.db.query("deletionContacts").unique())!._id);
          else if (kind === "evidence") await ctx.db.patch(id, { appleEvidence: "changed" });
          else await ctx.db.patch(execution, { googleAccounts: [{ ...accounts[1], acknowledged: false }] });
        });
      }
      return original(url, init);
    });
    await flush(t); expect(mutations()).toEqual([]); expect(lookups()).toHaveLength(1);
    expect(await row(t, execution)).toMatchObject({ state: "blocked", googleComplete: false });
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ googleStatus: "exception" });
    await t.mutation(a.recover, {}); await flush(t); expect(lookups()).toHaveLength(1);
  });
  it("an uncertain revoke cannot be claimed even if its state was incorrectly queued", async () => {
    const t = setup(); provider({ revoke: "unknown" }); const { execution } = await start(t); await flush(t);
    await t.run(ctx => ctx.db.patch(execution, { state: "queued" }));
    expect(await t.mutation(a.claim, { execution })).toBeNull();
    expect(await row(t, execution)).toMatchObject({ state: "blocked", code: "google_revoke_unresolved" });
    expect(lookups()).toHaveLength(1); expect(mutations()).toHaveLength(1);
  });
  it.each(["running", "config", "stage", "apple", "contact", "gate"])("manual resolution requires current %s", async kind => {
    const t = setup(); provider({ revoke: "unknown" }); const { execution } = await start(t); await flush(t);
    const s = await row(t, execution);
    if (kind === "config") vi.stubEnv("GOOGLE_DELETION_PROJECT_REF", "changed");
    else if (kind === "gate") vi.stubEnv("GOOGLE_DELETION_ENABLED", "false");
    else await t.run(async ctx => {
      if (kind === "running") await ctx.db.patch(execution, { state: "running", leaseUntil: Date.now() + LEASE_MS });
      else if (kind === "contact") await ctx.db.delete((await ctx.db.query("deletionContacts").unique())!._id);
      else { const target = kind === "stage" ? s.stage : s.appleStage;
        const stage = (await ctx.db.get(target))!; await ctx.db.patch(target, { fence: stage.fence + 1 }); }
    });
    await expect(t.mutation(a.resolveGoogle, { ...fence(s), stageFence: s.stageFence, googleConfig: s.googleConfig!,
      evidence: "operator-case", disposition: "revocation_verified", target: accounts[0] })).rejects.toThrow();
    expect(lookups()).toHaveLength(1); expect(mutations()).toHaveLength(1);
  });
  it.each(["code", "status", "state"])("invalid revoke acknowledgement %s cannot advance", async kind => {
    const t = setup(), { execution } = await start(t);
    await t.run(ctx => ctx.db.patch(execution, { phase: "revokeGoogle", googleAccounts: [{ ...accounts[0], acknowledged: false }] }));
    const s = (await t.mutation(a.claim, { execution }))!;
    await t.mutation(a.finishGoogle, { ...fence(s), result: { state: kind === "state" ? "inventory" : "acknowledgement",
      code: kind === "code" ? "wrong" : "google_revoke_acknowledged", httpStatus: kind === "status" ? 201 : 200 } });
    expect(await row(t, execution)).toMatchObject({ state: "blocked", phase: "revokeGoogle", googleComplete: false, googleIndex: 0 });
    await flush(t); expect(fetch).not.toHaveBeenCalled();
  });
  it("sorts exact identities and rejects duplicate inventory without lookup", async () => {
    const t = setup(), { execution } = await start(t);
    await t.run(ctx => ctx.db.patch(execution, { phase: "inventoryGoogle" }));
    const s = (await t.mutation(a.claim, { execution }))!;
    await t.mutation(a.finishGoogle, { ...fence(s), result: { state: "inventory", code: "google_inventory_observed", httpStatus: 200,
      accounts: [accounts[1], accounts[0]] } });
    expect((await row(t, execution)).googleAccounts!.map(a => a.externalAccountId)).toEqual(["ext_a", "ext_b"]);
    const other = setup(), target = await start(other);
    await other.run(ctx => ctx.db.patch(target.execution, { phase: "inventoryGoogle" }));
    const claimed = (await other.mutation(a.claim, { execution: target.execution }))!;
    await other.mutation(a.finishGoogle, { ...fence(claimed), result: { state: "inventory", code: "google_inventory_observed", httpStatus: 200,
      accounts: [accounts[0], accounts[0]] } });
    expect(await row(other, target.execution)).toMatchObject({ state: "blocked", googleComplete: false });
    expect(fetch).not.toHaveBeenCalled();
  });
  it.each(["target", "nonapp"])("preserves %s operator evidence through verification and invalidation", async kind => {
    const t = setup(); provider(kind === "target" ? { revoke: "unknown" } : { count: 0 });
    const { id, execution } = await start(t); await flush(t); const s = await row(t, execution);
    provider({ count: kind === "target" ? 1 : 0 });
    await t.mutation(a.resolveGoogle, { ...fence(s), stageFence: s.stageFence, googleConfig: s.googleConfig!, evidence: "durable-operator-case",
      disposition: kind === "target" ? "revocation_verified" : "historical_non_applicability_verified",
      ...(kind === "target" ? { target: accounts[0] } : {}) });
    await flush(t); const verified = await row(t, execution);
    expect(verified.googleComplete).toBe(true);
    expect(kind === "target" ? verified.googleAccounts![0].evidence : verified.googleOperatorEvidence).toBe("durable-operator-case");
    await t.mutation(internal.deletion.confirm, { id, owner, stage: "clerk", complete: false, evidence: "reopened-case",
      automationRevision: (await t.run(ctx => ctx.db.get(id)))!.automationRevision });
    const stage = (await t.run(ctx => ctx.db.get(verified.stage)))!;
    await t.mutation(a.releaseInvalidated, { ...fence(verified), stageFence: stage.fence,
      automationRevision: (await t.run(ctx => ctx.db.get(id)))!.automationRevision!, evidence: "remote-effects-case", remoteEffects: "reconciled" });
    const invalid = await row(t, execution);
    expect(invalid.googleComplete).toBe(false); expect(invalid.googleEvidence).toBeUndefined();
    expect(kind === "target" ? invalid.googleAccounts![0].evidence : invalid.googleOperatorEvidence).toBe("durable-operator-case");
    const d = (await t.run(ctx => ctx.db.get(id)))!; expect(d.googleStatus).toBe("exception"); expect(d.googleEvidence).toBeUndefined();
  });
  it("withdrawn ledger proof before Clerk dispatch prevents deletion without token lookup", async () => {
    const t = setup(); provider(); const { id, execution } = await start(t);
    const original = vi.mocked(fetch).getMockImplementation()!; let reads = 0;
    vi.mocked(fetch).mockImplementation(async (url, init) => {
      if (String(url).endsWith(`/users/${subject}`) && init?.method === "GET" && ++reads === 6)
        await t.run(ctx => ctx.db.patch(id, { googleEvidence: undefined }));
      return original(url, init);
    });
    await flush(t); expect(await row(t, execution)).toMatchObject({ state: "blocked", googleComplete: false });
    expect(mutations().map(([url]) => String(url))).toEqual(["https://oauth2.googleapis.com/revoke"]);
    expect(lookups()).toHaveLength(1);
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ googleStatus: "exception" });
  });
});
