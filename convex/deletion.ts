import { v } from "convex/values";
import { internalMutation, internalQuery, type MutationCtx } from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import { internal } from "./_generated/api";
import { deletionFor, requireActive } from "./deletionGuard";
import { fail } from "./limits";
import { settleQuota, type Reservation } from "./billing";
import { automationEnabled, geminiProjectRef } from "./deletionAdapter";
import { manualStage, publishIntent } from "./deletionAutomationState";
import { contactCaptureEnabled } from "./notificationAdapter";
import { deleteBatchContent, reconcileBatchWork } from "./batches";
import { deleteChatContent, reconcileChatWork } from "./batchChat";
import { executionEvidenceResolved } from "./deletionRetention";

async function deleteStoredFile(ctx: MutationCtx, id: Id<"_storage">) {
  if (await ctx.db.system.get("_storage", id)) await ctx.storage.delete(id);
}
async function settleOwnedReservation(ctx: MutationCtx, owner: string, reservation: Reservation | undefined) {
  if (!reservation) return;
  const bucket = await ctx.db.get(reservation.bucket);
  if (bucket && bucket.owner !== owner) fail(409, "Deletion quota ownership needs operator review.");
  // A missing bucket has no remaining reservation to release (e.g. partial legacy cleanup).
  if (bucket) await settleQuota(ctx, reservation, false);
}

export const check = internalQuery({ args: { owner: v.string() }, handler: async (ctx, { owner }) => { await requireActive(ctx, owner); } });

export const status = internalQuery({ args: {}, handler: async ctx => {
  const who = await ctx.auth.getUserIdentity();
  if (!who) fail(401, "Sign in to LessMeet first.");
  const d = await deletionFor(ctx, who.tokenIdentifier);
  return { userId: who.subject, requested: !!d, localComplete: d?.localComplete ?? false,
    // This broad provider/retention status is not the issue #3 acceptance decision.
    // Keep unresolved flags false; a scoped manual receipt does not complete them.
    providersComplete: !!d && d.localComplete && d.clerk && d.revenuecat && d.apple && d.gemini && d.residuals && await executionEvidenceResolved(ctx, d._id),
    requestedAt: d?.requestedAt ?? null,
    googleStatus: d?.googleStatus ?? null };
} });

export const request = internalMutation({ args: {}, handler: async ctx => {
  const who = await ctx.auth.getUserIdentity();
  if (!who) fail(401, "Sign in to LessMeet first.");
  const existing = await deletionFor(ctx, who.tokenIdentifier);
  if (existing) return;
  // Deployment prerequisite: Human-approved ledger retention and fulfillment process.
  if (process.env.ACCOUNT_DELETION_ENABLED !== "true") fail(503, "Account deletion is not enabled on this deployment. Contact the app owner.");
  const id = await ctx.db.insert("deletions", { owner: who.tokenIdentifier, subject: who.subject,
    requestedAt: Date.now(), updatedAt: Date.now(), localComplete: false,
    googleRequired: true, googleStatus: "pending",
    clerk: false, revenuecat: false, apple: false, gemini: false, residuals: false });
  await ctx.scheduler.runAfter(0, internal.deletion.cleanup, { id });
  if (contactCaptureEnabled()) await ctx.scheduler.runAfter(0, internal.deletionNotifications.captureContact, { id, owner: who.tokenIdentifier });
} });

// A durable admission precedes any nontransactional storage/provider side effect.
// An interrupted action stays unresolved; never guess success after a deadline.
export const beginWork = internalMutation({ args: { owner: v.string(), kind: v.union(v.literal("upload"), v.literal("gemini"), v.literal("chat"), v.literal("billing")) },
  handler: async (ctx, { owner, kind }) => {
    await requireActive(ctx, owner);
    return ctx.db.insert("deletionWork", { owner, kind, startedAt: Date.now(), finished: false, ambiguous: true,
      ...(["gemini", "chat"].includes(kind) ? { knowledgeVersion: 1 as const, generationStarted: false, generationFinished: false } : {}),
      ...(kind === "gemini" && geminiProjectRef() ? { providerConfig: geminiProjectRef() } : {}) });
  } });
// This is an intent-before-call marker, not proof that Google accepted a request.
export const generation = internalMutation({ args: { id: v.id("deletionWork"), phase: v.union(v.literal("started"), v.literal("finished")) },
  handler: async (ctx, { id, phase }) => {
    const w = await ctx.db.get(id);
    if (!w || w.finished || w.knowledgeVersion !== 1 || !["gemini", "chat"].includes(w.kind)) fail(409, "Generation work is no longer active.");
    if (phase === "started" && w.generationFinished) fail(409, "Generation work cannot be reused.");
    if (phase === "finished" && !w.generationStarted) fail(409, "Generation was not started.");
    await ctx.db.patch(id, phase === "started" ? { generationStarted: true } : { generationFinished: true });
  } });
