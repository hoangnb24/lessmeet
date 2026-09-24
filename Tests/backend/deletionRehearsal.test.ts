import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "../../convex/schema";
import { internal } from "../../convex/_generated/api";

// Historical row-only characterization retained to demonstrate that bypassing the
// deletion request/guard is STILL unsafe. See deletion.test.ts for the new workflow.
// All storage/database operations below are in-memory convex-test fixtures.
const modules = import.meta.glob(["../../convex/**/*.{ts,js}", "!../../convex/**/*.d.ts", "!../../convex/auth.config.ts"]);
const setup = () => convexTest({ schema, modules, transactionLimits: true });
type T = ReturnType<typeof setup>;
async function seed(t: T, owner: string, status: "queued" | "processing" | "ready" = "ready") {
  return t.run(async ctx => {
    const audio = await ctx.storage.store(new Blob(["synthetic-only"]));
    const bucket = await ctx.db.insert("quotaBuckets", { owner, window: "free", secondsUsed: 0,
      secondsReserved: 10, questionsUsed: 0, questionsReserved: 0 });
    const id = await ctx.db.insert("recordings", { owner, audio, mimeType: "audio/m4a", status,
      messages: [], transcriptionReservation: { bucket, seconds: 10, questions: 0 } });
    return { id, audio, bucket };
  });
}
beforeEach(() => {
  vi.stubGlobal("fetch", vi.fn(() => { throw new Error("Network forbidden in deletion rehearsal"); }));
  vi.stubEnv("BILLING_ENFORCEMENT_ENABLED", "true");
  vi.stubEnv("REVENUECAT_ORIGINAL_USER_POLICY_CONFIRMED", "true");
  vi.stubEnv("REVENUECAT_SECRET_API_KEY", "sk_synthetic_only");
});
afterEach(() => { expect(fetch).not.toHaveBeenCalled(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); });

describe("Deletion rehearsal: characterization, NOT release acceptance", () => {
  it("GAP: deleting only a recording row leaves its blob and reserved quota", async () => {
    const t = setup(), a = await seed(t, "issuer|alice");
    await t.run(ctx => ctx.db.delete(a.id));
    await t.run(async ctx => {
      expect(await ctx.db.get(a.id)).toBeNull();
      expect(await ctx.storage.get(a.audio)).not.toBeNull();
      expect((await ctx.db.get(a.bucket))?.secondsReserved).toBe(10);
    });
    await t.mutation(internal.recordings.expireJob, { id: a.id });
    expect((await t.run(ctx => ctx.db.get(a.bucket)))?.secondsReserved).toBe(10);
  });

  it("exact fixture targets preserve another owner's data; repeat inventory finds nothing", async () => {
    const t = setup(), a = await seed(t, "issuer|alice"), b = await seed(t, "issuer|bob");
    // Controlled, quiescent fixture only: this is NOT an operator deletion API.
    async function removeFixture() {
      return t.run(async ctx => {
        const row = await ctx.db.get(a.id);
        if (!row) return;
        expect(row.owner).toBe("issuer|alice");
        await ctx.storage.delete(row.audio);
        await ctx.db.delete(a.id);
        await ctx.db.delete(a.bucket);
      });
    }
    await removeFixture(); await removeFixture();
    await t.run(async ctx => {
      expect(await ctx.storage.get(a.audio)).toBeNull();
      expect(await ctx.db.get(a.id)).toBeNull();
      expect(await ctx.db.get(a.bucket)).toBeNull();
      expect((await ctx.db.get(b.id))?.owner).toBe("issuer|bob");
      expect(await ctx.storage.get(b.audio)).not.toBeNull();
      expect((await ctx.db.get(b.bucket))?.secondsReserved).toBe(10);
    });
  });

  it("deleted queued row cannot be claimed; late transcription cannot recreate row", async () => {
    const t = setup(), a = await seed(t, "issuer|alice", "queued");
    await t.run(ctx => ctx.db.delete(a.id));
    expect(await t.mutation(internal.recordings.claimJob, { id: a.id })).toBeNull();
    await t.mutation(internal.recordings.finishJob, { id: a.id, transcript: "late synthetic output" });
    expect(await t.run(ctx => ctx.db.get(a.id))).toBeNull();
  });

  it("deleted processing row fails authorization and rejects a late chat write", async () => {
    const t = setup(), a = await seed(t, "issuer|alice", "processing");
    await t.run(ctx => ctx.db.delete(a.id));
    await expect(t.mutation(internal.recordings.authorizeJob, { id: a.id })).rejects.toThrow();
    const alice = t.withIdentity({ tokenIdentifier: "issuer|alice", subject: "alice" });
    await expect(alice.mutation(internal.recordings.finishChat, {
      id: a.id, lease: "synthetic-lease", message: "question", text: "late reply",
    })).rejects.toThrow();
    expect(await t.run(ctx => ctx.db.get(a.id))).toBeNull();
  });

  it("GAP: raw billing-row deletion without registering a deletion request permits recreation", async () => {
    const t = setup();
    const args = { owner: "issuer|alice", subject: "alice" };
    await t.mutation(internal.billing.beginVerification, args);
    await t.run(async ctx => {
      const row = await ctx.db.query("billingAccounts").withIndex("by_owner", q => q.eq("owner", args.owner)).unique();
      await ctx.db.delete(row!._id);
    });
    await t.mutation(internal.billing.beginVerification, args);
    expect(await t.run(ctx => ctx.db.query("billingAccounts").first())).toMatchObject(args);
  });
});
