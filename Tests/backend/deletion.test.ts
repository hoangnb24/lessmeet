import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "../../convex/schema";
import { internal } from "../../convex/_generated/api";
import { replyToTranscript, transcribeAudio } from "../../convex/gemini";
import type { Id } from "../../convex/_generated/dataModel";

vi.mock("../../convex/gemini", () => ({
  replyToTranscript: vi.fn(), transcribeAudio: vi.fn(),
  safeFailure: () => "Provider unavailable; cleanup may remain pending.", GeminiFailure: class extends Error {},
}));
const modules = import.meta.glob(["../../convex/**/*.{ts,js}", "!../../convex/**/*.d.ts", "!../../convex/auth.config.ts"]);
const owner = "issuer|alice";
const confirmation = { method: "POST", body: JSON.stringify({ confirm: "delete-account" }) };
function setup() {
  const t = convexTest({ schema, modules, transactionLimits: true });
  return { t, alice: t.withIdentity({ tokenIdentifier: owner, subject: "alice" }),
    otherIssuer: t.withIdentity({ tokenIdentifier: "different-issuer|alice", subject: "alice" }),
    bob: t.withIdentity({ tokenIdentifier: "issuer|bob", subject: "bob" }) };
}
type T = ReturnType<typeof setup>["t"];
async function seed(t: T, who = owner, count = 1) {
  return t.run(async ctx => {
    const bucket = await ctx.db.insert("quotaBuckets", { owner: who, window: "free", secondsUsed: 7,
      secondsReserved: count * 10, questionsUsed: 2, questionsReserved: count });
    const rows = [];
    for (let i = 0; i < count; i++) {
      const audio = await ctx.storage.store(new Blob(["synthetic-only"]));
      const id = await ctx.db.insert("recordings", { owner: who, subject: "alice", audio, mimeType: "audio/m4a",
        status: "ready", transcript: "Synthetic transcript", messages: [],
        transcriptionReservation: { bucket, seconds: 10, questions: 0 }, chatReservation: { bucket, seconds: 0, questions: 1 } });
      rows.push({ id, audio });
    }
    return { bucket, rows };
  });
}
async function deletion(t: T) {
  return (await t.run(ctx => ctx.db.query("deletions").withIndex("by_owner", q => q.eq("owner", owner)).unique()))!;
}
async function drain(t: T, id: Id<"deletions">) {
  // Direct bounded invocations keep scheduler execution deterministic and offline.
  for (let i = 0; i < 8; i++) await t.mutation(internal.deletion.cleanup, { id });
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(r => { resolve = r; });
  return { promise, resolve };
}
beforeEach(() => {
  vi.useFakeTimers(); vi.resetAllMocks();
  vi.stubEnv("ACCOUNT_DELETION_ENABLED", "true");
  vi.stubEnv("BILLING_ENFORCEMENT_ENABLED", "false");
  vi.stubEnv("GEMINI_BILLABLE_ENABLED", "true");
  vi.stubGlobal("fetch", vi.fn(() => { throw new Error("External network forbidden"); }));
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); });