export const track = internalMutation({ args: { id: v.id("deletionWork"), audio: v.optional(v.id("_storage")), file: v.optional(v.string()) },
  handler: async (ctx, { id, audio, file }) => {
    const work = await ctx.db.get(id);
    if (!work || work.finished) fail(409, "Cloud operation is no longer active.");
    if (file && !/^files\/[a-zA-Z0-9_-]+$/.test(file)) fail(400, "Invalid provider resource.");
    if ((work.audio && audio && work.audio !== audio) || (work.file && file && work.file !== file)) fail(409, "Cloud resource mismatch.");
    await ctx.db.patch(id, { ...(audio ? { audio } : {}), ...(file ? { file, fileDeleted: false } : {}) });
  } });
export const finishWork = internalMutation({ args: { id: v.id("deletionWork"), ambiguous: v.boolean(), fileDeleted: v.optional(v.boolean()) },
  handler: async (ctx, { id, ambiguous, fileDeleted }) => {
    const work = await ctx.db.get(id);
    if (!work || work.finished) return;
    // Fully cleaned successful work needs no permanent per-request ledger.
    if (!ambiguous && (!work.file || fileDeleted)) await ctx.db.delete(id);
    else await ctx.db.patch(id, { finished: true, ambiguous, ...(fileDeleted === undefined ? {} : { fileDeleted }) });
    const d = await deletionFor(ctx, work.owner);
    if (d) await ctx.scheduler.runAfter(0, internal.deletion.cleanup, { id: d._id });
  } });

export const discardUpload = internalMutation({ args: { id: v.id("deletionWork"), audio: v.id("_storage") },
  handler: async (ctx, { id, audio }) => {
    const who = await ctx.auth.getUserIdentity(), work = await ctx.db.get(id);
    if (!who || !work || work.owner !== who.tokenIdentifier || work.kind !== "upload" || (work.audio && work.audio !== audio)) {
      fail(403, "Upload cleanup target mismatch.");
    }
    await deleteStoredFile(ctx, audio);
    await ctx.db.delete(id);
    const d = await deletionFor(ctx, work.owner);
    if (d) await ctx.scheduler.runAfter(0, internal.deletion.cleanup, { id: d._id });
  } });

// Bounded transactional batches. Blob deletion and row deletion commit together.
export const cleanup = internalMutation({ args: { id: v.id("deletions") }, handler: async (ctx, { id }) => {
  const d = await ctx.db.get(id);
  if (!d) fail(404, "Deletion request not found.");
  await ctx.db.patch(id, { localComplete: false, updatedAt: Date.now() });
  await publishIntent(ctx, id);
  const rows = await ctx.db.query("recordings").withIndex("by_owner", q => q.eq("owner", d.owner)).take(8);
  for (const r of rows) {
    await settleOwnedReservation(ctx, d.owner, r.transcriptionReservation);
    await settleOwnedReservation(ctx, d.owner, r.chatReservation);
    await deleteStoredFile(ctx, r.audio);
    await ctx.db.delete(r._id);
  }
  if (rows.length) { await ctx.scheduler.runAfter(0, internal.deletion.cleanup, { id }); return; }
  if (await deleteChatContent(ctx, d.owner)) { await ctx.scheduler.runAfter(0, internal.deletion.cleanup, { id }); return; }
  if (await deleteBatchContent(ctx, d.owner)) { await ctx.scheduler.runAfter(0, internal.deletion.cleanup, { id }); return; }
  const buckets = await ctx.db.query("quotaBuckets").withIndex("by_owner_window", q => q.eq("owner", d.owner)).take(32);
  for (const b of buckets) await ctx.db.delete(b._id);
  if (buckets.length) { await ctx.scheduler.runAfter(0, internal.deletion.cleanup, { id }); return; }
  const accounts = await ctx.db.query("billingAccounts").withIndex("by_owner", q => q.eq("owner", d.owner)).take(8);
  for (const a of accounts) await ctx.db.delete(a._id);
  if (accounts.length) { await ctx.scheduler.runAfter(0, internal.deletion.cleanup, { id }); return; }
  // Unresolved actions (including lost storage/provider responses) require an operator.
  const work = await ctx.db.query("deletionWork").withIndex("by_owner", q => q.eq("owner", d.owner)).first();
  await ctx.db.patch(id, { localComplete: !work, updatedAt: Date.now() });
  await publishIntent(ctx, id);
  if (automationEnabled()) await ctx.scheduler.runAfter(0, internal.deletionAutomation.start, { id, owner: d.owner });
} });

