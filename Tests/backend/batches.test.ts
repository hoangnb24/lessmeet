import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "../../convex/schema";
import { internal } from "../../convex/_generated/api";
import { nativeM4aFixture } from "./nativeMediaFixture";
import { sha256 } from "../../convex/batchContract";
import { structuralFixture } from "./batchMediaFixture";

const modules = import.meta.glob(["../../convex/**/*.{ts,js}", "!../../convex/**/*.d.ts", "!../../convex/auth.config.ts"]);
const root = "/v1/transcription-batches", origin = "https://generativelanguage.googleapis.com";
const raw = '{"version":1,"segments":[{"startMs":0,"endMs":1250,"speaker":"A","text":"Synthetic meeting"}]}';
const clientBatchId = "00000000-0000-4000-8000-000000000001", retryId = "00000000-0000-4000-8000-000000000002";
const post = (x: unknown) => ({ method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(x) });
function setup() {
  const t = convexTest({ schema, modules, transactionLimits: true });
  return { t, alice: t.withIdentity({ tokenIdentifier: "issuer|alice", issuer: "issuer", subject: "alice" }), bob: t.withIdentity({ tokenIdentifier: "issuer|bob", issuer: "issuer", subject: "bob" }) };
}
type Test = ReturnType<typeof setup>;
async function create(alice: Test["alice"], key = clientBatchId) {
  const audio = nativeM4aFixture(), hash = await sha256(audio);
  const manifest = { version: 1, source: { sha256: "a".repeat(64), bytes: audio.byteLength, duration: { value: 5, timescale: 4 } }, chunks: [{ sha256: hash, bytes: audio.byteLength }] };
  const response = await alice.fetch(root, post({ clientBatchId: key, manifest }));
  expect(response.status).toBe(201);
  return { ...await response.json(), manifest, audio };
}
async function upload(alice: Test["alice"], batch: Awaited<ReturnType<typeof create>>) {
  const response = await alice.fetch(`${root}/chunk?batchId=${batch.batchId}&index=0`, { method: "PUT", headers: { "Content-Type": "audio/m4a" }, body: batch.audio });
  expect(response.status).toBe(200); return response.json();
}
async function seal(alice: Test["alice"], batch: Awaited<ReturnType<typeof create>>) {
  const response = await alice.fetch(`${root}/seal`, post({ batchId: batch.batchId, manifestDigest: batch.manifestDigest }));
  expect(response.status).toBe(202); return response.json();
}
async function status(alice: Test["alice"], batchId: string) { return (await alice.fetch(`${root}?batchId=${batchId}`)).json(); }
let output: string, outcome: "completed" | "incomplete", unknown: boolean, cleanupFail: boolean;
let generationCount: number, failGeneration: number;
let billingPlan: "free" | "pro";
const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit): Promise<Response> => {
  const path = String(url);
  if (path.startsWith("https://api.revenuecat.com/")) {
    const product = "com.lessmeet.app.pro.monthly", purchase = "2026-09-01T00:00:00Z", expires = "2026-10-01T00:00:00Z";
    return Response.json({ request_date_ms: Date.now(), subscriber: { original_app_user_id: "alice",
      entitlements: billingPlan === "pro" ? { lessmeet_pro: { product_identifier: product, purchase_date: purchase, expires_date: expires } } : {},
      subscriptions: billingPlan === "pro" ? { [product]: { original_purchase_date: purchase, purchase_date: purchase, expires_date: expires, refunded_at: null, is_sandbox: false, store: "app_store", ownership_type: "PURCHASED" } } : {} } });
  }
  if (path === `${origin}/upload/v1beta/files`) return new Response(null, { headers: { "x-goog-upload-url": `${origin}/upload/session` } });
  if (path === `${origin}/upload/session`) return Response.json({ file: { name: "files/test", uri: `${origin}/v1beta/files/test`, state: "ACTIVE" } });
  if (path === `${origin}/v1beta/interactions`) { generationCount++; if (unknown) throw new Error("Synthetic lost response"); return Response.json({ status: generationCount === failGeneration ? "incomplete" : outcome, steps: [{ type: "model_output", content: [{ type: "text", text: output }] }] }); }
  if (path === `${origin}/v1beta/files/test` && init?.method === "DELETE") return new Response(null, { status: cleanupFail ? 503 : 204 });
  throw new Error("Unexpected mock route");
});
beforeEach(() => {
  vi.useFakeTimers(); vi.setSystemTime(Date.parse("2026-09-25T00:00:00Z"));
  vi.stubEnv("BATCH_TRANSCRIPTION_ENABLED", "true"); vi.stubEnv("BATCH_TRANSCRIPTION_OWNER", "issuer|alice");
  vi.stubEnv("GEMINI_BILLABLE_ENABLED", "true"); vi.stubEnv("GEMINI_API_KEY", "synthetic-placeholder");
  vi.stubEnv("BILLING_ENFORCEMENT_ENABLED", "true"); vi.stubEnv("REVENUECAT_ORIGINAL_USER_POLICY_CONFIRMED", "true");
  vi.stubEnv("REVENUECAT_SECRET_API_KEY", "sk_synthetic_placeholder"); vi.stubEnv("ACCOUNT_DELETION_ENABLED", "true");
  vi.stubEnv("DELETION_AUTOMATION_ENABLED", "false");
  output = raw; outcome = "completed"; unknown = false; cleanupFail = false; generationCount = 0; failGeneration = 0; billingPlan = "free"; fetchMock.mockClear(); vi.stubGlobal("fetch", fetchMock);
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllEnvs(); vi.unstubAllGlobals(); });

