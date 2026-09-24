import type { MutationCtx } from "./_generated/server";
import { internalMutation } from "./_generated/server";
import type { Doc, Id } from "./_generated/dataModel";
import { internal } from "./_generated/api";

export const DELETION_RETENTION_MS = 90 * 24 * 60 * 60 * 1000;
const CHILD_BATCH = 16;

function complete(d: Doc<"deletions">) {
  return d.localComplete && d.clerk && d.revenuecat && d.apple && d.gemini && d.residuals;
}

export async function syncDeletionRetention(ctx: MutationCtx, id: Id<"deletions">) {
  const d = await ctx.db.get(id);
  if (!d) return;
  if (complete(d)) {
    if (d.completedAt === undefined || d.purgeAt === undefined) {
      const completedAt = Date.now();
      await ctx.db.patch(id, { completedAt, purgeAt: completedAt + DELETION_RETENTION_MS });
    }
  } else if (d.completedAt !== undefined || d.purgeAt !== undefined) {
    await ctx.db.patch(id, { completedAt: undefined, purgeAt: undefined });
  }
}

async function deleteBatch(ctx: MutationCtx, id: Id<"deletions">) {
  const observations = await ctx.db.query("deletionPreflights")
    .withIndex("by_request_provider", q => q.eq("request", id)).take(CHILD_BATCH);
  if (observations.length) { for (const row of observations) await ctx.db.delete(row._id); return true; }
  const preflightReceipts = await ctx.db.query("deletionPreflightReceipts")
    .withIndex("by_request_provider", q => q.eq("request", id)).take(CHILD_BATCH);
  if (preflightReceipts.length) { for (const row of preflightReceipts) await ctx.db.delete(row._id); return true; }
  const sends = await ctx.db.query("deletionSends").withIndex("by_request", q => q.eq("request", id)).take(CHILD_BATCH);
  if (sends.length) { for (const row of sends) await ctx.db.delete(row._id); return true; }
  const contacts = await ctx.db.query("deletionContacts").withIndex("by_request", q => q.eq("request", id)).take(CHILD_BATCH);
  if (contacts.length) { for (const row of contacts) await ctx.db.delete(row._id); return true; }
  const stages = await ctx.db.query("deletionStages").withIndex("by_request_key", q => q.eq("request", id)).take(CHILD_BATCH);
  if (stages.length) { for (const row of stages) await ctx.db.delete(row._id); return true; }
  const outbox = await ctx.db.query("deletionOutbox").withIndex("by_request", q => q.eq("request", id)).take(CHILD_BATCH);
  if (outbox.length) { for (const row of outbox) await ctx.db.delete(row._id); return true; }
  return false;
}

// Purging is independent of intake/provider gates. Every invocation is bounded and
// resumes itself until the expired request and all identifier-bearing children are gone.
export const purgeExpired = internalMutation({ args: {}, handler: async ctx => {
  const d = await ctx.db.query("deletions")
    .withIndex("by_purge_at", q => q.gte("purgeAt", 0).lte("purgeAt", Date.now())).first();
  if (!d) return 0;
  if (!complete(d) || d.completedAt === undefined || d.purgeAt === undefined) {
    await ctx.db.patch(d._id, { completedAt: undefined, purgeAt: undefined });
    return 0;
  }
  // A completed request must not have unresolved work. Fail closed if state is inconsistent.
  if (await ctx.db.query("deletionWork").withIndex("by_owner", q => q.eq("owner", d.owner)).first()) {
    await ctx.db.patch(d._id, { completedAt: undefined, purgeAt: undefined });
    return 0;
  }
  if (await deleteBatch(ctx, d._id)) {
    await ctx.scheduler.runAfter(0, internal.deletionRetention.purgeExpired, {});
    return 0;
  }
  await ctx.db.insert("deletionReceipts", {
    completedAt: d.completedAt, purgedAt: Date.now(), policy: "completed_90d_v1",
  });
  await ctx.db.delete(d._id);
  await ctx.scheduler.runAfter(0, internal.deletionRetention.purgeExpired, {});
  return 1;
} });
