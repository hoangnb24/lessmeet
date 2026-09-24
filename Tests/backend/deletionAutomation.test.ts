import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "../../convex/schema";
import { internal } from "../../convex/_generated/api";
import type { Doc, Id } from "../../convex/_generated/dataModel";
import { LEASE_MS, MAX_ATTEMPTS } from "../../convex/deletionAdapter";
import crons from "../../convex/crons";

const modules = import.meta.glob(["../../convex/**/*.{ts,js}", "!../../convex/**/*.d.ts", "!../../convex/auth.config.ts"]);
const owner = "issuer|alice", config = "synthetic-project-v1";
function setup() {
  const t = convexTest({ schema, modules, transactionLimits: true });
  return { t, alice: t.withIdentity({ tokenIdentifier: owner, subject: "alice" }) };
}
type T = ReturnType<typeof setup>["t"];
async function request(t: T) {
  await t.withIdentity({ tokenIdentifier: owner, subject: "alice" }).mutation(internal.deletion.request, {});
  return (await t.run(ctx => ctx.db.query("deletions").withIndex("by_owner", q => q.eq("owner", owner)).unique()))!;
}
async function current(t: T, id: Id<"deletions">) { return (await t.run(ctx => ctx.db.get(id)))!; }
async function work(t: T, options: { who?: string; legacy?: boolean; unknownGeneration?: boolean; file?: string; active?: boolean } = {}) {
  const who = options.who ?? owner;
  if (options.legacy) return t.run(ctx => ctx.db.insert("deletionWork", {
    owner: who, kind: "gemini", startedAt: Date.now(), finished: true, ambiguous: true,
    ...(options.file ? { file: options.file, fileDeleted: false } : {}),
  }));
  const id = await t.mutation(internal.deletion.beginWork, { owner: who, kind: "gemini" });
  if (options.file) await t.mutation(internal.deletion.track, { id, file: options.file });
  await t.mutation(internal.deletion.generation, { id, phase: "started" });
  if (!options.unknownGeneration) await t.mutation(internal.deletion.generation, { id, phase: "finished" });
  if (!options.active) await t.mutation(internal.deletion.finishWork, { id, ambiguous: true, fileDeleted: false });
  return id;
}
async function flush(t: T) {
  await t.finishAllScheduledFunctions(() => vi.runOnlyPendingTimers(), 100);
  const jobs = await t.run(ctx => ctx.db.system.query("_scheduled_functions").collect());
  expect(jobs.filter(job => job.state.kind === "failed")).toEqual([]);
}
async function stages(t: T, id: Id<"deletions">) {
  return t.run(ctx => ctx.db.query("deletionStages").withIndex("by_request_key", q => q.eq("request", id)).collect());
}
// Seed a claimable frozen target without invoking a worker. Used for crash/manual-race probes.
async function frozenStage(t: T, id: Id<"deletions">, workId: Id<"deletionWork">, state: "queued" | "retry" = "queued") {
  return t.run(async ctx => {
    const w = (await ctx.db.get(workId))!;
    return ctx.db.insert("deletionStages", { request: id, owner, key: `file:${workId}`, kind: "geminiFile", target: w.file!,
      config, work: workId, state, attempts: 0, fence: 0, nextAttemptAt: Date.now(), updatedAt: Date.now() });
  });
}
function fence(s: Doc<"deletionStages">) { return { id: s._id, owner: s.owner, fence: s.fence, target: s.target, config: s.config }; }
beforeEach(() => {
  vi.useFakeTimers(); vi.setSystemTime(new Date("2026-09-23T00:00:00Z"));
  vi.stubEnv("ACCOUNT_DELETION_ENABLED", "true");
  vi.stubEnv("DELETION_AUTOMATION_ENABLED", "true");
  vi.stubEnv("GEMINI_DELETION_PROJECT_REF", config);
  vi.stubEnv("GEMINI_API_KEY", "synthetic-only");
  vi.stubGlobal("fetch", vi.fn(() => { throw new Error("External network forbidden"); }));
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); });

