import type { MutationCtx, QueryCtx } from "./_generated/server";
import type { Doc, Id } from "./_generated/dataModel";
import { fail } from "./limits";
import { internal } from "./_generated/api";
import { notificationsEnabled } from "./notificationAdapter";
import { syncDeletionRetention } from "./deletionRetention";

export async function exactRequest(ctx: QueryCtx | MutationCtx, id: Id<"deletions">, owner: string) {
  const d = await ctx.db.get(id);
  if (!d || d.owner !== owner) fail(404, "Exact deletion target not found.");
  return d;
}
export async function classification(ctx: QueryCtx | MutationCtx, d: Doc<"deletions">) {
  if (!d.discoveryComplete) return "queued" as const;
  for (const state of ["queued", "running", "retry"] as const) {
    if (await ctx.db.query("deletionStages").withIndex("by_request_state", q => q.eq("request", d._id).eq("state", state)).first()) return "queued" as const;
  }
  for (const state of ["blocked", "exhausted"] as const) {
    if (await ctx.db.query("deletionStages").withIndex("by_request_state", q => q.eq("request", d._id).eq("state", state)).first()) return "exceptions" as const;
  }
  return d.localComplete && d.clerk && d.apple && d.revenuecat && d.gemini && d.residuals ? "scope_complete" as const : "exceptions" as const;
}
// One mutable intent, never a send. No email address, token, payload, or delivery fiction.
export async function publishIntent(ctx: MutationCtx, id: Id<"deletions">) {
  await syncDeletionRetention(ctx, id);
  const d = await ctx.db.get(id);
  if (!d || d.automationRevision === undefined) return;
  const existing = await ctx.db.query("deletionOutbox").withIndex("by_request", q => q.eq("request", id)).unique();
  const revision = d.automationRevision + 1;
  const value = { request: id, owner: d.owner, revision, kind: "scope_status" as const,
    state: "intent" as const, delivery: "not_configured" as const, classification: await classification(ctx, d),
    localComplete: d.localComplete, providersComplete: d.localComplete && d.clerk && d.apple && d.revenuecat && d.gemini && d.residuals,
    updatedAt: Date.now() };
  await ctx.db.patch(id, { automationRevision: revision });
  if (existing) await ctx.db.patch(existing._id, value);
  else await ctx.db.insert("deletionOutbox", value);
  if (notificationsEnabled()) await ctx.scheduler.runAfter(0, internal.deletionNotifications.freeze, { id, owner: d.owner });
}
export async function manualStage(ctx: MutationCtx, stage: Doc<"deletionStages">, evidence: string) {
  await ctx.db.patch(stage._id, { state: "manual", fence: stage.fence + 1, leaseUntil: undefined,
    evidence, code: "operator_evidence", updatedAt: Date.now() });
}
export function canDrainFileWork(work: Doc<"deletionWork">) {
  // Older combined ambiguity cannot be reinterpreted from a file DELETE response.
  return work.kind === "gemini" && work.knowledgeVersion === 1 && work.finished && work.fileDeleted === true &&
    work.generationStarted !== undefined && work.generationFinished !== undefined &&
    (!work.generationStarted || work.generationFinished);
}