// Internal-only operator inputs require BOTH exact request ID and issuer-bound owner.
export const inventory = internalQuery({ args: { id: v.id("deletions"), owner: v.string(), cursor: v.union(v.string(), v.null()) },
  handler: async (ctx, { id, owner, cursor }) => {
    const d = await ctx.db.get(id);
    if (!d || d.owner !== owner) fail(404, "Exact deletion target not found.");
    return { request: d, work: await ctx.db.query("deletionWork").withIndex("by_owner", q => q.eq("owner", owner)).paginate({ cursor, numItems: 32 }) };
  } });
export const retry = internalMutation({ args: { id: v.id("deletions"), owner: v.string() }, handler: async (ctx, { id, owner }) => {
  const d = await ctx.db.get(id);
  if (!d || d.owner !== owner) fail(404, "Exact deletion target not found.");
  await ctx.scheduler.runAfter(0, internal.deletion.cleanup, { id });
} });
export const confirm = internalMutation({ args: { id: v.id("deletions"), owner: v.string(),
  stage: v.union(v.literal("clerk"), v.literal("revenuecat"), v.literal("apple"), v.literal("gemini"), v.literal("residuals")),
  complete: v.boolean(), evidence: v.string(), automationRevision: v.optional(v.number()) }, handler: async (ctx, { id, owner, stage, complete, evidence, automationRevision }) => {
    const d = await ctx.db.get(id);
    if (!d || d.owner !== owner) fail(404, "Exact deletion target not found.");
    if (d.automationRevision !== undefined && d.automationRevision !== automationRevision) fail(409, "Automation revision changed; inspect the exact request again.");
    if (!/^[A-Za-z0-9_-]{1,100}$/.test(evidence)) fail(400, "Use a private case-reference identifier, not personal data.");
    if (complete && !d.localComplete) fail(409, "Resolve local cleanup and outstanding operations first.");
    if (complete && stage === "clerk") {
      const execution = await ctx.db.query("deletionClerkExecutions").withIndex("by_request", q => q.eq("request", id)).unique();
      if (execution && execution.state !== "manual") fail(409, "Use exact Clerk execution reconciliation first.");
    }
    if (complete && (stage === "apple" || stage === "revenuecat")) {
      const execution = await ctx.db.query("deletionProviderExecutions").withIndex("by_request_provider", q => q.eq("request", id).eq("provider", stage)).unique();
      if (execution && execution.state !== "manual") fail(409, "Use exact provider execution reconciliation first.");
    }
    await ctx.db.patch(id, { [stage]: complete, [`${stage}Evidence`]: evidence, updatedAt: Date.now() });
    const automatic = await ctx.db.query("deletionStages").withIndex("by_request_key", q => q.eq("request", id).eq("key", stage)).unique();
    if (automatic) await manualStage(ctx, automatic, evidence);
    await publishIntent(ctx, id);
} });
export const reconcileWork = internalMutation({ args: { id: v.id("deletions"), owner: v.string(), workId: v.id("deletionWork"), evidence: v.string(), automationRevision: v.optional(v.number()) },
  handler: async (ctx, { id, owner, workId, evidence, automationRevision }) => {
    const d = await ctx.db.get(id), work = await ctx.db.get(workId);
    if (!d || d.owner !== owner || (work && work.owner !== owner)) fail(404, "Exact deletion target not found.");
    if (d.automationRevision !== undefined && d.automationRevision !== automationRevision) fail(409, "Automation revision changed; inspect the exact request again.");
    if (!work) return; // Repeating verified reconciliation is harmless.
    if (!/^[A-Za-z0-9_-]{1,100}$/.test(evidence)) fail(400, "Use a private case-reference identifier.");
    // Operator attests the action has stopped AND provider/unknown side effects reconciled.
    if (work.audio) await deleteStoredFile(ctx, work.audio);
    await reconcileBatchWork(ctx, workId);
    await reconcileChatWork(ctx, workId);
    const automatic = await ctx.db.query("deletionStages").withIndex("by_work", q => q.eq("work", workId)).unique();
    if (automatic) await manualStage(ctx, automatic, evidence);
    await ctx.db.delete(workId);
    await ctx.db.patch(id, { evidence, updatedAt: Date.now() });
    await publishIntent(ctx, id);
    await ctx.scheduler.runAfter(0, internal.deletion.cleanup, { id });
  } });
