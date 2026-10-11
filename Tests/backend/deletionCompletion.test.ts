import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "../../convex/schema";
import { internal } from "../../convex/_generated/api";
import type { Id } from "../../convex/_generated/dataModel";
import { nativeM4aFixture } from "./nativeMediaFixture";
import { sha256 } from "../../convex/batchContract";

const modules = import.meta.glob(["../../convex/**/*.{ts,js}", "!../../convex/**/*.d.ts", "!../../convex/auth.config.ts"]);
const owner = "issuer|completion-alice", bobOwner = "issuer|completion-bob", otherOwner = "other|completion-alice";
const root = "/v1/transcription-batches";
const uuid = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const post = (body: unknown) => ({ method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
const rawText = JSON.stringify({ version: 1, segments: [{ startMs: 0, endMs: 1250, speaker: "A", text: "Synthetic meeting" }] });
const contentTables = ["recordings", "transcriptionBatches", "transcriptionChunks", "transcriptionAttempts",
  "batchChatContexts", "batchChats", "batchChatOperations", "quotaBuckets", "billingAccounts", "deletionWork"] as const;

function setup() {
  const t = convexTest({ schema, modules, transactionLimits: true });
  return { t, alice: t.withIdentity({ tokenIdentifier: owner, issuer: "issuer", subject: "completion-alice" }),
    bob: t.withIdentity({ tokenIdentifier: bobOwner, issuer: "issuer", subject: "completion-bob" }),
    other: t.withIdentity({ tokenIdentifier: otherOwner, issuer: "other", subject: "completion-alice" }) };
}
type T = ReturnType<typeof setup>["t"];
type Client = ReturnType<typeof setup>["alice"];

async function recordings(t: T, who: string, count = 1) {
  return t.run(async ctx => {
    const bucket = await ctx.db.insert("quotaBuckets", { owner: who, window: "free", secondsUsed: 7,
      secondsReserved: count * 10, questionsUsed: 2, questionsReserved: count });
    const billing = await ctx.db.insert("billingAccounts", { owner: who, subject: who.split("|")[1], revision: 1,
      plan: "free", expiresAt: null, observedAt: Date.now(), verifiedAt: Date.now() });
    const rows = [];
    for (let i = 0; i < count; i++) {
      const audio = await ctx.storage.store(new Blob([`Synthetic recording ${i}`]));
      const id = await ctx.db.insert("recordings", { owner: who, audio, mimeType: "audio/m4a", status: "ready",
        transcript: "Synthetic transcript", messages: [{ role: "user", text: "Synthetic question" }, { role: "assistant", text: "Synthetic answer" }],
        transcriptionReservation: { bucket, seconds: 10, questions: 0 }, chatReservation: { bucket, seconds: 0, questions: 1 } });
      rows.push({ id, audio });
    }
    return { bucket, billing, rows };
  });
}

// Only fixture seeding and synthetic provider outcomes bypass HTTP. All lifecycle
// transitions below use accepted handlers. Scheduled provider actions never run.
async function batch(t: T, client: Client, who: string, key: number, complete = true) {
  vi.stubEnv("BATCH_TRANSCRIPTION_OWNER", who);
  const audio = nativeM4aFixture(), hash = await sha256(audio);
  const manifest = { version: 1, source: { sha256: hash, bytes: audio.byteLength, duration: { value: 5, timescale: 4 } },
    chunks: [{ sha256: hash, bytes: audio.byteLength }] };
  const response = await client.fetch(root, post({ clientBatchId: uuid(key), manifest }));
  expect(response.status).toBe(201);
  const created = await response.json();
  const batchId = created.batchId as Id<"transcriptionBatches">;
  expect((await client.fetch(`${root}/chunk?batchId=${batchId}&index=0`, {
    method: "PUT", headers: { "Content-Type": "audio/m4a" }, body: audio,
  })).status).toBe(200);
  const chunk = (await t.run(ctx => ctx.db.query("transcriptionChunks").withIndex("by_parent", q => q.eq("parent", batchId)).unique()))!;
  await client.mutation(internal.batches.seal, { batchId, manifestDigest: created.manifestDigest, revision: 1 });
  const lease = (await t.mutation(internal.batches.beginDispatch, {}))!;
  const claimed = (await t.mutation(internal.batches.claim, { owner: who, dispatchFence: lease.fence, revision: 1 }))!;
  expect(claimed.ids).toHaveLength(1);
  const attempt = (await t.run(ctx => ctx.db.get(claimed.ids[0])))!;
  expect(await t.mutation(internal.batches.job, { id: attempt._id, fence: attempt.fence })).not.toBeNull();
  await t.mutation(internal.batches.phase, { id: attempt._id, fence: attempt.fence, phase: "uploading" });
  await t.mutation(internal.deletion.track, { id: attempt.work!, file: `files/synthetic-${key}` });
  await t.mutation(internal.batches.phase, { id: attempt._id, fence: attempt.fence, phase: "generating" });
  if (complete) {
    await t.mutation(internal.batches.phase, { id: attempt._id, fence: attempt.fence, phase: "finished" });
    await t.mutation(internal.batches.finish, { id: attempt._id, fence: attempt.fence, rawText, known: true, fileDeleted: true });
  }
  await t.mutation(internal.batches.endDispatch, { fence: lease.fence });
  return { batchId, audio: chunk.audio!, attempt };
}

async function chat(t: T, client: Client, batchId: string, key: number, complete = true) {
  const status = await client.query(internal.batchChat.get, { batchId });
  expect(status.availability).toBe("ready");
  await client.mutation(internal.batchChat.admit, { batchId, clientMessageId: uuid(key),
    expectedContextDigest: status.contextDigest!, expectedHistoryRevision: status.revision, message: "Synthetic question", billingRevision: 1 });
  const op = (await t.run(ctx => ctx.db.query("batchChatOperations").withIndex("by_owner_parent_key", q =>
    q.eq("owner", owner).eq("parent", batchId as Id<"transcriptionBatches">).eq("clientMessageId", uuid(key))).unique()))!;
  const claim = (await t.mutation(internal.batchChat.claim, { id: op._id }))!;
  expect(await t.mutation(internal.batchChat.intent, { id: op._id, fence: claim.fence, billingRevision: 1 })).toBe(true);
  if (complete) await t.mutation(internal.batchChat.finish, { id: op._id, fence: claim.fence, outcome: "completed", text: "Synthetic answer" });
  return (await t.run(ctx => ctx.db.get(op._id)))!;
}

async function request(t: T, client: Client) {
  expect((await client.fetch("/account/deletion", post({ confirm: "delete-account" }))).status).toBe(202);
  return (await t.run(ctx => ctx.db.query("deletions").withIndex("by_owner", q => q.eq("owner", owner)).unique()))!;
}
async function drain(t: T, id: Id<"deletions">) {
  // Drive bounded cleanup only. Do not drain scheduled billable/provider actions.
  for (let i = 0; i < 24; i++) await t.mutation(internal.deletion.cleanup, { id });
}
async function snapshot(t: T, who: string) {
  return t.run(async ctx => {
    const result = [];
    for (const table of contentTables) result.push((await ctx.db.query(table).collect()).filter(row => row.owner === who));
    return result;
  });
}
async function pendingProviders(t: T, client: Client, id: Id<"deletions">, localComplete: boolean) {
  expect(await client.query(internal.deletion.status, {})).toMatchObject({ requested: true, localComplete, providersComplete: false });
  expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ clerk: false, apple: false, revenuecat: false, gemini: false, residuals: false });
  const d = await t.run(ctx => ctx.db.get(id));
  expect(d?.completedAt).toBeUndefined(); expect(d?.purgeAt).toBeUndefined();
  expect(fetch).not.toHaveBeenCalled();
}

