import { v } from "convex/values";
import { internalMutation, internalQuery, type MutationCtx, type QueryCtx } from "./_generated/server";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { ownedBatch } from "./batches";
import { buildChatContext, history, room, validQuestion, validReply } from "./batchChatContext";
import { allowOwner, enabled, failBatch, requireEnabled, uuid } from "./batchContract";
import { billableEnabled } from "./billable";
import { byteLength } from "./limits";
import { chatRequest } from "./batchChatSchema";
import { reserveQuota, settleQuota, verifiedAccount } from "./billing";
import { enforcementEnabled } from "./billingPolicy";
import { deletionFor, requireActive } from "./deletionGuard";

type Ctx = QueryCtx | MutationCtx;
export type ChatRequest = { batchId: string; clientMessageId: string; expectedContextDigest: string; expectedHistoryRevision: number; message: string };
export const chatEnabled = () => process.env.BATCH_CHAT_ENABLED === "true" && enabled() && billableEnabled();
function requireChat(owner: string) {
  requireEnabled(); allowOwner(owner);
  if (!chatEnabled()) failBatch(503, "disabled", "Batch chat is disabled.");
}
function conflict(): never { return failBatch(409, "chat_conflict", "Chat state or submitted fields changed. Refresh before continuing."); }
function validateRequest(a: ChatRequest) {
  if (!uuid(a.clientMessageId) || !/^[0-9a-f]{64}$/.test(a.expectedContextDigest) || !Number.isSafeInteger(a.expectedHistoryRevision) || a.expectedHistoryRevision < 0 || !validQuestion(a.message)) failBatch(400, "malformed", "Provide a valid chat identity, revision, digest and nonempty message of at most 8 KiB.");
}
const saved = (ctx: Ctx, parent: Id<"transcriptionBatches">) => ctx.db.query("batchChats").withIndex("by_parent", q => q.eq("parent", parent)).unique();
const existing = (ctx: Ctx, parent: Doc<"transcriptionBatches">, key: string) => ctx.db.query("batchChatOperations")
  .withIndex("by_owner_parent_key", q => q.eq("owner", parent.owner).eq("parent", parent._id).eq("clientMessageId", key)).unique();
function operation(op: Doc<"batchChatOperations">) {
  if (op.deleted || !op.contextDigest) return failBatch(404, "not_found", "Chat operation not found.");
  const dto = { version: 1 as const, batchId: op.parent, clientMessageId: op.clientMessageId, revision: op.revision, contextDigest: op.contextDigest,
    state: op.state, quota: op.quota, text: op.text ?? null, error: op.error ?? null };
  if (byteLength(JSON.stringify(dto)) > 65536) failBatch(502, "wire_limit", "Chat operation exceeds its response limit.");
  return dto;
}
function same(op: Doc<"batchChatOperations">, args: ChatRequest) {
  if (op.message !== args.message || op.contextDigest !== args.expectedContextDigest || op.expectedRevision !== args.expectedHistoryRevision) conflict();
  return operation(op);
}
async function context(ctx: Ctx, p: Doc<"transcriptionBatches">) {
  const rows = await ctx.db.query("transcriptionChunks").withIndex("by_parent", q => q.eq("parent", p._id)).take(25);
  if (!p.sealed) return { availability: "incomplete" as const, contextText: null, contextDigest: null };
  return buildChatContext(p.manifest, p.manifestDigest, rows);
}

export const get = internalQuery({ args: { batchId: v.string() }, handler: async (ctx, { batchId }) => {
  const p = await ownedBatch(ctx, batchId), state = await saved(ctx, p._id), c = await context(ctx, p);
  const pending = state?.pending ? await ctx.db.get(state.pending) : null;
  const availability = pending?.state === "unknown" ? "attention" : pending ? "busy" :
    !chatEnabled() || p.owner !== process.env.BATCH_TRANSCRIPTION_OWNER ? "disabled" : c.availability !== "ready" ? c.availability :
    !room(state?.exchanges ?? [], "") ? "history_full" : "ready";
  const result = { version: 1, batchId: p._id, revision: state?.revision ?? 0, contextDigest: c.contextDigest,
    availability, exchanges: state?.exchanges ?? [], pending: pending ? operation(pending) : null };
  if (byteLength(JSON.stringify(result)) > 256 * 1024) failBatch(502, "wire_limit", "Chat history exceeds its response limit.");
  return result;
} });
export const receipt = internalQuery({ args: { batchId: v.string(), clientMessageId: v.string() }, handler: async (ctx, args) => {
  const p = await ownedBatch(ctx, args.batchId), op = await existing(ctx, p, args.clientMessageId);
  if (!op) return failBatch(404, "not_found", "Chat operation not found.");
  return operation(op);
} });