describe("scheduled deletion automation", () => {
  it("is separately default-off; old intake/cleanup and manual schema rows remain usable", async () => {
    vi.stubEnv("DELETION_AUTOMATION_ENABLED", undefined);
    const { t } = setup(); const d = await request(t); await flush(t);
    expect((await current(t, d._id)).localComplete).toBe(true);
    expect(await stages(t, d._id)).toEqual([]);
    expect(await t.run(ctx => ctx.db.query("deletionOutbox").collect())).toEqual([]);
    await t.mutation(internal.deletionAutomation.recover, {}); await flush(t);
    expect(fetch).not.toHaveBeenCalled();
    await t.mutation(internal.deletion.confirm, { id: d._id, owner, stage: "apple", complete: false, evidence: "legacy-case" });
  });

  it("executes cleanup → discovery → actions via scheduler, blocks other providers and creates only one honest intent", async () => {
    const { t } = setup(); const a = await work(t, { file: "files/alice" });
    const bob = await work(t, { who: "issuer|bob", file: "files/bob" });
    const issuer = await work(t, { who: "other-issuer|alice", file: "files/other" });
    vi.mocked(fetch).mockResolvedValue(Response.json({}));
    const d = await request(t); await flush(t);
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(vi.mocked(fetch).mock.calls[0][0]).toContain("files/alice");
    expect(await t.run(ctx => ctx.db.get(a))).toBeNull();
    expect(await t.run(ctx => ctx.db.get(bob))).not.toBeNull();
    expect(await t.run(ctx => ctx.db.get(issuer))).not.toBeNull();
    const ss = await stages(t, d._id);
    expect(ss).toHaveLength(6);
    expect(ss.filter(s => s.state === "blocked")).toHaveLength(5);
    expect(ss.find(s => s.kind === "geminiFile")).toMatchObject({ state: "succeeded", code: "deleted", attempts: 1, config });
    expect(await current(t, d._id)).toMatchObject({ localComplete: true, clerk: false, apple: false, revenuecat: false, gemini: false, residuals: false });
    const inventory = await t.query(internal.deletionAutomation.inventory, { id: d._id, owner, cursor: null });
    expect(inventory).toMatchObject({ classification: "exceptions", outbox: { state: "intent", delivery: "not_configured", providersComplete: false } });
    await t.mutation(internal.deletionAutomation.start, { id: d._id, owner }); await flush(t);
    expect(await stages(t, d._id)).toHaveLength(6);
    expect(await t.run(ctx => ctx.db.query("deletionOutbox").collect())).toHaveLength(1);
    expect(fetch).toHaveBeenCalledTimes(1);
    await expect(t.query(internal.deletionAutomation.inventory, { id: d._id, owner: "issuer|bob", cursor: null })).rejects.toThrow("Exact deletion target");
    await expect(t.mutation(internal.deletionAutomation.start, { id: d._id, owner: "issuer|bob" })).rejects.toThrow("Exact deletion target");
  });

  it("preserves unknown generation, legacy ambiguity, unknown uploads and active actions", async () => {
    const { t } = setup();
    const generation = await work(t, { file: "files/generation", unknownGeneration: true });
    const legacy = await work(t, { legacy: true, file: "files/legacy" });
    const upload = await work(t, { legacy: true });
    const active = await work(t, { file: "files/active", active: true });
    vi.mocked(fetch).mockResolvedValue(Response.json({ error: { code: 404, status: "NOT_FOUND" } }, { status: 404 }));
    const d = await request(t); await flush(t);
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(await t.run(ctx => ctx.db.get(generation))).toMatchObject({ fileDeleted: true, generationStarted: true, generationFinished: false, ambiguous: true });
    expect(await t.run(ctx => ctx.db.get(legacy))).toMatchObject({ fileDeleted: false, ambiguous: true });
    expect(await t.run(ctx => ctx.db.get(upload))).not.toBeNull();
    expect(await t.run(ctx => ctx.db.get(active))).toMatchObject({ finished: false });
    expect((await current(t, d._id)).localComplete).toBe(false);
    expect((await stages(t, d._id)).find(s => s.work === legacy)).toMatchObject({ state: "blocked", code: "unverified_config" });
    vi.setSystemTime(Date.now() + 365 * 86400_000);
    await t.mutation(internal.deletionAutomation.recover, {}); await flush(t);
    expect((await current(t, d._id)).localComplete).toBe(false);
  });

  it("legacy file acknowledgement never resolves the generation ambiguity", async () => {
    const { t } = setup(); const id = await work(t, { legacy: true, file: "files/legacy" });
    await t.run(ctx => ctx.db.patch(id, { fileDeleted: true }));
    const d = await request(t); await flush(t);
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ ambiguous: true });
    expect((await stages(t, d._id)).find(s => s.work === id)).toMatchObject({ state: "succeeded", code: "previous_file_acknowledgement", attempts: 0 });
    expect((await current(t, d._id)).localComplete).toBe(false);
    expect(fetch).not.toHaveBeenCalled();
  });

  it("scheduled transient retries stop at eight attempts, preserve targets, and never emit completion", async () => {
    const { t } = setup(); const id = await work(t, { file: "files/retry" });
    const calls: number[] = [];
    vi.mocked(fetch).mockImplementation(async () => { calls.push(Date.now()); return new Response(null, { status: 503, headers: { "Retry-After": "7200" } }); });
    const d = await request(t); await flush(t);
    expect(fetch).toHaveBeenCalledTimes(MAX_ATTEMPTS);
    for (let i = 1; i < calls.length; i++) expect(calls[i] - calls[i - 1]).toBeGreaterThanOrEqual(7200_000);
    const s = (await stages(t, d._id)).find(s => s.work === id)!;
    expect(s).toMatchObject({ state: "exhausted", attempts: 8, target: "files/retry", config });
    expect(new Set(vi.mocked(fetch).mock.calls.map(c => c[0])).size).toBe(1);
    await t.mutation(internal.deletionAutomation.recover, {}); await flush(t);
    expect(fetch).toHaveBeenCalledTimes(8);
    await expect(t.mutation(internal.deletionAutomation.resume, { id: d._id, owner, stage: s._id, fence: s.fence })).rejects.toThrow("operator reconciliation");
    expect(await t.run(ctx => ctx.db.query("deletionOutbox").unique())).toMatchObject({ classification: "exceptions", providersComplete: false });
  });

  it("a transient failure can recover automatically without touching provider completion flags", async () => {
    const { t } = setup(); const id = await work(t, { file: "files/retry-success" });
    vi.mocked(fetch).mockResolvedValueOnce(new Response(null, { status: 429 })).mockResolvedValueOnce(Response.json({}));
    const d = await request(t); await flush(t);
    expect((await stages(t, d._id)).find(s => s.work === id)).toMatchObject({ state: "succeeded", attempts: 2 });
    expect((await current(t, d._id)).gemini).toBe(false);
  });

  it("missing key blocks without network and explicit resume preserves attempt budget and frozen config", async () => {
    const { t } = setup(); const id = await work(t, { file: "files/key" });
    vi.stubEnv("GEMINI_API_KEY", undefined);
    const d = await request(t); await flush(t);
    const s = (await stages(t, d._id)).find(s => s.work === id)!;
    expect(s).toMatchObject({ state: "blocked", code: "missing_secret", attempts: 1 });
    expect(fetch).not.toHaveBeenCalled();
    vi.stubEnv("GEMINI_API_KEY", "synthetic-replacement"); vi.mocked(fetch).mockResolvedValue(Response.json({}));
    await t.mutation(internal.deletionAutomation.resume, { id: d._id, owner, stage: s._id, fence: s.fence }); await flush(t);
    expect((await stages(t, d._id)).find(s => s.work === id)).toMatchObject({ state: "succeeded", attempts: 2, target: s.target, config: s.config });
  });

  it("paginates discovery beyond one batch using scheduled continuations", async () => {
    const { t } = setup();
    for (let n = 0; n < 35; n++) await work(t, { file: `files/page-${n}` });
    vi.mocked(fetch).mockImplementation(async () => Response.json({}));
    const d = await request(t); await flush(t);
    expect(fetch).toHaveBeenCalledTimes(35);
    expect(await stages(t, d._id)).toHaveLength(40);
    expect((await current(t, d._id)).localComplete).toBe(true);
  });
});