describe("authenticated deletion, bounded cleanup and durable provider work", () => {
  it("requires authentication and activation; has no anonymous/operator HTTP write surface", async () => {
    const { t, alice } = setup();
    expect((await t.fetch("/account/deletion")).status).toBe(401);
    expect((await t.fetch("/account/deletion", confirmation)).status).toBe(401);
    vi.stubEnv("ACCOUNT_DELETION_ENABLED", "false");
    expect((await alice.fetch("/account/deletion", confirmation)).status).toBe(503);
    expect(await t.run(ctx => ctx.db.query("deletions").collect())).toEqual([]);
    expect(fetch).not.toHaveBeenCalled();
  });

  it("requires exact confirmation, refuses caller identity and derives issuer-bound owner", async () => {
    const { t, alice, bob, otherIssuer } = setup();
    for (const body of ["{}", "null", "bad JSON", JSON.stringify({ confirm: "delete-account", owner: "issuer|bob" })]) {
      expect((await alice.fetch("/account/deletion", { method: "POST", body })).status).toBe(400);
    }
    expect((await alice.fetch("/account/deletion?owner=issuer%7Cbob", confirmation)).status).toBe(400);
    expect((await alice.fetch("/account/deletion", { method: "POST", body: "x".repeat(129) })).status).toBe(413);
    expect((await alice.fetch("/account/deletion", confirmation)).status).toBe(202);
    const first = await deletion(t);
    vi.stubEnv("ACCOUNT_DELETION_ENABLED", "false"); // retries stay idempotent even when new intake is disabled
    expect((await alice.fetch("/account/deletion", confirmation)).status).toBe(202);
    expect((await deletion(t))._id).toBe(first._id);
    expect(await t.run(ctx => ctx.db.query("deletions").collect())).toHaveLength(1);
    expect(await (await bob.fetch("/account/deletion")).json()).toMatchObject({ userId: "bob", requested: false });
    expect(await (await otherIssuer.fetch("/account/deletion")).json()).toMatchObject({ userId: "alice", requested: false });
    expect((await otherIssuer.fetch("/account")).status).toBe(200);
    expect((await alice.fetch("/account")).status).toBe(403);
    expect(await (await alice.fetch("/account/deletion")).json()).toMatchObject({ requested: true, localComplete: false, providersComplete: false });
  });

  it("bounds batches, settles reservations, removes blobs/buckets/billing and preserves other owners", async () => {
    const { t, alice } = setup();
    const a = await seed(t, owner, 10), b = await seed(t, "issuer|bob"), c = await seed(t, "different-issuer|alice");
    await t.run(ctx => ctx.db.insert("billingAccounts", { owner, subject: "alice", revision: 1 }));
    await alice.mutation(internal.deletion.request, {});
    const d = await deletion(t);
    await t.mutation(internal.deletion.cleanup, { id: d._id });
    expect(await t.run(ctx => ctx.db.query("recordings").withIndex("by_owner", q => q.eq("owner", owner)).collect())).toHaveLength(2);
    expect(await t.run(ctx => ctx.db.get(a.bucket))).toMatchObject({ secondsReserved: 20, questionsReserved: 2 });
    await drain(t, d._id); await drain(t, d._id);
    await t.run(async ctx => {
      for (const row of a.rows) { expect(await ctx.db.get(row.id)).toBeNull(); expect(await ctx.storage.get(row.audio)).toBeNull(); }
      expect(await ctx.db.get(a.bucket)).toBeNull();
      expect(await ctx.db.query("billingAccounts").first()).toBeNull();
      for (const fixture of [b, c]) {
        expect(await ctx.db.get(fixture.rows[0].id)).not.toBeNull();
        expect(await ctx.storage.get(fixture.rows[0].audio)).not.toBeNull();
        expect(await ctx.db.get(fixture.bucket)).toMatchObject({ secondsReserved: 10, questionsReserved: 1 });
      }
    });
    expect(await alice.query(internal.deletion.status, {})).toMatchObject({ localComplete: true, providersComplete: false });
    expect(await deletion(t)).toMatchObject({ clerk: false, revenuecat: false, apple: false, gemini: false, residuals: false });
    expect(fetch).not.toHaveBeenCalled();
  });

  it("keeps failed cleanup transactional and retryable without erasing the owner guard", async () => {
    const { t, alice } = setup(); const a = await seed(t);
    await t.run(ctx => ctx.db.patch(a.bucket, { secondsReserved: 0 }));
    await alice.mutation(internal.deletion.request, {}); const d = await deletion(t);
    await expect(t.mutation(internal.deletion.cleanup, { id: d._id })).rejects.toThrow("Usage accounting");
    await t.run(async ctx => { expect(await ctx.storage.get(a.rows[0].audio)).not.toBeNull(); });
    expect(await t.run(ctx => ctx.db.get(a.rows[0].id))).not.toBeNull();
    expect((await deletion(t)).localComplete).toBe(false);
    await t.run(ctx => ctx.db.patch(a.bucket, { secondsReserved: 10 }));
    await t.mutation(internal.deletion.retry, { id: d._id, owner });
    await drain(t, d._id);
    expect((await deletion(t)).localComplete).toBe(true);
    await expect(t.query(internal.deletion.check, { owner })).rejects.toThrow("Account deletion");
  });

  it("guards upload/chat/queued and in-flight job writes and billing even without enforcement", async () => {
    const { t, alice } = setup(); const a = await seed(t);
    const id = a.rows[0].id;
    await t.run(ctx => ctx.db.patch(id, { status: "queued" }));
    await alice.mutation(internal.deletion.request, {});
    expect((await alice.fetch("/recordings", { method: "POST", headers: { "Content-Type": "audio/m4a" }, body: "synthetic" })).status).toBe(403);
    expect((await alice.fetch(`/recordings?id=${id}`)).status).toBe(403);
    expect((await alice.fetch("/chat", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ recordingId: id, message: "q" }) })).status).toBe(403);
    expect((await alice.fetch("/billing")).status).toBe(403);
    expect((await alice.fetch("/billing/sync", { method: "POST" })).status).toBe(403);
    await expect(alice.mutation(internal.recordings.create, { audio: a.rows[0].audio, mimeType: "audio/m4a" })).rejects.toThrow("Account deletion");
    expect(await t.mutation(internal.recordings.claimJob, { id })).toBeNull();
    await t.run(ctx => ctx.db.patch(id, { status: "processing" }));
    await expect(t.mutation(internal.recordings.authorizeJob, { id })).rejects.toThrow("Account deletion");
    await t.mutation(internal.recordings.finishJob, { id, transcript: "late" });
    expect((await t.run(ctx => ctx.db.get(id)))?.transcript).toBe("Synthetic transcript");
    await expect(t.mutation(internal.billing.beginVerification, { owner, subject: "alice" })).rejects.toThrow("Account deletion");
    await expect(t.mutation(internal.billing.applyVerification, { owner, subject: "alice", revision: 1,
      observedAt: Date.now(), plan: "free", anchor: null, expiresAt: null })).rejects.toThrow("Account deletion");
    expect(fetch).not.toHaveBeenCalled(); expect(replyToTranscript).not.toHaveBeenCalled();
  });

  it("an admitted upload that crosses deletion cannot create a recording and keeps its orphan discoverable", async () => {
    const { t, alice } = setup();
    const work = await t.mutation(internal.deletion.beginWork, { owner, kind: "upload" });
    await alice.mutation(internal.deletion.request, {}); const d = await deletion(t);
    const audio = await t.run(ctx => ctx.storage.store(new Blob(["late synthetic storage result"])));
    await t.mutation(internal.deletion.track, { id: work, audio });
    await expect(alice.mutation(internal.recordings.create, { audio, mimeType: "audio/m4a" })).rejects.toThrow("Account deletion");
    await drain(t, d._id);
    expect((await deletion(t)).localComplete).toBe(false);
    const inventory = await t.query(internal.deletion.inventory, { id: d._id, owner, cursor: null });
    expect(inventory.work.page).toMatchObject([{ _id: work, audio, finished: false, ambiguous: true }]);
    // Synthetic operator proof: this fixture action has ended and the exact object is known.
    await t.mutation(internal.deletion.reconcileWork, { id: d._id, owner, workId: work, evidence: "synthetic-case" });
    expect(await t.run(ctx => ctx.storage.get(audio))).toBeNull();
    await drain(t, d._id); expect((await deletion(t)).localComplete).toBe(true);
    await t.mutation(internal.deletion.reconcileWork, { id: d._id, owner, workId: work, evidence: "synthetic-case" });
  });

  it("a slow HTTP upload body cannot bypass a lock acquired while reading it", async () => {
    const { t, alice } = setup();
    const reading = deferred<void>();
    let controller!: ReadableStreamDefaultController<Uint8Array>;
    const body = new ReadableStream<Uint8Array>({ start(c) { controller = c; }, pull() { reading.resolve(); } });
    const init = { method: "POST", headers: { "Content-Type": "audio/m4a" }, body, duplex: "half" };
    const response = alice.fetch("/recordings", init);
    await reading.promise;
    await alice.mutation(internal.deletion.request, {});
    controller.enqueue(new TextEncoder().encode("synthetic audio")); controller.close();
    expect((await response).status).toBe(403);
    expect(await t.run(ctx => ctx.db.system.query("_storage").collect())).toEqual([]);
    expect(fetch).not.toHaveBeenCalled();
  });

  it("an in-flight RevenueCat read cannot recreate billing after deletion; its durable work drains", async () => {
    const { t, alice } = setup();
    vi.stubEnv("BILLING_ENFORCEMENT_ENABLED", "true");
    vi.stubEnv("REVENUECAT_ORIGINAL_USER_POLICY_CONFIRMED", "true");
    vi.stubEnv("REVENUECAT_SECRET_API_KEY", "sk_synthetic_only");
    const started = deferred<void>(), finish = deferred<Response>();
    vi.mocked(fetch).mockImplementation(async () => { started.resolve(); return finish.promise; });
    const response = alice.fetch("/billing"); await started.promise;
    await alice.mutation(internal.deletion.request, {}); const d = await deletion(t);
    await drain(t, d._id); expect((await deletion(t)).localComplete).toBe(false);
    finish.resolve(Response.json({ request_date_ms: Date.now(), subscriber: {
      original_app_user_id: "alice", entitlements: {}, subscriptions: {},
    } }));
    expect((await response).status).toBe(403);
    await drain(t, d._id); expect((await deletion(t)).localComplete).toBe(true);
    expect(await t.run(ctx => ctx.db.query("billingAccounts").collect())).toEqual([]);
    expect((await alice.fetch("/billing")).status).toBe(403);
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("missing blobs are idempotent and restored rows cannot defeat a retained tombstone", async () => {
    const { t, alice } = setup(); const a = await seed(t);
    await t.run(ctx => ctx.storage.delete(a.rows[0].audio));
    await alice.mutation(internal.deletion.request, {}); const d = await deletion(t); await drain(t, d._id);
    expect((await deletion(t)).localComplete).toBe(true);
    const restored = await seed(t); // synthetic backup restore, retaining suppression ledger
    expect((await alice.fetch(`/recordings?id=${restored.rows[0].id}`)).status).toBe(403);
    await t.mutation(internal.deletion.retry, { id: d._id, owner }); await drain(t, d._id);
    await t.run(async ctx => { expect(await ctx.storage.get(restored.rows[0].audio)).toBeNull(); });
    expect(await t.run(ctx => ctx.db.get(restored.rows[0].id))).toBeNull();
    expect((await deletion(t)).localComplete).toBe(true);
  });

  it("missing legacy quota buckets are harmless; corrupt cross-owner reservations fail without touching either owner", async () => {
    const { t, alice } = setup(); const a = await seed(t), b = await seed(t, "issuer|bob");
    await t.run(ctx => ctx.db.patch(a.rows[0].id, { transcriptionReservation: { bucket: b.bucket, seconds: 10, questions: 0 } }));
    await alice.mutation(internal.deletion.request, {}); const d = await deletion(t);
    await expect(t.mutation(internal.deletion.cleanup, { id: d._id })).rejects.toThrow("ownership needs operator review");
    expect(await t.run(ctx => ctx.db.get(b.bucket))).toMatchObject({ secondsReserved: 10 });
    expect(await t.run(ctx => ctx.db.get(a.rows[0].id))).not.toBeNull();
    await t.run(async ctx => {
      await ctx.db.patch(a.rows[0].id, { transcriptionReservation: { bucket: a.bucket, seconds: 10, questions: 0 } });
      await ctx.db.delete(a.bucket);
    });
    await drain(t, d._id); expect((await deletion(t)).localComplete).toBe(true);
    expect(await t.run(ctx => ctx.db.get(b.bucket))).toMatchObject({ secondsReserved: 10, questionsReserved: 1 });
  });

  it("failed upload cleanup requires its authenticated owner and exact admitted storage target", async () => {
    const { t, alice, bob } = setup();
    const work = await t.mutation(internal.deletion.beginWork, { owner, kind: "upload" });
    const audio = await t.run(ctx => ctx.storage.store(new Blob(["synthetic-owned"])));
    const other = await t.run(ctx => ctx.storage.store(new Blob(["synthetic-other"])));
    await t.mutation(internal.deletion.track, { id: work, audio });
    await expect(bob.mutation(internal.deletion.discardUpload, { id: work, audio })).rejects.toThrow("target mismatch");
    await expect(alice.mutation(internal.deletion.discardUpload, { id: work, audio: other })).rejects.toThrow("target mismatch");
    await alice.mutation(internal.deletion.discardUpload, { id: work, audio });
    await t.run(async ctx => {
      expect(await ctx.storage.get(audio)).toBeNull(); expect(await ctx.storage.get(other)).not.toBeNull();
    });
  });

  it("lost provider/upload acknowledgments never expire into success and survive repeat requests", async () => {
    const { t, alice } = setup();
    const work = await t.mutation(internal.deletion.beginWork, { owner, kind: "gemini" });
    await t.mutation(internal.deletion.finishWork, { id: work, ambiguous: true });
    await alice.mutation(internal.deletion.request, {}); const d = await deletion(t);
    vi.setSystemTime(Date.now() + 365 * 86400_000);
    await drain(t, d._id); await alice.mutation(internal.deletion.request, {});
    expect((await deletion(t)).localComplete).toBe(false);
    expect(await t.run(ctx => ctx.db.get(work))).toMatchObject({ finished: true, ambiguous: true });
    await expect(t.mutation(internal.deletion.confirm, { id: d._id, owner, stage: "gemini", complete: true, evidence: "case" })).rejects.toThrow("outstanding operations");
  });

  it("in-flight chat cannot persist after locking; active work prevents early completion", async () => {
    const { t, alice } = setup(); const a = await seed(t);
    // This fixture has no existing chat reservation; reserveChat creates the lease.
    await t.run(ctx => ctx.db.patch(a.rows[0].id, { chatReservation: undefined }));
    const started = deferred<void>(), finish = deferred<string>();
    vi.mocked(replyToTranscript).mockImplementation(async () => { started.resolve(); return finish.promise; });
    const response = alice.fetch("/chat", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ recordingId: a.rows[0].id, message: "question" }) });
    await started.promise;
    await alice.mutation(internal.deletion.request, {}); const d = await deletion(t);
    await drain(t, d._id); expect((await deletion(t)).localComplete).toBe(false);
    finish.resolve("late reply"); expect((await response).status).toBe(403);
    await drain(t, d._id);
    expect((await deletion(t)).localComplete).toBe(true);
    expect(await t.run(ctx => ctx.db.get(a.rows[0].id))).toBeNull();
  });

  it("in-flight Gemini file is captured after lock and cleanup failure remains pending for manual retry", async () => {
    const { t, alice } = setup(); const a = await seed(t);
    await t.run(ctx => ctx.db.patch(a.rows[0].id, { status: "queued" }));
    const started = deferred<void>(), finish = deferred<void>();
    vi.mocked(transcribeAudio).mockImplementation(async (_, __, lifecycle) => {
      started.resolve(); await finish.promise;
      await lifecycle!.uploaded("files/synthetic");
      // Simulate the late upload response followed by failed provider DELETE.
      throw new Error("provider DELETE unavailable");
    });
    const job = t.action(internal.jobs.transcribe, { id: a.rows[0].id });
    await started.promise;
    await alice.mutation(internal.deletion.request, {}); const d = await deletion(t);
    await drain(t, d._id); finish.resolve(); await job;
    const work = (await t.query(internal.deletion.inventory, { id: d._id, owner, cursor: null })).work.page[0];
    expect(work).toMatchObject({ file: "files/synthetic", fileDeleted: false, finished: true, ambiguous: true });
    await drain(t, d._id); expect((await deletion(t)).localComplete).toBe(false);
    await t.mutation(internal.deletion.confirm, { id: d._id, owner, stage: "gemini", complete: false, evidence: "provider-failed" });
    await expect(t.mutation(internal.deletion.reconcileWork, { id: d._id, owner: "issuer|bob", workId: work._id, evidence: "case" })).rejects.toThrow("Exact deletion target");
    // This mutation is evidence attestation, not a fake provider deletion implementation.
    await t.mutation(internal.deletion.reconcileWork, { id: d._id, owner, workId: work._id, evidence: "synthetic-provider-proof" });
    await drain(t, d._id); expect((await deletion(t)).localComplete).toBe(true);
    expect((await deletion(t)).gemini).toBe(false);
  });

  it("a deleted Gemini File does not prove an interrupted generation has stopped", async () => {
    const { t, alice } = setup(); const a = await seed(t);
    await t.run(ctx => ctx.db.patch(a.rows[0].id, { status: "queued" }));
    vi.mocked(transcribeAudio).mockImplementation(async (_, __, lifecycle) => {
      await lifecycle!.uploaded("files/synthetic-timeout");
      await lifecycle!.generationStarted!();
      lifecycle!.deleted(); // DELETE acknowledged, generation response never arrived.
      throw new Error("generation timeout");
    });
    await t.action(internal.jobs.transcribe, { id: a.rows[0].id });
    await alice.mutation(internal.deletion.request, {}); const d = await deletion(t); await drain(t, d._id);
    expect((await deletion(t)).localComplete).toBe(false);
    const inventory = await t.query(internal.deletion.inventory, { id: d._id, owner, cursor: null });
    expect(inventory.work.page[0]).toMatchObject({ finished: true, ambiguous: true, fileDeleted: true });
  });

  it("successful transcription discards its temporary ledger only after generation and file deletion finish", async () => {
    const { t, alice } = setup(); const a = await seed(t);
    await t.run(ctx => ctx.db.patch(a.rows[0].id, { status: "queued" }));
    vi.mocked(transcribeAudio).mockImplementation(async (_, __, lifecycle) => {
      await lifecycle!.checkActive(); await lifecycle!.uploaded("files/synthetic-complete");
      await lifecycle!.generationStarted!(); await lifecycle!.generationFinished!(); lifecycle!.deleted();
      return { text: "Complete synthetic transcript" };
    });
    await t.action(internal.jobs.transcribe, { id: a.rows[0].id });
    expect(await t.run(ctx => ctx.db.get(a.rows[0].id))).toMatchObject({ status: "ready", transcript: "Complete synthetic transcript" });
    expect(await t.run(ctx => ctx.db.query("deletionWork").collect())).toEqual([]);
    await alice.mutation(internal.deletion.request, {}); const d = await deletion(t); await drain(t, d._id);
    expect((await deletion(t)).localComplete).toBe(true);
  });

  it("does not infer Apple revocation from Clerk deletion or local cleanup; retries retain exact-owner progress", async () => {
    const { t, alice } = setup();
    await alice.mutation(internal.deletion.request, {}); const d = await deletion(t); await drain(t, d._id);
    for (const stage of ["clerk", "revenuecat", "gemini", "residuals"] as const) {
      await t.mutation(internal.deletion.confirm, { id: d._id, owner, stage, complete: true, evidence: `synthetic-${stage}` });
    }
    expect(await alice.query(internal.deletion.status, {})).toMatchObject({ localComplete: true, providersComplete: false });
    await t.mutation(internal.deletion.retry, { id: d._id, owner });
    await expect(t.mutation(internal.deletion.confirm, { id: d._id, owner: "issuer|bob", stage: "apple", complete: true, evidence: "case" })).rejects.toThrow();
    await t.mutation(internal.deletion.confirm, { id: d._id, owner, stage: "apple", complete: true, evidence: "synthetic-apple-proof" });
    expect(await alice.query(internal.deletion.status, {})).toMatchObject({ providersComplete: false, googleStatus: "pending" });
    // Synthetic independent Google proof; the flags above cannot create it.
    await t.run(ctx => ctx.db.patch(d._id, { googleStatus: "acknowledged", googleEvidence: "synthetic-google" }));
    expect(await alice.query(internal.deletion.status, {})).toMatchObject({ providersComplete: true });
    expect(await deletion(t)).toMatchObject({ clerkEvidence: "synthetic-clerk", appleEvidence: "synthetic-apple-proof",
      revenuecatEvidence: "synthetic-revenuecat", geminiEvidence: "synthetic-gemini", residualsEvidence: "synthetic-residuals" });
    await t.mutation(internal.deletion.confirm, { id: d._id, owner, stage: "apple", complete: false, evidence: "proof-reopened" });
    expect(await alice.query(internal.deletion.status, {})).toMatchObject({ providersComplete: false });
    expect((await alice.fetch("/billing")).status).toBe(403);
  });
});