// Read-only identity resolution precedes billing. Admission repeats all checks in
// the transaction that binds context/history and reserves quota.
export const prepare = internalQuery({ args: chatRequest, handler: async (ctx, args) => {
  validateRequest(args);
  const p = await ownedBatch(ctx, args.batchId), previous = await existing(ctx, p, args.clientMessageId);
  if (previous) return { replay: same(previous, args) };
  requireChat(p.owner);
  const state = await saved(ctx, p._id);
  if ((state?.revision ?? 0) !== args.expectedHistoryRevision) conflict();
  if (state?.pending) failBatch(409, "chat_busy", "A chat operation is unresolved. Refresh it before sending another question.");
  const c = await context(ctx, p);
  if (c.availability !== "ready") failBatch(409, c.availability, "Chat requires a complete, bounded context containing every original segment.");
  if (c.contextDigest !== args.expectedContextDigest) conflict();
  if (!room(state?.exchanges ?? [], args.message)) failBatch(409, "history_full", "Chat history has no room for the complete next exchange.");
  return { replay: null };
} });

function nextRevision(revision: number) {
  if (!Number.isSafeInteger(revision) || revision < 0 || revision >= Number.MAX_SAFE_INTEGER) conflict();
  return revision + 1;
}
export const admit = internalMutation({ args: { ...chatRequest, billingRevision: v.optional(v.number()) }, handler: async (ctx, args) => {
  validateRequest(args);
  const p = await ownedBatch(ctx, args.batchId), previous = await existing(ctx, p, args.clientMessageId);
  if (previous) return same(previous, args);
  requireChat(p.owner);
  let state = await saved(ctx, p._id);
  if ((state?.revision ?? 0) !== args.expectedHistoryRevision) conflict();
  if (state?.pending) failBatch(409, "chat_busy", "A chat operation is unresolved. Refresh it before sending another question.");
  const c = await context(ctx, p);
  if (c.availability !== "ready") return failBatch(409, c.availability, "Chat requires a complete, bounded context containing every original segment.");
  if (c.contextDigest !== args.expectedContextDigest) conflict();
  if (!room(state?.exchanges ?? [], args.message)) failBatch(409, "history_full", "Chat history has no room for the complete next exchange.");
  const reservation = await reserveQuota(ctx, p.owner, args.billingRevision, 0, 1);
  let snapshot = await ctx.db.query("batchChatContexts").withIndex("by_parent_digest", q => q.eq("parent", p._id).eq("digest", c.contextDigest)).unique();
  if (!snapshot) {
    const id = await ctx.db.insert("batchChatContexts", { owner: p.owner, parent: p._id, digest: c.contextDigest, text: c.contextText }); snapshot = (await ctx.db.get(id))!;
  }
  if (snapshot.owner !== p.owner || snapshot.text !== c.contextText) conflict();
  if (!state) { const id = await ctx.db.insert("batchChats", { owner: p.owner, parent: p._id, revision: 0, exchanges: [] }); state = (await ctx.db.get(id))!; }
  const revision = 1;
  const id = await ctx.db.insert("batchChatOperations", { owner: p.owner, parent: p._id, subject: p.subject, clientMessageId: args.clientMessageId,
    expectedRevision: args.expectedHistoryRevision, contextDigest: c.contextDigest, message: args.message, context: snapshot._id, historyText: JSON.stringify(history(state.exchanges)),
    revision, fence: 0, phase: "queued", state: "queued", quota: reservation ? "reserved" : "not_enforced", reservation, due: Date.now() + 120_000, deleted: false });
  await ctx.db.patch(state._id, { pending: id });
  await ctx.scheduler.runAfter(0, internal.batchChatJobs.run, { id });
  return operation((await ctx.db.get(id))!);
} });