describe("integrated batch workflow (all provider HTTP mocked)", () => {
  it("retires the reproduced Free 25-slot reservation after Pro verification without blocking new Pro work", async () => {
    const { t, alice } = setup(), full = structuralFixture(300), last = structuralFixture(120);
    const manifest = { version: 1, source: { sha256: "c".repeat(64), bytes: 1, duration: { value: 7200, timescale: 1 } },
      chunks: await Promise.all(Array.from({ length: 25 }, async (_, i) => ({ sha256: await sha256(i === 24 ? last : full), bytes: i === 24 ? last.byteLength : full.byteLength }))) };
    const old = await (await alice.fetch(root, post({ clientBatchId, manifest }))).json();
    for (let i = 0; i < 25; i++) expect((await alice.fetch(`${root}/chunk?batchId=${old.batchId}&index=${i}`, { method: "PUT", headers: { "Content-Type": "audio/m4a" }, body: i === 24 ? last : full })).status).toBe(200);
    await seal(alice, old); billingPlan = "pro";
    const later = await create(alice, retryId); await upload(alice, later); await seal(alice, later);
    expect((await t.run(ctx => ctx.db.query("quotaBuckets").collect())).reduce((n, b) => n + b.secondsReserved, 0)).toBe(7202);
    await t.finishAllScheduledFunctions(vi.runAllTimers); await t.mutation(internal.batches.recover, {}); await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect((await status(alice, old.batchId)).chunks.every((c: { state: string; error: { code: string }; retryAllowed: boolean }) => c.state === "failed" && c.error.code === "billing_changed" && c.retryAllowed)).toBe(true);
    expect((await status(alice, later.batchId)).state).toBe("complete"); expect(generationCount).toBe(1);
    const buckets = await t.run(ctx => ctx.db.query("quotaBuckets").collect());
    expect(buckets.find(b => b.window === "free")).toMatchObject({ secondsReserved: 0, secondsUsed: 0 });
    expect(buckets.find(b => b.window !== "free")).toMatchObject({ secondsReserved: 0, secondsUsed: 2 });
  });
  it("drains incompatible queued work without changing two unknown holds or their reservations", async () => {
    const { t, alice } = setup(); unknown = true;
    for (let i = 1; i <= 2; i++) { const b = await create(alice, `00000000-0000-4000-8000-00000000000${i}`); await upload(alice, b); await seal(alice, b); }
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    const held = (await t.run(ctx => ctx.db.query("transcriptionAttempts").collect())).filter(a => a.phase === "unknown"); expect(held).toHaveLength(2);
    const queued = await create(alice, "00000000-0000-4000-8000-000000000003"); await upload(alice, queued); await seal(alice, queued);
    billingPlan = "pro"; await t.action(internal.batchJobs.dispatch, {}); await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect((await status(alice, queued.batchId)).chunks[0]).toMatchObject({ state: "failed", error: { code: "billing_changed" } });
    expect((await t.run(ctx => ctx.db.query("transcriptionAttempts").collect())).filter(a => a.phase === "unknown")).toEqual(held);
    expect((await t.run(ctx => ctx.db.query("transcriptionInventory").first()))?.jobs).toHaveLength(2);
    expect(await t.run(ctx => ctx.db.query("quotaBuckets").first())).toMatchObject({ secondsReserved: 4, secondsUsed: 0 }); expect(generationCount).toBe(2);
  });
  it("does not grant a third attempt when billing changes again before an explicit retry submits", async () => {
    const { t, alice } = setup(), b = await create(alice); await upload(alice, b); await seal(alice, b);
    billingPlan = "pro"; await t.finishAllScheduledFunctions(vi.runAllTimers);
    const first = await status(alice, b.batchId);
    expect(first.chunks[0]).toMatchObject({ attempt: 1, state: "failed", retryAllowed: true });
    expect((await alice.fetch(`${root}/retry`, post({ batchId: b.batchId, index: 0, expectedAttempt: 1, expectedFence: first.chunks[0].fence, requestId: retryId, confirm: "retry-failed-chunk" }))).status).toBe(202);
    billingPlan = "free"; await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect((await status(alice, b.batchId)).chunks[0]).toMatchObject({ attempt: 2, state: "failed", retryAllowed: false, error: { code: "billing_changed" } });
    expect((await t.run(ctx => ctx.db.query("quotaBuckets").collect())).every(b => b.secondsReserved === 0 && b.secondsUsed === 0)).toBe(true);
    expect(generationCount).toBe(0); expect(await t.run(ctx => ctx.db.query("transcriptionAttempts").collect())).toHaveLength(2);
  });
  it("does not mutate already running claims when draining incompatible queued reservations", async () => {
    const { t, alice } = setup();
    for (let i = 1; i <= 3; i++) { const b = await create(alice, `00000000-0000-4000-8000-00000000000${i}`); await upload(alice, b); await seal(alice, b); }
    await t.action(internal.batchJobs.dispatch, {});
    const held = (await t.run(ctx => ctx.db.query("transcriptionAttempts").collect())).filter(a => a.phase === "claimed"); expect(held).toHaveLength(2);
    billingPlan = "pro"; await t.action(internal.batchJobs.dispatch, {});
    expect((await t.run(ctx => ctx.db.query("transcriptionAttempts").collect())).filter(a => a.phase === "claimed")).toEqual(held);
    expect((await t.run(ctx => ctx.db.query("transcriptionChunks").collect())).filter(c => c.state === "failed")).toHaveLength(1);
    expect(await t.run(ctx => ctx.db.query("quotaBuckets").first())).toMatchObject({ secondsReserved: 4, secondsUsed: 0 }); expect(generationCount).toBe(0);
  });
  it.each(["free", "pro"] as const)("drains >25 incompatible %s reservations, unblocks later work, and retries only explicitly", async initial => {
    const { t, alice } = setup(); billingPlan = initial;
    const old = [];
    for (let i = 1; i <= 30; i++) {
      const b = await create(alice, `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`);
      await upload(alice, b); await seal(alice, b); old.push(b);
    }
    billingPlan = initial === "free" ? "pro" : "free";
    const later = await create(alice, "00000000-0000-4000-8000-000000000099"); await upload(alice, later); await seal(alice, later);
    // Remove seal notifications to prove that the bounded drain itself schedules
    // its continuation, not that thirty preexisting notifications happen to help.
    await t.run(async ctx => { for (const s of await ctx.db.system.query("_scheduled_functions").collect()) if (s.state.kind === "pending") await ctx.scheduler.cancel(s._id); });
    await t.action(internal.batchJobs.dispatch, {});
    const firstPage = await t.run(ctx => ctx.db.query("transcriptionChunks").collect());
    expect(firstPage.filter(c => c.state === "failed")).toHaveLength(25);
    expect(firstPage.filter(c => c.state === "queued")).toHaveLength(6);
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect((await status(alice, later.batchId)).state).toBe("complete"); expect(generationCount).toBe(1);
    for (const b of old) expect((await status(alice, b.batchId)).chunks[0]).toMatchObject({ state: "failed", attempt: 1, retryAllowed: true, error: { code: "billing_changed" } });
    const buckets = await t.run(ctx => ctx.db.query("quotaBuckets").collect());
    expect(buckets.find(b => (b.window === "free") === (initial === "free"))).toMatchObject({ secondsReserved: 0, secondsUsed: 0 });
    expect(buckets.find(b => (b.window === "free") !== (initial === "free"))).toMatchObject({ secondsReserved: 0, secondsUsed: 2 });
    await t.mutation(internal.batches.recover, {}); await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(await t.run(ctx => ctx.db.query("quotaBuckets").collect())).toEqual(buckets);
    const s = await status(alice, old[0].batchId), request = { batchId: old[0].batchId, index: 0, expectedAttempt: 1, expectedFence: s.chunks[0].fence, requestId: retryId, confirm: "retry-failed-chunk" };
    expect((await alice.fetch(`${root}/retry`, post(request))).status).toBe(202);
    expect((await alice.fetch(`${root}/retry`, post(request))).status).toBe(202);
    const reserved = await t.run(ctx => ctx.db.query("quotaBuckets").collect());
    expect(reserved.find(b => (b.window === "free") !== (initial === "free"))).toMatchObject({ secondsReserved: 2, secondsUsed: 2 });
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(generationCount).toBe(2); expect((await status(alice, old[0].batchId)).chunks[0]).toMatchObject({ state: "succeeded", attempt: 2 });
  });
  it("runs HTTP admission -> durable storage -> scheduler -> actual SDK/mock provider -> raw and aggregate", async () => {
    const { t, alice } = setup(), b = await create(alice);
    await upload(alice, b); await seal(alice, b);
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    const result = await status(alice, b.batchId);
    expect(result).toMatchObject({ state: "complete", quotaSeconds: 2, cleanupPending: false, chunks: [{ state: "succeeded", attempt: 1, resultAvailable: true }] });
    expect((await (await alice.fetch(`${root}/result?batchId=${b.batchId}&index=0&attempt=1`)).json()).rawText).toBe(raw);
    expect(await (await alice.fetch(`${root}/aggregate?batchId=${b.batchId}`)).json()).toMatchObject({ status: "complete", aggregate: { timed: [{ text: "Synthetic meeting", sources: [{ chunkIndex: 0, segmentIndex: 0 }] }] } });
    const calls = fetchMock.mock.calls.filter(c => String(c[0]).endsWith("/interactions"));
    expect(calls).toHaveLength(1); expect(JSON.parse(calls[0][1]!.body as string)).toMatchObject({ store: false, model: "gemini-flash-latest" });
    expect(await t.run(ctx => ctx.db.query("quotaBuckets").first())).toMatchObject({ secondsUsed: 2, secondsReserved: 0 });
    expect(await t.run(ctx => ctx.db.query("deletionWork").collect())).toHaveLength(0);
    vi.stubEnv("BATCH_TRANSCRIPTION_ENABLED", "false"); vi.stubEnv("BATCH_TRANSCRIPTION_OWNER", undefined);
    expect((await status(alice, b.batchId)).state).toBe("complete");
  });
  it("refuses unauthenticated/off/foreign requests before storage or external billing", async () => {
    const { t, alice, bob } = setup();
    expect((await t.fetch(root, post({}))).status).toBe(401);
    expect((await bob.fetch(root, post({}))).status).toBe(403);
    vi.stubEnv("BATCH_TRANSCRIPTION_ENABLED", "false"); expect((await alice.fetch(root, post({}))).status).toBe(503);
    expect(fetchMock).not.toHaveBeenCalled();
    vi.stubEnv("BATCH_TRANSCRIPTION_ENABLED", "true"); const b = await create(alice);
    expect((await bob.fetch(`${root}?batchId=${b.batchId}`)).status).toBe(404);
    expect((await alice.fetch(`${root}/seal`, post({ batchId: b.batchId, manifestDigest: "wrong" }))).status).toBe(409);
    expect(fetchMock).not.toHaveBeenCalled(); expect(await t.run(ctx => ctx.db.system.query("_storage").collect())).toHaveLength(0);
  });
  it("recovers identical create/upload/seal replays without duplicate storage/quota/provider work", async () => {
    const { t, alice } = setup(), b = await create(alice);
    expect((await alice.fetch(root, post({ clientBatchId, manifest: b.manifest }))).status).toBe(200);
    expect((await (await alice.fetch(`${root}?clientBatchId=${clientBatchId}`)).json()).batchId).toBe(b.batchId);
    await upload(alice, b); await upload(alice, b); await seal(alice, b); await seal(alice, b);
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(await t.run(ctx => ctx.db.system.query("_storage").collect())).toHaveLength(1);
    expect(await t.run(ctx => ctx.db.query("transcriptionAttempts").collect())).toHaveLength(1);
    expect(fetchMock.mock.calls.filter(c => String(c[0]).endsWith("/interactions"))).toHaveLength(1);
  });
  it("keeps unknown generation slot and quota, even after timeout and file DELETE", async () => {
    unknown = true;
    const { t, alice } = setup(), b = await create(alice); await upload(alice, b); await seal(alice, b);
    await t.finishAllScheduledFunctions(vi.runAllTimers); vi.advanceTimersByTime(300000);
    await t.mutation(internal.batches.recover, {}); await t.finishAllScheduledFunctions(vi.runAllTimers);
    const s = await status(alice, b.batchId);
    expect(s).toMatchObject({ state: "attention", cleanupPending: true, chunks: [{ state: "unknown", retryAllowed: false }] });
    expect(await t.run(ctx => ctx.db.query("quotaBuckets").first())).toMatchObject({ secondsUsed: 0, secondsReserved: 2 });
    expect((await t.run(ctx => ctx.db.query("transcriptionInventory").first()))?.jobs).toHaveLength(1);
    expect((await alice.fetch(`${root}/retry`, post({ batchId: b.batchId, index: 0, expectedAttempt: 1, expectedFence: s.chunks[0].fence, requestId: retryId, confirm: "retry-failed-chunk" }))).status).toBe(409);
  });
  it("releases known failed quota and permits precisely one explicit idempotent retry", async () => {
    outcome = "incomplete";
    const { t, alice } = setup(), b = await create(alice); await upload(alice, b); await seal(alice, b); await t.finishAllScheduledFunctions(vi.runAllTimers);
    const s = await status(alice, b.batchId); expect(s.chunks[0].retryAllowed).toBe(true);
    expect(await t.run(ctx => ctx.db.query("quotaBuckets").first())).toMatchObject({ secondsUsed: 0, secondsReserved: 0 });
    outcome = "completed";
    const request = { batchId: b.batchId, index: 0, expectedAttempt: 1, expectedFence: s.chunks[0].fence, requestId: retryId, confirm: "retry-failed-chunk" };
    expect((await alice.fetch(`${root}/retry`, post(request))).status).toBe(202);
    expect((await alice.fetch(`${root}/retry`, post(request))).status).toBe(202);
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect((await status(alice, b.batchId)).chunks[0]).toMatchObject({ attempt: 2, state: "succeeded", retryAllowed: false });
    expect(await t.run(ctx => ctx.db.query("quotaBuckets").first())).toMatchObject({ secondsUsed: 2, secondsReserved: 0 });
  });
  it("deletes batch content before quotas and retains unknown operational work until exact reconciliation", async () => {
    unknown = true;
    const { t, alice } = setup(), b = await create(alice); await upload(alice, b); await seal(alice, b); await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect((await alice.fetch("/account/deletion", post({ confirm: "delete-account" }))).status).toBe(202);
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(await t.run(ctx => ctx.db.query("transcriptionBatches").collect())).toHaveLength(0);
    expect(await t.run(ctx => ctx.db.query("transcriptionChunks").collect())).toHaveLength(0);
    expect(await t.run(ctx => ctx.db.system.query("_storage").collect())).toHaveLength(0);
    expect(await t.run(ctx => ctx.db.query("quotaBuckets").collect())).toHaveLength(0);
    const d = (await t.run(ctx => ctx.db.query("deletions").first()))!, w = (await t.run(ctx => ctx.db.query("deletionWork").first()))!;
    expect(d.localComplete).toBe(false);
    vi.stubEnv("BATCH_TRANSCRIPTION_ENABLED", "false");
    await t.mutation(internal.deletion.reconcileWork, { id: d._id, owner: d.owner, workId: w._id, evidence: "synthetic-terminal-proof" });
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect((await t.run(ctx => ctx.db.query("transcriptionInventory").first()))?.jobs).toHaveLength(0);
    expect(await t.run(ctx => ctx.db.query("transcriptionAttempts").collect())).toHaveLength(0);
  });
  it("validates media with billing disabled and rejects duplicate control keys", async () => {
    vi.stubEnv("BILLING_ENFORCEMENT_ENABLED", "false");
    const { alice } = setup(), b = await create(alice);
    const damaged = b.audio.slice(0); new Uint8Array(damaged)[0] ^= 1;
    expect((await alice.fetch(`${root}/chunk?batchId=${b.batchId}&index=0`, { method: "PUT", headers: { "Content-Type": "audio/m4a" }, body: damaged })).status).toBe(409);
    expect((await alice.fetch(root, { ...post({}), body: '{"clientBatchId":"a","clientBatchId":"b","manifest":{}}' })).status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });
  it("caps work at two across parents and never frees ambiguous slots to start a third", async () => {
    unknown = true;
    const { t, alice } = setup();
    const batches = [];
    for (let i = 1; i <= 3; i++) {
      const b = await create(alice, `00000000-0000-4000-8000-00000000000${i}`); batches.push(b); await upload(alice, b); await seal(alice, b);
    }
    await t.action(internal.batchJobs.dispatch, {});
    await t.action(internal.batchJobs.dispatch, {});
    expect((await t.run(ctx => ctx.db.query("transcriptionInventory").first()))?.jobs).toHaveLength(2);
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(fetchMock.mock.calls.filter(c => String(c[0]).endsWith("/interactions"))).toHaveLength(2);
    const states = await Promise.all(batches.map(b => status(alice, b.batchId)));
    expect(states.filter(s => s.chunks[0].state === "unknown")).toHaveLength(2);
    expect(states.filter(s => s.chunks[0].state === "queued")).toHaveLength(1);
    expect(await t.run(ctx => ctx.db.query("quotaBuckets").first())).toMatchObject({ secondsReserved: 6, secondsUsed: 0 });
  });
  it("leaves an interrupted upload admission observable without storing another blob", async () => {
    const { t, alice } = setup(), b = await create(alice);
    await alice.mutation(internal.batches.beginUpload, { batchId: b.batchId, index: 0 });
    expect((await alice.fetch(`${root}/chunk?batchId=${b.batchId}&index=0`, { method: "PUT", headers: { "Content-Type": "audio/m4a" }, body: b.audio })).status).toBe(202);
    expect((await status(alice, b.batchId)).chunks[0].state).toBe("admitting");
    expect(await t.run(ctx => ctx.db.system.query("_storage").collect())).toHaveLength(0);
    expect(fetchMock).not.toHaveBeenCalled();
  });
  it("retains a completed result when provider cleanup fails", async () => {
    cleanupFail = true;
    const { t, alice } = setup(), b = await create(alice); await upload(alice, b); await seal(alice, b); await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(await status(alice, b.batchId)).toMatchObject({ state: "complete", cleanupPending: true });
    expect((await t.run(ctx => ctx.db.query("transcriptionInventory").first()))?.jobs).toHaveLength(0);
    expect(await t.run(ctx => ctx.db.query("quotaBuckets").first())).toMatchObject({ secondsUsed: 2, secondsReserved: 0 });
  });
  it("serializes control billing and rejects stale revision claims", async () => {
    const { t, alice } = setup(), b = await create(alice); await upload(alice, b); await seal(alice, b);
    const lease = await t.mutation(internal.batches.beginDispatch, {});
    expect(lease).not.toBeNull();
    await expect(alice.mutation(internal.batches.beginControlBilling, {})).rejects.toThrow("verification");
    await expect(t.mutation(internal.batches.claim, { owner: "issuer|alice", dispatchFence: lease!.fence, revision: 0 })).rejects.toThrow("verification");
    expect((await t.run(ctx => ctx.db.query("transcriptionInventory").first()))?.jobs).toHaveLength(0);
  });
  it("fences duplicate worker starts and late completions after deletion", async () => {
    const { t, alice } = setup(), b = await create(alice); await upload(alice, b); await seal(alice, b);
    await t.action(internal.batchJobs.dispatch, {});
    const a = (await t.run(ctx => ctx.db.query("transcriptionAttempts").first()))!;
    expect(await t.mutation(internal.batches.job, { id: a._id, fence: a.fence })).not.toBeNull();
    expect(await t.mutation(internal.batches.job, { id: a._id, fence: a.fence })).toBeNull();
    await expect(t.mutation(internal.batches.phase, { id: a._id, fence: a.fence + 1, phase: "uploading" })).rejects.toThrow();
    await t.mutation(internal.batches.phase, { id: a._id, fence: a.fence, phase: "uploading" });
    await expect(t.mutation(internal.batches.phase, { id: a._id, fence: a.fence, phase: "uploading" })).rejects.toThrow();
    await alice.fetch("/account/deletion", post({ confirm: "delete-account" })); await t.finishAllScheduledFunctions(vi.runAllTimers);
    await t.mutation(internal.batches.finish, { id: a._id, fence: a.fence, rawText: raw, known: true, fileDeleted: true });
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(await t.run(ctx => ctx.db.query("transcriptionChunks").collect())).toHaveLength(0);
    expect(await t.run(ctx => ctx.db.query("transcriptionBatches").collect())).toHaveLength(0);
    expect(await t.run(ctx => ctx.db.query("quotaBuckets").collect())).toHaveLength(0);
  });
  it("integrates all 25 slots for 120 minutes and charges exactly 7200 canonical seconds", async () => {
    const { t, alice } = setup();
    const full = structuralFixture(300), last = structuralFixture(120), fullHash = await sha256(full), lastHash = await sha256(last);
    const manifest = { version: 1, source: { sha256: "c".repeat(64), bytes: 999999999, duration: { value: 7200, timescale: 1 } },
      chunks: Array.from({ length: 25 }, (_, i) => ({ sha256: i === 24 ? lastHash : fullHash, bytes: i === 24 ? last.byteLength : full.byteLength })) };
    const response = await alice.fetch(root, post({ clientBatchId, manifest })); expect(response.status).toBe(201);
    const b = await response.json();
    for (let i = 0; i < 25; i++) expect((await alice.fetch(`${root}/chunk?batchId=${b.batchId}&index=${i}`, { method: "PUT", headers: { "Content-Type": "audio/m4a" }, body: i === 24 ? last : full })).status).toBe(200);
    await seal(alice, b); await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(await status(alice, b.batchId)).toMatchObject({ state: "complete", quotaSeconds: 7200 });
    expect(fetchMock.mock.calls.filter(c => String(c[0]).endsWith("/interactions"))).toHaveLength(25);
    expect(await t.run(ctx => ctx.db.query("quotaBuckets").first())).toMatchObject({ secondsUsed: 7200, secondsReserved: 0 });
  });
  it("preserves originals when aggregation overflows", async () => {
    output = JSON.stringify({ version: 1, segments: Array.from({ length: 40 }, () => ({ startMs: null, endMs: null, speaker: null, text: "x".repeat(8000) })) });
    const { t, alice } = setup(), audio = [structuralFixture(300), structuralFixture(6)];
    const manifest = { version: 1, source: { sha256: "d".repeat(64), bytes: 1, duration: { value: 301, timescale: 1 } },
      chunks: await Promise.all(audio.map(async a => ({ sha256: await sha256(a), bytes: a.byteLength }))) };
    const b = await (await alice.fetch(root, post({ clientBatchId, manifest }))).json();
    for (let i = 0; i < 2; i++) expect((await alice.fetch(`${root}/chunk?batchId=${b.batchId}&index=${i}`, { method: "PUT", headers: { "Content-Type": "audio/m4a" }, body: audio[i] })).status).toBe(200);
    await seal(alice, b); await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect((await status(alice, b.batchId)).aggregate).toEqual({ state: "too_large", available: false });
    expect(await (await alice.fetch(`${root}/aggregate?batchId=${b.batchId}`)).json()).toMatchObject({ status: "too_large", aggregate: null });
    expect((await (await alice.fetch(`${root}/result?batchId=${b.batchId}&index=1&attempt=1`)).json()).rawText).toBe(output);
  });
  it("rejects structurally invalid hash-matching media even when billing enforcement is off", async () => {
    vi.stubEnv("BILLING_ENFORCEMENT_ENABLED", "false");
    const { t, alice } = setup(), bad = new Uint8Array([1, 2, 3, 4]).buffer;
    const manifest = { version: 1, source: { sha256: "a".repeat(64), bytes: 4, duration: { value: 1, timescale: 1 } }, chunks: [{ sha256: await sha256(bad), bytes: 4 }] };
    const b = await (await alice.fetch(root, post({ clientBatchId, manifest }))).json();
    expect((await alice.fetch(`${root}/chunk?batchId=${b.batchId}&index=0`, { method: "PUT", headers: { "Content-Type": "audio/m4a" }, body: bad })).status).toBe(415);
    expect(await t.run(ctx => ctx.db.query("deletionWork").collect())).toHaveLength(0);
    expect(await t.run(ctx => ctx.db.system.query("_storage").collect())).toHaveLength(0); expect(fetchMock).not.toHaveBeenCalled();
  });
  it("allows exact reconciliation with generation disabled and fences wrong targets", async () => {
    unknown = true;
    const { t, alice } = setup(), b = await create(alice); await upload(alice, b); await seal(alice, b); await t.finishAllScheduledFunctions(vi.runAllTimers);
    const a = (await t.run(ctx => ctx.db.query("transcriptionAttempts").first()))!;
    vi.stubEnv("BATCH_TRANSCRIPTION_ENABLED", "false");
    const args = { id: a._id, owner: a.owner, fence: a.fence, evidence: "synthetic-terminal-proof", remoteStopped: true as const, filesReconciled: true as const };
    await expect(t.mutation(internal.batches.reconcile, { ...args, owner: "wrong|alice" })).rejects.toThrow();
    await t.mutation(internal.batches.reconcile, args);
    expect((await status(alice, b.batchId)).chunks[0]).toMatchObject({ state: "failed", retryAllowed: false });
    expect(await t.run(ctx => ctx.db.query("quotaBuckets").first())).toMatchObject({ secondsReserved: 0 });
    expect((await t.run(ctx => ctx.db.query("transcriptionInventory").first()))?.jobs).toHaveLength(0);
  });
  it("keeps successful siblings on partial failure and reserves only the failed canonical interval on retry", async () => {
    failGeneration = 2;
    const { t, alice } = setup(), audio = [structuralFixture(300), structuralFixture(6)];
    const manifest = { version: 1, source: { sha256: "d".repeat(64), bytes: 1, duration: { value: 301, timescale: 1 } },
      chunks: await Promise.all(audio.map(async a => ({ sha256: await sha256(a), bytes: a.byteLength }))) };
    const b = await (await alice.fetch(root, post({ clientBatchId, manifest }))).json();
    for (let i = 0; i < 2; i++) expect((await alice.fetch(`${root}/chunk?batchId=${b.batchId}&index=${i}`, { method: "PUT", headers: { "Content-Type": "audio/m4a" }, body: audio[i] })).status).toBe(200);
    await seal(alice, b); await t.finishAllScheduledFunctions(vi.runAllTimers);
    const s = await status(alice, b.batchId); expect(s.state).toBe("partial");
    const missing = s.chunks.find((c: { state: string }) => c.state === "failed");
    expect(await (await alice.fetch(`${root}/aggregate?batchId=${b.batchId}`)).json()).toMatchObject({ status: "partial", missingChunks: [missing.index] });
    const request = { batchId: b.batchId, index: missing.index, expectedAttempt: 1, expectedFence: missing.fence, requestId: retryId, confirm: "retry-failed-chunk" };
    expect((await alice.fetch(`${root}/retry`, post(request))).status).toBe(202); await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(generationCount).toBe(3); expect((await status(alice, b.batchId)).state).toBe("complete");
    expect(await t.run(ctx => ctx.db.query("quotaBuckets").first())).toMatchObject({ secondsUsed: 301, secondsReserved: 0 });
    expect((await alice.fetch(`${root}/retry`, post({ ...request, requestId: clientBatchId }))).status).toBe(409);
  });
});
