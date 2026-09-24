import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "../../convex/schema";
import { internal } from "../../convex/_generated/api";
import crons from "../../convex/crons";
import { DELETION_RETENTION_MS } from "../../convex/deletionRetention";

const modules = import.meta.glob(["../../convex/**/*.{ts,js}", "!../../convex/**/*.d.ts", "!../../convex/auth.config.ts"]);
const owner = "issuer|retention-user";
function setup() { return convexTest({ schema, modules, transactionLimits: true }); }

async function seed(t: ReturnType<typeof setup>, complete = true) {
  return t.run(ctx => ctx.db.insert("deletions", {
    owner, subject: "retention-user", requestedAt: Date.now(), updatedAt: Date.now(),
    localComplete: complete, clerk: complete, revenuecat: complete, apple: complete,
    gemini: complete, residuals: complete,
  }));
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-09-24T00:00:00Z"));
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); });

describe("completed deletion ledger retention", () => {
  it("starts a 90-day clock only at full completion and resets it if completion reopens", async () => {
    const t = setup();
    const id = await seed(t, false);
    await t.run(ctx => ctx.db.patch(id, { localComplete: true }));
    await t.mutation(internal.deletion.confirm, { id, owner, stage: "clerk", complete: true, evidence: "case-clerk" });
    const pending = await t.run(ctx => ctx.db.get(id));
    expect(pending?.completedAt).toBeUndefined(); expect(pending?.purgeAt).toBeUndefined();

    await t.run(ctx => ctx.db.patch(id, { localComplete: true, revenuecat: true, apple: true, gemini: true, residuals: true }));
    await t.mutation(internal.deletion.confirm, { id, owner, stage: "clerk", complete: true, evidence: "case-complete" });
    const completed = (await t.run(ctx => ctx.db.get(id)))!;
    expect(completed.completedAt).toBe(Date.now());
    expect(completed.purgeAt).toBe(Date.now() + DELETION_RETENTION_MS);

    await t.mutation(internal.deletion.confirm, { id, owner, stage: "apple", complete: false, evidence: "case-reopened" });
    const reopened = await t.run(ctx => ctx.db.get(id));
    expect(reopened?.completedAt).toBeUndefined(); expect(reopened?.purgeAt).toBeUndefined();
    vi.setSystemTime(Date.now() + 24 * 60 * 60 * 1000);
    await t.mutation(internal.deletion.confirm, { id, owner, stage: "apple", complete: true, evidence: "case-reclosed" });
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({
      completedAt: Date.now(), purgeAt: Date.now() + DELETION_RETENTION_MS,
    });
  });

  it("purges identifier-bearing children after 90 days and leaves only an unlinkable receipt", async () => {
    const t = setup();
    const id = await seed(t);
    await t.mutation(internal.deletion.confirm, { id, owner, stage: "apple", complete: true, evidence: "case-complete" });
    await t.run(async ctx => {
      const contact = await ctx.db.insert("deletionContacts", { request: id, owner, subject: "retention-user",
        issuer: "https://issuer.example", instance: "instance", email: "synthetic@example.test", code: "captured", capturedAt: Date.now() });
      const intent = await ctx.db.insert("deletionOutbox", { request: id, owner, revision: 1, kind: "scope_status",
        state: "intent", delivery: "not_configured", classification: "scope_complete", localComplete: true,
        providersComplete: true, updatedAt: Date.now() });
      await ctx.db.insert("deletionSends", { request: id, intent, revision: 1, owner, subject: "retention-user",
        recipient: "synthetic@example.test", contact, completion: { localComplete: true, clerk: true, apple: true,
          revenuecat: true, gemini: true, residuals: true }, config: "synthetic", payload: "synthetic payload", key: "synthetic-key",
        createdAt: Date.now(), state: "pending", delivery: "pending", code: "queued", attempts: 0, fence: 0, due: Date.now() });
      await ctx.db.insert("deletionStages", { request: id, owner, key: "clerk", kind: "clerk", target: "retention-user",
        config: "synthetic", state: "manual", fence: 1, attempts: 0, nextAttemptAt: Date.now(), evidence: "case-clerk", updatedAt: Date.now() });
      await ctx.db.insert("deletionPreflights", { request: id, owner, subject: "retention-user", requestedAt: Date.now(),
        provider: "clerk", config: "synthetic", phase: "user", cursor: "", state: "observed", code: "inventory_observed",
        inventoryComplete: true, fence: 1, attempts: 1, claims: 1, pages: 1, due: Date.now(), createdAt: Date.now(),
        updatedAt: Date.now(), purgeAt: Date.now() + 30 * 24 * 60 * 60 * 1000,
        externalAccounts: [], sessions: [], aliases: [], cursors: [] });
      await ctx.db.insert("deletionPreflightReceipts", { request: id, provider: "revenuecat", state: "observed",
        code: "complete", inventoryComplete: true, createdAt: Date.now(), updatedAt: Date.now(), purgedAt: Date.now() });
    });

    vi.setSystemTime(Date.now() + DELETION_RETENTION_MS);
    await t.mutation(internal.deletionRetention.purgeExpired, {});
    await t.finishAllScheduledFunctions(() => vi.runOnlyPendingTimers(), 100);
    for (const table of ["deletions", "deletionContacts", "deletionSends", "deletionStages", "deletionOutbox",
      "deletionPreflights", "deletionPreflightReceipts"] as const) {
      expect(await t.run(ctx => ctx.db.query(table).collect())).toEqual([]);
    }
    const receipts = await t.run(ctx => ctx.db.query("deletionReceipts").collect());
    expect(receipts).toHaveLength(1);
    expect(receipts[0]).toMatchObject({ policy: "completed_90d_v1", purgedAt: Date.now() });
    const serialized = JSON.stringify(receipts[0]);
    for (const forbidden of [owner, "retention-user", "synthetic@example.test", "case-complete", id]) {
      expect(serialized).not.toContain(forbidden);
    }
  });

  it("never purges incomplete or inconsistent requests", async () => {
    const t = setup();
    const incomplete = await seed(t, false);
    const inconsistent = await seed(t, true);
    await t.mutation(internal.deletion.confirm, { id: inconsistent, owner, stage: "apple", complete: true, evidence: "case" });
    await t.run(ctx => ctx.db.insert("deletionWork", { owner, kind: "upload", startedAt: Date.now(), finished: false, ambiguous: true }));
    vi.setSystemTime(Date.now() + DELETION_RETENTION_MS + 1);
    expect(await t.mutation(internal.deletionRetention.purgeExpired, {})).toBe(0);
    expect(await t.run(ctx => ctx.db.get(incomplete))).not.toBeNull();
    const guarded = await t.run(ctx => ctx.db.get(inconsistent));
    expect(guarded?.completedAt).toBeUndefined(); expect(guarded?.purgeAt).toBeUndefined();
    expect(await t.run(ctx => ctx.db.query("deletionReceipts").collect())).toEqual([]);
  });

  it("registers the daily purge independently of feature gates", () => {
    expect(JSON.stringify(crons.crons)).toContain("purge completed deletion ledgers");
    expect(JSON.stringify(crons.crons)).toContain("deletionRetention:purgeExpired");
  });
});