type Outcome = "completed" | "failed_before_submission" | "unknown";
const finishArgs = { id: v.id("batchChatOperations"), fence: v.number(), outcome: v.union(v.literal("completed"), v.literal("failed_before_submission"), v.literal("unknown")), text: v.optional(v.string()) };
async function finishOperation(ctx: MutationCtx, op: Doc<"batchChatOperations">, outcome: Outcome, text?: string, beforeCode = "chat_failed") {
  if (op.phase === "terminal") return;
  // Completion is only meaningful for the exact generation intent. A local error
  // after that intent is unknown even if the caller believes submission failed.
  const completed = outcome === "completed" && op.phase === "intent";
  const known = completed || op.phase !== "intent";
  const work = op.work ? await ctx.db.get(op.work) : null;
  if (completed && (!work || !work.generationStarted)) conflict();
  const d = await deletionFor(ctx, op.owner);
  if (op.deleted || d) {
    if (op.reservation) await settleQuota(ctx, op.reservation, false);
    if (known) { if (work) await ctx.db.delete(work._id); await ctx.db.delete(op._id); }
    else await ctx.db.patch(op._id, { deleted: true, reservation: undefined, quota: op.quota === "reserved" ? "released" : op.quota,
      message: undefined, text: undefined, historyText: undefined, context: undefined, contextDigest: undefined, expectedRevision: undefined, state: "unknown" });
    if (d) await ctx.scheduler.runAfter(0, internal.deletion.cleanup, { id: d._id });
    return;
  }
  const state = await saved(ctx, op.parent);
  if (!state || state.pending !== op._id) conflict();
  if (!known) {
    if (op.state === "unknown") return;
    const revision = nextRevision(op.revision);
    await ctx.db.patch(op._id, { revision, state: "unknown", error: { code: "chat_unknown", message: "The remote reply is unresolved. Do not send a replacement question." } });
    if (work) await ctx.db.patch(work._id, { finished: true, ambiguous: true });
    return;
  }
  const valid = completed && validReply(text) && op.historyText === JSON.stringify(history(state.exchanges)) && !!op.message && !!op.contextDigest && room(state.exchanges, op.message);
  if (op.reservation) await settleQuota(ctx, op.reservation, valid);
  const revision = nextRevision(op.revision);
  const exchanges = valid ? [...state.exchanges, { clientMessageId: op.clientMessageId, contextDigest: op.contextDigest!, message: op.message!, reply: text! }] : state.exchanges;
  await ctx.db.patch(state._id, { revision: valid ? nextRevision(state.revision) : state.revision, exchanges, pending: undefined });
  await ctx.db.patch(op._id, { revision, phase: "terminal", state: valid ? "succeeded" : "failed", text: valid ? text : undefined,
    quota: op.quota === "not_enforced" ? "not_enforced" : valid ? "consumed" : "released", reservation: undefined,
    context: undefined, historyText: undefined, work: undefined,
    error: valid ? undefined : { code: completed ? "invalid_reply" : beforeCode, message: completed ? "The completed provider response was not a valid bounded reply. No question allowance was consumed." : "This question was not submitted. No question allowance was consumed; a new explicit question may be sent." } });
  if (work) await ctx.db.delete(work._id);
}
export const finish = internalMutation({ args: finishArgs, handler: async (ctx, args) => {
  const op = await ctx.db.get(args.id);
  if (!op || op.fence !== args.fence) return;
  await finishOperation(ctx, op, args.outcome, args.text);
} });

