import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "../../convex/schema";
import { internal } from "../../convex/_generated/api";
import { publishIntent } from "../../convex/deletionAutomationState";
import { DELETION_RETENTION_MS } from "../../convex/deletionRetention";

const modules = import.meta.glob(["../../convex/**/*.{ts,js}", "!../../convex/**/*.d.ts", "!../../convex/auth.config.ts"]);
const owner = "issuer|google-completion", subject = "google-completion";
const setup = () => convexTest({ schema, modules, transactionLimits: true });
beforeEach(() => {
  vi.useFakeTimers(); vi.setSystemTime(new Date("2026-10-05T00:00:00Z"));
  vi.stubEnv("ACCOUNT_DELETION_ENABLED", "true");
  for (const name of ["DELETION_AUTOMATION_ENABLED", "DELETION_EMAIL_ENABLED", "DELETION_CONTACT_RETENTION_APPROVED"])
    vi.stubEnv(name, "false");
  vi.stubGlobal("fetch", vi.fn(() => { throw new Error("Network forbidden"); }));
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); });

async function request(t: ReturnType<typeof setup>) {
  const client = t.withIdentity({ issuer: "issuer", tokenIdentifier: owner, subject });
  await client.mutation(internal.deletion.request, {});
  const d = (await t.run(ctx => ctx.db.query("deletions").unique()))!;
  return { client, id: d._id };
}

describe("Google proof is distinct from Clerk deletion", () => {
  it("legacy completed status uses the nullable native contract without inventing Google proof", async () => {
    const t = setup(), client = t.withIdentity({ issuer: "issuer", tokenIdentifier: owner, subject });
    await t.run(ctx => ctx.db.insert("deletions", { owner, subject, requestedAt: Date.now(), updatedAt: Date.now(),
      localComplete: true, clerk: true, apple: true, revenuecat: true, gemini: true, residuals: true }));
    expect(await client.query(internal.deletion.status, {})).toMatchObject({ requested: true, providersComplete: true, googleStatus: null });
    expect((await t.run(ctx => ctx.db.query("deletions").unique()))?.googleEvidence).toBeUndefined();
  });
  it("new intake requires Google and repeated intake preserves pending proof", async () => {
    const t = setup(), { client, id } = await request(t);
    expect(await t.run(ctx => ctx.db.get(id))).toMatchObject({ googleRequired: true, googleStatus: "pending" });
    await client.mutation(internal.deletion.request, {});
    expect(await t.run(ctx => ctx.db.query("deletions").collect())).toHaveLength(1);
    expect(await client.query(internal.deletion.status, {})).toMatchObject({ googleStatus: "pending", providersComplete: false });
    expect(fetch).not.toHaveBeenCalled();
  });

  it.each([undefined, "pending", "revoking", "exception", "unknown", "acknowledged", "not_applicable"] as const)(
    "all old flags and manual Clerk acceptance cannot bypass missing Google proof: %s", async googleStatus => {
      const t = setup(), { client, id } = await request(t);
      await t.run(async ctx => {
        await ctx.db.patch(id, { localComplete: true, clerk: true, apple: true, revenuecat: true, gemini: true, residuals: true,
          googleStatus, automationRevision: 0, discoveryComplete: true });
        await publishIntent(ctx, id);
      });
      const d = (await t.run(ctx => ctx.db.get(id)))!;
      await t.mutation(internal.deletion.confirm, { id, owner, stage: "clerk", complete: true,
        evidence: "clerk-only", automationRevision: d.automationRevision });
      expect(await client.query(internal.deletion.status, {})).toMatchObject({ providersComplete: false });
      expect(await t.run(ctx => ctx.db.query("deletionOutbox").unique())).toMatchObject({ providersComplete: false, classification: "exceptions" });
      expect(await t.query(internal.deletionNotifications.inventory, { id, owner })).toMatchObject({ completionEligible: false });
      expect(await t.mutation(internal.deletionNotifications.freeze, { id, owner })).toBeNull();
      expect((await t.run(ctx => ctx.db.get(id)))?.purgeAt).toBeUndefined();
      expect(fetch).not.toHaveBeenCalled();
    });

  it("Google acknowledgement alone does not complete other provider scopes", async () => {
    const t = setup(), { client, id } = await request(t);
    await t.run(async ctx => {
      await ctx.db.patch(id, { googleStatus: "acknowledged", googleEvidence: "google-case", localComplete: true });
      await publishIntent(ctx, id);
    });
    expect(await client.query(internal.deletion.status, {})).toMatchObject({ googleStatus: "acknowledged", providersComplete: false });
    expect((await t.run(ctx => ctx.db.get(id)))?.purgeAt).toBeUndefined();
  });

  it.each(["acknowledged", "not_applicable"] as const)("retains %s proof through child-batch purge", async googleStatus => {
    const t = setup(), { id } = await request(t);
    // Synthetic accepted provider evidence, not live revocation proof.
    await t.run(async ctx => {
      await ctx.db.patch(id, { localComplete: true, clerk: true, apple: true, revenuecat: true, gemini: true, residuals: true,
        googleStatus, googleEvidence: "synthetic-google-proof", automationRevision: 0, discoveryComplete: true });
      const stage = await ctx.db.insert("deletionStages", { request: id, owner, kind: "clerk", key: "clerk", target: subject,
        config: "synthetic", state: "manual", fence: 2, attempts: 1, nextAttemptAt: Date.now(), updatedAt: Date.now() });
      await ctx.db.insert("deletionClerkExecutions", { request: id, owner, subject, requestedAt: Date.now(),
        stage, stageFence: 1, config: "synthetic", appleStage: stage, appleFence: 1, appleEvidence: "synthetic-apple",
        appleDisposition: "revocation_verified", phase: "observeUser", state: "manual", sessions: [], offset: 0, sessionIndex: 0,
        inventoryComplete: true, mutationUncertain: false, userDeleteAcknowledged: true, userAbsenceObserved: true,
        fence: 2, attempts: 1, claims: 3, due: Date.now(), code: "synthetic-proof", createdAt: Date.now(), updatedAt: Date.now() });
      await publishIntent(ctx, id);
    });
    expect((await t.run(ctx => ctx.db.get(id)))?.purgeAt).toBe(Date.now() + DELETION_RETENTION_MS);
    vi.setSystemTime(Date.now() + DELETION_RETENTION_MS + 1);
    // Drive retention only; do not run the intake cleanup scheduled in this fixture.
    for (let i = 0; i < 6; i++) await t.mutation(internal.deletionRetention.purgeExpired, {});
    expect(await t.run(ctx => ctx.db.get(id))).toBeNull();
    expect(await t.run(ctx => ctx.db.query("deletionClerkExecutions").collect())).toEqual([]);
    const receipts = await t.run(ctx => ctx.db.query("deletionReceipts").collect());
    expect(receipts).toHaveLength(1);
    expect(JSON.stringify(receipts)).not.toContain("synthetic-google-proof");
    expect(fetch).not.toHaveBeenCalled();
  });
});