describe("leases, fencing and manual exceptions", () => {
  it("claims at most once under concurrent dispatch and rejects owner/target/config mismatches", async () => {
    const { t } = setup(); const w = await work(t, { file: "files/fenced" }); const d = await request(t);
    const id = await frozenStage(t, d._id, w);
    const claims = await Promise.all([t.mutation(internal.deletionAutomation.claim, { id }), t.mutation(internal.deletionAutomation.claim, { id })]);
    expect(claims.filter(Boolean)).toHaveLength(1); const s = claims.find(Boolean)!;
    const result = { state: "succeeded" as const, code: "deleted", httpStatus: 200 };
    for (const wrong of [{ owner: "issuer|bob" }, { target: "files/bob" }, { config: "other-project" }, { fence: s.fence + 1 }]) {
      expect(await t.mutation(internal.deletionAutomation.finish, { ...fence(s), ...wrong, result })).toBe(false);
    }
    expect(await t.run(ctx => ctx.db.get(w))).toMatchObject({ fileDeleted: false });
    expect(await t.mutation(internal.deletionAutomation.finish, { ...fence(s), result })).toBe(true);
    expect(await t.mutation(internal.deletionAutomation.finish, { ...fence(s), result })).toBe(false);
    vi.stubEnv("DELETION_AUTOMATION_ENABLED", "false"); await flush(t);
  });

  it("lease expiry is uncertainty; watchdog retries and rejects a late completion", async () => {
    const { t } = setup(); const w = await work(t, { file: "files/crash" }); const d = await request(t);
    const id = await frozenStage(t, d._id, w);
    const s = (await t.mutation(internal.deletionAutomation.claim, { id }))!;
    vi.setSystemTime(s.leaseUntil!);
    expect(await t.mutation(internal.deletionAutomation.finish, { ...fence(s), result: { state: "succeeded", code: "deleted", httpStatus: 200 } })).toBe(false);
    vi.mocked(fetch).mockImplementation(async () => Response.json({}));
    await flush(t); // Executes the watchdog actually scheduled by claim.
    expect((await stages(t, d._id)).find(s => s.work === w)).toMatchObject({ state: "succeeded", attempts: 2, fence: 3 });
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("recovery schedules due work, including after automation was temporarily disabled", async () => {
    const { t } = setup(); const w = await work(t, { file: "files/recovery" }); const d = await request(t);
    const id = await frozenStage(t, d._id, w);
    const s = (await t.mutation(internal.deletionAutomation.claim, { id }))!;
    vi.stubEnv("DELETION_AUTOMATION_ENABLED", "false"); await flush(t);
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ state: "retry", code: "lease_expired_unknown" });
    expect(fetch).not.toHaveBeenCalled();
    vi.setSystemTime(Date.now() + LEASE_MS);
    vi.stubEnv("DELETION_AUTOMATION_ENABLED", "true"); vi.mocked(fetch).mockResolvedValue(Response.json({}));
    await t.mutation(internal.deletionAutomation.recover, {}); await flush(t);
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ state: "succeeded", attempts: s.attempts + 1 });
    // Verify deployment registers the recovery mutation, not just a test-only invocation.
    expect(JSON.stringify(crons.crons)).toContain("recover deletion automation");
    expect(JSON.stringify(crons.crons)).toContain("deletionAutomation:recover");
  });

  it("config changes before dispatch or completion cannot silently retarget a file", async () => {
    const { t } = setup(); const w = await work(t, { file: "files/config" }); const d = await request(t);
    const id = await frozenStage(t, d._id, w);
    const s = (await t.mutation(internal.deletionAutomation.claim, { id }))!;
    vi.stubEnv("GEMINI_DELETION_PROJECT_REF", "other-project");
    expect(await t.mutation(internal.deletionAutomation.finish, { ...fence(s), result: { state: "succeeded", code: "deleted", httpStatus: 200 } })).toBe(true);
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ state: "blocked", config, target: "files/config", code: "config_mismatch" });
    expect(await t.run(ctx => ctx.db.get(w))).toMatchObject({ fileDeleted: false });
    await flush(t); expect(fetch).not.toHaveBeenCalled();
  });

  it("manual reconciliation wins over in-flight completion and requires current request revision", async () => {
    const { t } = setup(); const w = await work(t, { file: "files/manual" }); const d = await request(t);
    await t.mutation(internal.deletionAutomation.start, { id: d._id, owner });
    const id = await frozenStage(t, d._id, w);
    const s = (await t.mutation(internal.deletionAutomation.claim, { id }))!;
    await expect(t.mutation(internal.deletion.reconcileWork, { id: d._id, owner, workId: w, evidence: "case" })).rejects.toThrow("revision changed");
    const latest = await current(t, d._id);
    await t.mutation(internal.deletion.reconcileWork, { id: d._id, owner, workId: w, evidence: "synthetic-proof", automationRevision: latest.automationRevision });
    expect(await t.mutation(internal.deletionAutomation.finish, { ...fence(s), result: { state: "retry", code: "transport_unknown" } })).toBe(false);
    await flush(t);
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ state: "manual", evidence: "synthetic-proof" });
    expect(fetch).not.toHaveBeenCalled();
    await expect(t.mutation(internal.deletion.confirm, { id: d._id, owner, stage: "apple", complete: false, evidence: "old-proof", automationRevision: latest.automationRevision })).rejects.toThrow("revision changed");
  });

  it("malformed internal results cannot inject provider text or fabricate success for missing adapters", async () => {
    const { t } = setup(); const d = await request(t);
    await t.mutation(internal.deletionAutomation.start, { id: d._id, owner });
    const apple = (await stages(t, d._id)).find(s => s.kind === "apple")!;
    const s = (await t.mutation(internal.deletionAutomation.claim, { id: apple._id }))!;
    await t.mutation(internal.deletionAutomation.finish, { ...fence(s), result: { state: "succeeded", code: "deleted", httpStatus: 200 } });
    expect(await t.run(ctx => ctx.db.get(s._id))).toMatchObject({ state: "blocked", code: "malformed_response" });
    await flush(t); expect((await current(t, d._id)).apple).toBe(false);
  });

  it("checks the frozen work owner/target/config before any side effect", async () => {
    const { t } = setup(); const w = await work(t, { file: "files/owner" }); const d = await request(t);
    const id = await frozenStage(t, d._id, w);
    await t.run(ctx => ctx.db.patch(w, { owner: "issuer|bob" }));
    expect(await t.mutation(internal.deletionAutomation.claim, { id })).toBeNull();
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ state: "blocked", code: "work_target_mismatch", owner, target: "files/owner" });
    await flush(t); expect(fetch).not.toHaveBeenCalled();
    expect(await t.run(ctx => ctx.db.get(w))).toMatchObject({ owner: "issuer|bob", fileDeleted: false });
  });

  it("in-flight mocked DELETE cannot overwrite an operator work reconciliation", async () => {
    const { t } = setup(); const w = await work(t, { file: "files/concurrent" }); const d = await request(t);
    await t.mutation(internal.deletionAutomation.start, { id: d._id, owner });
    const id = await frozenStage(t, d._id, w);
    let started!: () => void, release!: (r: Response) => void;
    const waiting = new Promise<void>(r => { started = r; });
    vi.mocked(fetch).mockImplementation(() => { started(); return new Promise<Response>(r => { release = r; }); });
    const running = t.action(internal.deletionAutomation.run, { id }); await waiting;
    await t.mutation(internal.deletion.reconcileWork, { id: d._id, owner, workId: w, evidence: "operator-wins",
      automationRevision: (await current(t, d._id)).automationRevision });
    release(Response.json({})); await running; await flush(t);
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ state: "manual", evidence: "operator-wins" });
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("all legacy/manual provider evidence is still required for a scope-complete intent, never delivery", async () => {
    const { t } = setup(); const d = await request(t); await flush(t);
    for (const stage of ["clerk", "apple", "revenuecat", "gemini", "residuals"] as const) {
      await t.mutation(internal.deletion.confirm, { id: d._id, owner, stage, complete: true, evidence: `synthetic-${stage}`,
        automationRevision: (await current(t, d._id)).automationRevision });
    }
    expect(await t.run(ctx => ctx.db.query("deletionOutbox").unique())).toMatchObject({ classification: "scope_complete", providersComplete: true, state: "intent", delivery: "not_configured" });
    await t.mutation(internal.deletionAutomation.start, { id: d._id, owner }); await flush(t);
    expect((await stages(t, d._id)).every(s => s.state === "manual")).toBe(true);
    await t.mutation(internal.deletion.confirm, { id: d._id, owner, stage: "apple", complete: false, evidence: "reopened-proof",
      automationRevision: (await current(t, d._id)).automationRevision });
    expect(await t.run(ctx => ctx.db.query("deletionOutbox").unique())).toMatchObject({ classification: "exceptions", providersComplete: false });
    expect(fetch).not.toHaveBeenCalled();
  });

  it("eight lost workers exhaust rather than infer success; recovery does not reset the budget", async () => {
    const { t } = setup(); const w = await work(t, { file: "files/exhausted" }); const d = await request(t);
    const id = await frozenStage(t, d._id, w);
    await t.run(ctx => ctx.db.patch(id, { attempts: 7 }));
    await t.mutation(internal.deletionAutomation.claim, { id });
    vi.stubEnv("DELETION_AUTOMATION_ENABLED", "false"); await flush(t);
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ state: "exhausted", attempts: 8, code: "lease_expired_unknown" });
    vi.stubEnv("DELETION_AUTOMATION_ENABLED", "true");
    await t.mutation(internal.deletionAutomation.recover, {}); await flush(t);
    expect(fetch).not.toHaveBeenCalled();
    expect(await t.run(ctx => ctx.db.get(w))).toMatchObject({ fileDeleted: false });
  });
});