beforeEach(() => {
  vi.useFakeTimers(); vi.setSystemTime(new Date("2026-10-04T00:00:00Z"));
  for (const name of ["ACCOUNT_DELETION_ENABLED", "BATCH_TRANSCRIPTION_ENABLED", "BATCH_CHAT_ENABLED",
    "GEMINI_BILLABLE_ENABLED", "BILLING_ENFORCEMENT_ENABLED", "REVENUECAT_ORIGINAL_USER_POLICY_CONFIRMED"]) vi.stubEnv(name, "true");
  for (const name of ["DELETION_AUTOMATION_ENABLED", "DELETION_EMAIL_ENABLED", "DELETION_CONTACT_RETENTION_APPROVED", "DELETION_PREFLIGHT_ENABLED"]) vi.stubEnv(name, "false");
  vi.stubGlobal("fetch", vi.fn(() => { throw new Error("External network forbidden in deletion completion rehearsal"); }));
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); });

describe("offline populated deletion lifecycle using accepted handlers", () => {
  it("cleans recordings, completed batch/chat and quotas without changing either unrelated issuer-bound owner", async () => {
    const { t, alice, bob, other } = setup();
    const a = await recordings(t, owner, 9), b = await recordings(t, bobOwner), c = await recordings(t, otherOwner);
    const bb = await batch(t, bob, bobOwner, 1), cb = await batch(t, other, otherOwner, 1);
    const ab = await batch(t, alice, owner, 1); await chat(t, alice, ab.batchId, 2);
    const beforeBob = await snapshot(t, bobOwner), beforeOther = await snapshot(t, otherOwner);
    const d = await request(t, alice);
    expect(d).toMatchObject({ owner, subject: "completion-alice" });
    vi.stubEnv("ACCOUNT_DELETION_ENABLED", "false");
    expect((await request(t, alice))._id).toBe(d._id);
    await t.mutation(internal.deletion.cleanup, { id: d._id });
    expect((await snapshot(t, owner))[0]).toHaveLength(1);
    expect(await t.run(ctx => ctx.db.get(a.bucket))).toMatchObject({ secondsReserved: 10, questionsReserved: 1 });
    await drain(t, d._id); await drain(t, d._id);
    expect((await snapshot(t, owner)).every(rows => rows.length === 0)).toBe(true);
    for (const audio of [...a.rows.map(r => r.audio), ab.audio]) expect(await t.run(ctx => ctx.storage.get(audio))).toBeNull();
    expect(await snapshot(t, bobOwner)).toEqual(beforeBob); expect(await snapshot(t, otherOwner)).toEqual(beforeOther);
    for (const audio of [b.rows[0].audio, c.rows[0].audio, bb.audio, cb.audio]) expect(await t.run(async ctx => (await ctx.storage.get(audio)) !== null)).toBe(true);
    for (const client of [bob, other]) expect(await client.query(internal.deletion.status, {})).toMatchObject({ requested: false });
    expect(await t.run(ctx => ctx.db.query("deletions").collect())).toHaveLength(1);
    await pendingProviders(t, alice, d._id, true);
  });

  it("holds local completion for unknown batch/chat work and a late upload, then reconciles exact work without provider completion", async () => {
    const { t, alice } = setup(); await recordings(t, owner);
    const complete = await batch(t, alice, owner, 1), op = await chat(t, alice, complete.batchId, 2, false);
    const running = await batch(t, alice, owner, 3, false);
    const upload = await t.mutation(internal.deletion.beginWork, { owner, kind: "upload" });
    const d = await request(t, alice); await drain(t, d._id);
    await pendingProviders(t, alice, d._id, false);
    expect(await t.run(ctx => ctx.db.get(op._id))).toMatchObject({ deleted: true, state: "unknown", quota: "released" });
    const stripped = await t.run(ctx => ctx.db.get(op._id));
    for (const field of ["message", "text", "historyText", "context", "contextDigest"] as const) expect(stripped?.[field]).toBeUndefined();
    const late = await t.run(ctx => ctx.storage.store(new Blob(["Late synthetic upload"])));
    await t.mutation(internal.deletion.track, { id: upload, audio: late });
    await expect(alice.mutation(internal.recordings.create, { audio: late, mimeType: "audio/m4a" })).rejects.toThrow("Account deletion");
    await expect(t.mutation(internal.billing.applyVerification, { owner, subject: "completion-alice", revision: 1,
      observedAt: Date.now(), plan: "free", expiresAt: null, anchor: null })).rejects.toThrow("Account deletion");
    await t.mutation(internal.batchChat.finish, { id: op._id, fence: op.fence, outcome: "unknown", text: "Unproven late answer" });
    await t.mutation(internal.batches.finish, { id: running.attempt._id, fence: running.attempt.fence, rawText, known: false, fileDeleted: false });
    await drain(t, d._id);
    const inventory = await t.query(internal.deletion.inventory, { id: d._id, owner, cursor: null });
    expect(inventory.work.isDone).toBe(true); expect(inventory.work.page).toHaveLength(3);
    expect(inventory.work.page.find(w => w._id === running.attempt.work)).toMatchObject({ finished: true, ambiguous: true, fileDeleted: false });
    vi.setSystemTime(Date.now() + 91 * 86400_000);
    await t.mutation(internal.deletionRetention.purgeExpired, {});
    expect((await request(t, alice))._id).toBe(d._id);
    await pendingProviders(t, alice, d._id, false);
    await expect(t.mutation(internal.deletion.confirm, { id: d._id, owner, stage: "gemini", complete: true, evidence: "synthetic-incomplete" })).rejects.toThrow("outstanding operations");
    await expect(t.mutation(internal.deletion.reconcileWork, { id: d._id, owner: otherOwner, workId: upload, evidence: "synthetic-wrong-owner" })).rejects.toThrow("Exact deletion target");
    // Fixture attestation only: no actual provider termination or erasure is proven.
    for (const w of inventory.work.page) {
      const args = { id: d._id, owner, workId: w._id, evidence: "synthetic-stopped-reconciled" };
      await t.mutation(internal.deletion.reconcileWork, args); await t.mutation(internal.deletion.reconcileWork, args);
    }
    await drain(t, d._id);
    expect(await t.run(ctx => ctx.storage.get(late))).toBeNull();
    expect((await snapshot(t, owner)).every(rows => rows.length === 0)).toBe(true);
    expect((await t.run(ctx => ctx.db.query("transcriptionInventory").unique()))?.jobs).toEqual([]);
    await t.mutation(internal.batches.finish, { id: running.attempt._id, fence: running.attempt.fence, rawText, known: true, fileDeleted: true });
    await t.mutation(internal.batchChat.finish, { id: op._id, fence: op.fence, outcome: "completed", text: "Too late" });
    expect((await snapshot(t, owner)).every(rows => rows.length === 0)).toBe(true);
    await pendingProviders(t, alice, d._id, true);
  });

  it("keeps broad provider status, sends and retention pending after scoped account handling", async () => {
    const { t, alice } = setup();
    await recordings(t, owner);
    const d = await request(t, alice); await drain(t, d._id);
    // Synthetic case evidence only. Issue closure/manual communication is not a DB flag.
    await t.run(ctx => ctx.db.patch(d._id, { automationRevision: 0, discoveryComplete: true }));
    for (const stage of ["apple", "clerk", "revenuecat"] as const) {
      const current = (await t.run(ctx => ctx.db.get(d._id)))!;
      await t.mutation(internal.deletion.confirm, { id: d._id, owner, stage, complete: true,
        evidence: `synthetic-${stage}-disposition`, automationRevision: current.automationRevision });
    }
    expect(await alice.query(internal.deletion.status, {})).toMatchObject({
      requested: true, localComplete: true, providersComplete: false,
    });
    expect(await t.run(ctx => ctx.db.get(d._id))).toMatchObject({
      clerk: true, apple: true, revenuecat: true, gemini: false, residuals: false,
    });
    expect(await t.run(ctx => ctx.db.query("deletionOutbox").withIndex("by_request", q => q.eq("request", d._id)).unique()))
      .toMatchObject({ localComplete: true, providersComplete: false, classification: "exceptions" });
    vi.stubEnv("DELETION_EMAIL_ENABLED", "true");
    vi.stubEnv("DELETION_CONTACT_RETENTION_APPROVED", "true");
    expect(await t.query(internal.deletionNotifications.inventory, { id: d._id, owner }))
      .toMatchObject({ completionEligible: false, send: null });
    expect(await t.mutation(internal.deletionNotifications.freeze, { id: d._id, owner })).toBeNull();
    vi.setSystemTime(Date.now() + 91 * 86400_000);
    expect(await t.mutation(internal.deletionRetention.purgeExpired, {})).toBe(0);
    const retained = await t.run(ctx => ctx.db.get(d._id));
    expect(retained).not.toBeNull();
    expect(retained?.completedAt).toBeUndefined(); expect(retained?.purgeAt).toBeUndefined();
    expect(await t.run(ctx => ctx.db.query("deletionSends").collect())).toEqual([]);
    expect(await t.run(ctx => ctx.db.query("deletionReceipts").collect())).toEqual([]);
    await expect(t.query(internal.deletion.check, { owner })).rejects.toThrow("Account deletion");
    expect(fetch).not.toHaveBeenCalled();
  });

  it("recovers a failed second cleanup batch and suppresses restored content only while the guard is retained", async () => {
    const { t, alice, bob } = setup(); const a = await recordings(t, owner, 9); await recordings(t, bobOwner);
    const ab = await batch(t, alice, owner, 1); await chat(t, alice, ab.batchId, 2);
    const beforeBob = await snapshot(t, bobOwner), d = await request(t, alice);
    await t.mutation(internal.deletion.cleanup, { id: d._id });
    const remaining = a.rows[8];
    await t.run(ctx => ctx.db.patch(a.bucket, { secondsReserved: 0 }));
    const beforeFailure = await snapshot(t, owner);
    await expect(t.mutation(internal.deletion.cleanup, { id: d._id })).rejects.toThrow("Usage accounting");
    expect(await snapshot(t, owner)).toEqual(beforeFailure);
    expect(await t.run(async ctx => (await ctx.storage.get(remaining.audio)) !== null)).toBe(true);
    for (const row of a.rows.slice(0, 8)) expect(await t.run(ctx => ctx.storage.get(row.audio))).toBeNull();
    expect((await alice.fetch(`/recordings?id=${remaining.id}`)).status).toBe(403);
    await t.run(ctx => ctx.db.patch(a.bucket, { secondsReserved: 10 }));
    await t.mutation(internal.deletion.retry, { id: d._id, owner }); await drain(t, d._id);
    await pendingProviders(t, alice, d._id, true);
    const restored = await recordings(t, owner);
    // Restore synthetic batch/chat rows and blobs, but deliberately retain the guard.
    // Full rollback of the guard or restore after purge needs an operator procedure.
    const restoredBatch = await t.run(async ctx => {
      const audio = await ctx.storage.store(new Blob(["Restored synthetic batch audio"]));
      const parent = await ctx.db.insert("transcriptionBatches", { owner, subject: "completion-alice", issuer: "issuer",
        clientBatchId: uuid(10), manifestDigest: "synthetic-restored", manifest: { version: 1,
          source: { sha256: "a".repeat(64), bytes: 1, duration: { value: 5, timescale: 4 } }, chunks: [{ sha256: "a".repeat(64), bytes: 1 }] },
        revision: 1, sealed: true, createdAt: Date.now() });
      await ctx.db.insert("transcriptionChunks", { parent, owner, index: 0, state: "succeeded", attempt: 1, fence: 1, quota: 2, audio, rawText });
      await ctx.db.insert("batchChatContexts", { parent, owner, digest: "synthetic-restored", text: "Restored synthetic context" });
      await ctx.db.insert("batchChats", { parent, owner, revision: 1, exchanges: [{ clientMessageId: uuid(11), contextDigest: "synthetic-restored", message: "Restored question", reply: "Restored answer" }] });
      return { parent, audio };
    });
    for (const path of [`/recordings?id=${restored.rows[0].id}`, `${root}?batchId=${restoredBatch.parent}`,
      `${root}/chat?batchId=${restoredBatch.parent}`, "/billing"]) expect((await alice.fetch(path)).status).toBe(403);
    expect((await request(t, alice))._id).toBe(d._id);
    await t.mutation(internal.deletion.retry, { id: d._id, owner }); await drain(t, d._id);
    for (const audio of [restored.rows[0].audio, restoredBatch.audio]) expect(await t.run(ctx => ctx.storage.get(audio))).toBeNull();
    expect((await snapshot(t, owner)).every(rows => rows.length === 0)).toBe(true);
    expect(await snapshot(t, bobOwner)).toEqual(beforeBob);
    expect(await bob.query(internal.deletion.status, {})).toMatchObject({ requested: false });
    await pendingProviders(t, alice, d._id, true);
  });
});