export const claim = internalMutation({ args: { id: v.id("batchChatOperations") }, handler: async (ctx, { id }) => {
  const op = await ctx.db.get(id);
  if (!op || op.deleted || op.phase !== "queued" || await deletionFor(ctx, op.owner)) return null;
  if (!chatEnabled() || op.owner !== process.env.BATCH_TRANSCRIPTION_OWNER) { await finishOperation(ctx, op, "failed_before_submission", undefined, "disabled"); return null; }
  const snapshot = op.context ? await ctx.db.get(op.context) : null;
  if (!snapshot || snapshot.owner !== op.owner || snapshot.digest !== op.contextDigest || !op.message || op.historyText === undefined) {
    await finishOperation(ctx, op, "failed_before_submission", undefined, "context_unavailable"); return null;
  }
  const fence = nextRevision(op.fence);
  await ctx.db.patch(op._id, { fence, phase: "preparing", due: Date.now() + 120_000 });
  return { id: op._id, fence, owner: op.owner, subject: op.subject, context: snapshot.text, history: op.historyText, question: op.message };
} });
export const intent = internalMutation({ args: { id: v.id("batchChatOperations"), fence: v.number(), billingRevision: v.optional(v.number()) }, handler: async (ctx, args) => {
  const op = await ctx.db.get(args.id);
  if (!op || op.fence !== args.fence || op.phase !== "preparing" || op.deleted) return false;
  await requireActive(ctx, op.owner);
  if (!chatEnabled() || op.owner !== process.env.BATCH_TRANSCRIPTION_OWNER) { await finishOperation(ctx, op, "failed_before_submission", undefined, "disabled"); return false; }
  if (enforcementEnabled() || op.reservation) {
    const account = await verifiedAccount(ctx, op.owner, args.billingRevision);
    const bucket = op.reservation ? await ctx.db.get(op.reservation.bucket) : null;
    if (!bucket || bucket.owner !== op.owner || (bucket.window === "free") !== (account.plan === "free")) {
      await finishOperation(ctx, op, "failed_before_submission", undefined, "billing_changed"); return false;
    }
  }
  const state = await saved(ctx, op.parent);
  if (!state || state.pending !== op._id || op.historyText !== JSON.stringify(history(state.exchanges))) conflict();
  const work = await ctx.db.insert("deletionWork", { owner: op.owner, kind: "chat", startedAt: Date.now(), finished: false, ambiguous: true,
    knowledgeVersion: 1, generationStarted: true, generationFinished: false });
  const revision = nextRevision(op.revision);
  await ctx.db.patch(op._id, { phase: "intent", state: "running", revision, work, due: Date.now() + 90_000 });
  return true;
} });
export const recover = internalMutation({ args: {}, handler: async ctx => {
  for (const state of ["queued", "running"] as const) {
    const rows = await ctx.db.query("batchChatOperations").withIndex("by_state_due", q => q.eq("state", state).lte("due", Date.now())).take(8);
    for (const op of rows) {
      if (op.deleted) continue;
      if (op.phase === "queued" && chatEnabled() && op.owner === process.env.BATCH_TRANSCRIPTION_OWNER) {
        await ctx.db.patch(op._id, { due: Date.now() + 120_000 }); await ctx.scheduler.runAfter(0, internal.batchChatJobs.run, { id: op._id });
      } else await finishOperation(ctx, op, op.phase === "intent" ? "unknown" : "failed_before_submission", undefined, "chat_expired_before_submission");
    }
  }
} });

export const reconcile = internalMutation({ args: { id: v.id("batchChatOperations"), owner: v.string(), fence: v.number(), evidence: v.string(), remoteStopped: v.literal(true) }, handler: async (ctx, args) => {
  const op = await ctx.db.get(args.id);
  if (!op || op.owner !== args.owner || op.fence !== args.fence || !/^[A-Za-z0-9_-]{1,100}$/.test(args.evidence)) conflict();
  if (op.phase === "terminal") return;
  await ctx.db.patch(op._id, { evidence: args.evidence });
  await finishOperation(ctx, op, op.phase === "intent" ? "completed" : "failed_before_submission", undefined, "chat_reconciled");
  if (await ctx.db.get(op._id)) await ctx.db.patch(op._id, { error: { code: "chat_reconciled", message: "The remote operation was reconciled without a saved reply. No question allowance was consumed." } });
} });

export async function reconcileChatWork(ctx: MutationCtx, work: Id<"deletionWork">) {
  const op = await ctx.db.query("batchChatOperations").withIndex("by_work", q => q.eq("work", work)).unique();
  if (!op) return;
  // Existing deletion reconciliation attests exact-target remote termination.
  if (op.reservation) await settleQuota(ctx, op.reservation, false);
  await ctx.db.delete(op._id);
}
export async function deleteChatContent(ctx: MutationCtx, owner: string): Promise<boolean> {
  // Separate content-bearing rows from operational tombstones so an unresolved
  // early receipt never hides later content or forces an unbounded scan.
  const rows = await ctx.db.query("batchChatOperations").withIndex("by_owner_deleted", q => q.eq("owner", owner).eq("deleted", false)).take(8);
  for (const op of rows) {
    if (op.reservation) await settleQuota(ctx, op.reservation, false);
    if (op.phase === "intent" && op.work) {
      await ctx.db.patch(op._id, { deleted: true, state: "unknown", message: undefined, text: undefined, historyText: undefined,
        context: undefined, contextDigest: undefined, expectedRevision: undefined, reservation: undefined,
        quota: op.quota === "reserved" ? "released" : op.quota, error: undefined });
    } else await ctx.db.delete(op._id);
  }
  if (rows.length) return true;
  const states = await ctx.db.query("batchChats").withIndex("by_owner", q => q.eq("owner", owner)).take(8);
  for (const state of states) await ctx.db.delete(state._id);
  if (states.length) return true;
  const contexts = await ctx.db.query("batchChatContexts").withIndex("by_owner", q => q.eq("owner", owner)).take(8);
  for (const c of contexts) await ctx.db.delete(c._id);
  return contexts.length > 0;
}
