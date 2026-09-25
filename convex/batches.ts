import { v } from "convex/values";
import { internalMutation, internalQuery, type MutationCtx, type QueryCtx } from "./_generated/server";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { allowOwner, requireEnabled, enabled, manifest, geometry, aggregate, failBatch, validateResult } from "./batchContract";
import { manifestValue } from "./batchSchema";
import { deletionFor, requireActive } from "./deletionGuard";
import { reserveQuota, settleQuota, verifiedAccount } from "./billing";
import { enforcementEnabled } from "./billingPolicy";
import { billableEnabled } from "./billable";
import { geminiProjectRef } from "./deletionAdapter";

const conflict = () => failBatch(409, "conflict", "Batch state changed. Refresh before continuing.");
type Ctx = QueryCtx | MutationCtx;
async function owner(ctx: Ctx, mutate = false) {
  const who = await ctx.auth.getUserIdentity();
  if (!who) return failBatch(401, "auth", "Sign in to LessMeet first.");
  if (mutate) { requireEnabled(); allowOwner(who.tokenIdentifier); }
  await requireActive(ctx, who.tokenIdentifier);
  return who;
}
export async function ownedBatch(ctx: Ctx, raw: string, mutate = false) {
  const who = await owner(ctx, mutate), id = ctx.db.normalizeId("transcriptionBatches", raw), parent = id ? await ctx.db.get(id) : null;
  if (!parent || parent.owner !== who.tokenIdentifier) return failBatch(404, "not_found", "Batch not found.");
  return parent;
}
const chunks = (ctx: Ctx, parent: Id<"transcriptionBatches">) => ctx.db.query("transcriptionChunks").withIndex("by_parent", q => q.eq("parent", parent)).take(25);
async function slot(ctx: Ctx, parent: Id<"transcriptionBatches">, index: number) {
  const c = (await chunks(ctx, parent)).find(c => c.index === index);
  if (!c) return failBatch(404, "not_found", "Chunk not found.");
  return c;
}
async function inventory(ctx: MutationCtx) {
  let row = await ctx.db.query("transcriptionInventory").withIndex("by_key", q => q.eq("key", "batch")).unique();
  if (!row) { const id = await ctx.db.insert("transcriptionInventory", { key: "batch", jobs: [], dispatchFence: 0, dispatchUntil: 0 }); row = (await ctx.db.get(id))!; }
  return row;
}
async function bump(ctx: MutationCtx, id: Id<"transcriptionBatches">) {
  const p = await ctx.db.get(id); if (p) await ctx.db.patch(id, { revision: p.revision + 1 });
}
async function summary(ctx: Ctx, p: Doc<"transcriptionBatches">) {
  const rows = (await chunks(ctx, p._id)).sort((a, b) => a.index - b.index);
  const active = rows.some(c => ["queued", "running"].includes(c.state));
  const unknown = rows.some(c => ["unknown", "admitting"].includes(c.state));
  const success = rows.filter(c => c.state === "succeeded").length;
  const merged = success ? aggregate(p.manifest, rows.map(c => c.rawText ?? null)) : null;
  const aggState = merged?.status ?? "pending";
  const attempts = await Promise.all(rows.map(c => ctx.db.query("transcriptionAttempts").withIndex("by_chunk", q => q.eq("chunk", c._id)).take(2)));
  const cleanupPending = attempts.flat().some(a => a.work !== undefined && (!a.fileDeleted || !a.terminal)) || rows.some(c => c.uploadWork !== undefined);
  // No provider identifiers or raw results in the summary DTO.
  return { version: 1 as const, batchId: p._id, clientBatchId: p.clientBatchId, manifestDigest: p.manifestDigest, revision: p.revision,
    state: !p.sealed ? (unknown ? "attention" : "uploading") : unknown ? "attention" : active ? (rows.some(c => c.state === "running") ? "processing" : "queued") : success === rows.length ? "complete" : success ? "partial" : "failed",
    quotaSeconds: Number((BigInt(p.manifest.source.duration.value) + BigInt(p.manifest.source.duration.timescale) - 1n) / BigInt(p.manifest.source.duration.timescale)),
    chunks: rows.map(c => ({ index: c.index, state: c.state, attempt: c.attempt, fence: c.fence,
      retryAllowed: c.state === "failed" && c.attempt === 1 && enabled() && billableEnabled() && p.owner === process.env.BATCH_TRANSCRIPTION_OWNER && !attempts[c.index]?.some(a => !a.terminal || (a.work && !a.fileDeleted)),
      resultAvailable: c.rawText !== undefined, error: c.error ?? null })),
    aggregate: { state: aggState, available: merged !== null && merged.status !== "too_large" }, cleanupPending };
}

export const get = internalQuery({ args: { batchId: v.optional(v.string()), clientBatchId: v.optional(v.string()) }, handler: async (ctx, args) => {
  const who = await owner(ctx);
  const p = args.batchId ? await ownedBatch(ctx, args.batchId) : await ctx.db.query("transcriptionBatches").withIndex("by_owner_key", q => q.eq("owner", who.tokenIdentifier).eq("clientBatchId", args.clientBatchId!)).unique();
  if (!p) return failBatch(404, "not_found", "Batch not found.");
  return summary(ctx, p);
} });
export const admission = internalQuery({ args: { batchId: v.string(), index: v.number() }, handler: async (ctx, { batchId, index }) => {
  const p = await ownedBatch(ctx, batchId, true), c = await slot(ctx, p._id, index);
  return { manifest: p.manifest, state: c.state, sealed: p.sealed };
} });
export const create = internalMutation({ args: { clientBatchId: v.string(), manifest: manifestValue, manifestDigest: v.string() }, handler: async (ctx, args) => {
  const who = await owner(ctx, true), m = manifest(args.manifest);
  const previous = await ctx.db.query("transcriptionBatches").withIndex("by_owner_key", q => q.eq("owner", who.tokenIdentifier).eq("clientBatchId", args.clientBatchId)).unique();
  if (previous) { if (previous.manifestDigest !== args.manifestDigest) conflict(); return { id: previous._id, created: false }; }
  const id = await ctx.db.insert("transcriptionBatches", { owner: who.tokenIdentifier, issuer: who.issuer, subject: who.subject,
    clientBatchId: args.clientBatchId, manifest: m, manifestDigest: args.manifestDigest, revision: 1, sealed: false, createdAt: Date.now() });
  for (const c of geometry(m.source.duration)) await ctx.db.insert("transcriptionChunks", { parent: id, owner: who.tokenIdentifier, index: c.index, state: "missing", attempt: 0, fence: 0, quota: c.quota });
  return { id, created: true };
} });
export const beginUpload = internalMutation({ args: { batchId: v.string(), index: v.number() }, handler: async (ctx, args) => {
  const p = await ownedBatch(ctx, args.batchId, true), c = await slot(ctx, p._id, args.index);
  if (c.audio || c.state === "admitting") return { work: null, fence: c.fence, unresolved: !c.audio };
  if (p.sealed || c.state !== "missing") return conflict();
  const work = await ctx.db.insert("deletionWork", { owner: p.owner, kind: "upload", startedAt: Date.now(), finished: false, ambiguous: true });
  await ctx.db.patch(c._id, { state: "admitting", fence: c.fence + 1, uploadWork: work }); await bump(ctx, p._id);
  return { work, fence: c.fence + 1, unresolved: false };
} });
export const finishUpload = internalMutation({ args: { batchId: v.string(), index: v.number(), fence: v.number(), work: v.id("deletionWork"), audio: v.id("_storage"), metadata: v.string() }, handler: async (ctx, args) => {
  const who = await ctx.auth.getUserIdentity(), work = await ctx.db.get(args.work);
  if (!who || !work || work.owner !== who.tokenIdentifier || work.kind !== "upload") return conflict();
  await ctx.db.patch(work._id, { audio: args.audio }); // preserve late storage evidence even after deletion
  const id = ctx.db.normalizeId("transcriptionBatches", args.batchId), p = id ? await ctx.db.get(id) : null;
  const c = p && p.owner === who.tokenIdentifier ? await slot(ctx, p._id, args.index) : null;
  if (!p || !c || c.fence !== args.fence || c.uploadWork !== args.work || await deletionFor(ctx, who.tokenIdentifier)) {
    await ctx.storage.delete(args.audio); await ctx.db.delete(work._id);
    const d = await deletionFor(ctx, who.tokenIdentifier); if (d) await ctx.scheduler.runAfter(0, internal.deletion.cleanup, { id: d._id });
    return false;
  }
  await ctx.db.patch(c._id, { audio: args.audio, metadata: args.metadata, state: "uploaded", uploadWork: undefined, error: undefined });
  await ctx.db.delete(work._id); await bump(ctx, p._id); return true;
} });

export const seal = internalMutation({ args: { batchId: v.string(), manifestDigest: v.string(), revision: v.optional(v.number()) }, handler: async (ctx, args) => {
  const p = await ownedBatch(ctx, args.batchId, true);
  if (p.manifestDigest !== args.manifestDigest) return conflict();
  if (p.sealed) return;
  const rows = await chunks(ctx, p._id);
  if (rows.some(c => c.state !== "uploaded" || !c.audio)) return conflict();
  if (!billableEnabled()) return failBatch(503, "disabled", "Cloud generation is paused.");
  // A single transaction reserves all canonical intervals; no partial seal.
  for (const c of rows) {
    const reservation = c.quota ? await reserveQuota(ctx, p.owner, args.revision, c.quota, 0) : undefined;
    await ctx.db.insert("transcriptionAttempts", { parent: p._id, chunk: c._id, owner: p.owner, attempt: 1, fence: c.fence + 1, requestId: p.clientBatchId,
      phase: "queued", due: Date.now(), settled: false, terminal: false, generationFinished: false, fileDeleted: false, reservation });
    await ctx.db.patch(c._id, { state: "queued", attempt: 1, fence: c.fence + 1 });
  }
  await ctx.db.patch(p._id, { sealed: true, revision: p.revision + 1 });
  await ctx.scheduler.runAfter(0, internal.batchJobs.dispatch, {});
} });
export const controlAdmission = internalQuery({ args: { batchId: v.string(), manifestDigest: v.optional(v.string()), index: v.optional(v.number()), expectedFence: v.optional(v.number()), requestId: v.optional(v.string()) }, handler: async (ctx, args) => {
  const p = await ownedBatch(ctx, args.batchId, true);
  if (args.manifestDigest !== undefined) {
    if (p.manifestDigest !== args.manifestDigest) return conflict();
    if (p.sealed) return false;
    if ((await chunks(ctx, p._id)).some(c => c.state !== "uploaded" || !c.audio)) return conflict();
  } else {
    const c = await slot(ctx, p._id, args.index!);
    const attempts = await ctx.db.query("transcriptionAttempts").withIndex("by_chunk", q => q.eq("chunk", c._id)).take(2);
    const replay = attempts.find(a => a.attempt === 2 && a.requestId === args.requestId);
    if (replay) { if (replay.fence !== args.expectedFence! + 1) return conflict(); return false; }
    if (c.state !== "failed" || c.attempt !== 1 || c.fence !== args.expectedFence || attempts.some(a => !a.terminal || (a.work && !a.fileDeleted))) return conflict();
  }
  if (!billableEnabled()) return failBatch(503, "disabled", "Cloud generation is paused.");
  return true;
} });
export const beginControlBilling = internalMutation({ args: {}, handler: async ctx => {
  await owner(ctx, true);
  const inv = await inventory(ctx);
  if (inv.dispatchUntil > Date.now()) return failBatch(409, "verification_busy", "Billing verification is in progress. Refresh and try again.");
  await ctx.db.patch(inv._id, { dispatchFence: inv.dispatchFence + 1, dispatchUntil: Date.now() + 60_000 });
  return inv.dispatchFence + 1;
} });
export const retry = internalMutation({ args: { batchId: v.string(), index: v.number(), expectedAttempt: v.number(), expectedFence: v.number(), requestId: v.string(), revision: v.optional(v.number()) }, handler: async (ctx, args) => {
  const p = await ownedBatch(ctx, args.batchId, true), c = await slot(ctx, p._id, args.index);
  const attempts = await ctx.db.query("transcriptionAttempts").withIndex("by_chunk", q => q.eq("chunk", c._id)).take(2);
  const replay = attempts.find(a => a.requestId === args.requestId && a.attempt === 2);
  if (replay) { if (args.expectedAttempt !== 1 || replay.fence !== args.expectedFence + 1) conflict(); return; }
  if (!billableEnabled()) return failBatch(503, "disabled", "Cloud generation is paused.");
  if (c.state !== "failed" || c.attempt !== 1 || args.expectedAttempt !== 1 || c.fence !== args.expectedFence || attempts.some(a => !a.terminal || (a.work && !a.fileDeleted))) return conflict();
  const reservation = c.quota ? await reserveQuota(ctx, p.owner, args.revision, c.quota, 0) : undefined;
  await ctx.db.insert("transcriptionAttempts", { parent: p._id, chunk: c._id, owner: p.owner, attempt: 2, fence: c.fence + 1, requestId: args.requestId,
    phase: "queued", due: Date.now(), settled: false, terminal: false, generationFinished: false, fileDeleted: false, reservation });
  await ctx.db.patch(c._id, { state: "queued", attempt: 2, fence: c.fence + 1, error: undefined }); await bump(ctx, p._id);
  await ctx.scheduler.runAfter(0, internal.batchJobs.dispatch, {});
} });
export const result = internalQuery({ args: { batchId: v.string(), index: v.number(), attempt: v.number() }, handler: async (ctx, args) => {
  const p = await ownedBatch(ctx, args.batchId), c = await slot(ctx, p._id, args.index);
  if (c.rawText === undefined || c.attempt !== args.attempt) return conflict();
  return { version: 1, batchId: p._id, index: c.index, attempt: c.attempt, rawText: c.rawText };
} });
export const merged = internalQuery({ args: { batchId: v.string() }, handler: async (ctx, args) => {
  const p = await ownedBatch(ctx, args.batchId), rows = (await chunks(ctx, p._id)).sort((a, b) => a.index - b.index);
  const merged = rows.some(c => c.rawText !== undefined) ? aggregate(p.manifest, rows.map(c => c.rawText ?? null)) : null;
  return { version: 1, batchId: p._id, revision: p.revision, status: merged?.status ?? "pending", missingChunks: merged?.missingChunks ?? rows.map(c => c.index), aggregate: merged?.aggregate ?? null };
} });

export const beginDispatch = internalMutation({ args: {}, handler: async ctx => {
  if (!enabled() || !billableEnabled()) return null;
  const inv = await inventory(ctx);
  if (inv.dispatchUntil > Date.now()) return null;
  const allowed = process.env.BATCH_TRANSCRIPTION_OWNER;
  if (!allowed) return null;
  const c = await ctx.db.query("transcriptionChunks").withIndex("by_owner_state", q => q.eq("owner", allowed).eq("state", "queued")).first();
  if (!c || await deletionFor(ctx, c.owner)) return null;
  const p = await ctx.db.get(c.parent); if (!p) return null;
  await ctx.db.patch(inv._id, { dispatchFence: inv.dispatchFence + 1, dispatchUntil: Date.now() + 60_000 });
  return { owner: p.owner, subject: p.subject, fence: inv.dispatchFence + 1 };
} });
export const endDispatch = internalMutation({ args: { fence: v.number(), drained: v.optional(v.boolean()) }, handler: async (ctx, { fence, drained }) => {
  const inv = await inventory(ctx);
  if (inv.dispatchFence === fence) {
    await ctx.db.patch(inv._id, { dispatchUntil: 0 });
    // The next bounded page starts only after the verification lease is released.
    // A drain removes queued rows; it never reserves or retries the failed work.
    if (drained && enabled() && billableEnabled()) await ctx.scheduler.runAfter(0, internal.batchJobs.dispatch, {});
  }
} });
export const claim = internalMutation({ args: { owner: v.string(), dispatchFence: v.number(), revision: v.optional(v.number()) }, handler: async (ctx, args) => {
  requireEnabled(); allowOwner(args.owner); await requireActive(ctx, args.owner);
  if (!billableEnabled()) return null;
  const inv = await inventory(ctx);
  if (inv.dispatchFence !== args.dispatchFence || inv.dispatchUntil <= Date.now()) return null;
  const a = enforcementEnabled() ? await verifiedAccount(ctx, args.owner, args.revision) : null;
  const rows = await ctx.db.query("transcriptionChunks").withIndex("by_owner_state", q => q.eq("owner", args.owner).eq("state", "queued")).take(25);
  const ids: Id<"transcriptionAttempts">[] = [];
  let drained = false;
  for (const c of rows) {
    const attempts = await ctx.db.query("transcriptionAttempts").withIndex("by_chunk", q => q.eq("chunk", c._id)).take(2);
    const attempt = attempts.find(a => a.attempt === c.attempt && a.fence === c.fence && a.phase === "queued" && !a.work && !a.terminal && !a.settled); if (!attempt) continue;
    if (a && c.quota) {
      const b = attempt.reservation ? await ctx.db.get(attempt.reservation.bucket) : null;
      if (b && b.owner !== args.owner) return conflict();
      if (!b || (b.window === "free") !== (a.plan === "free")) {
        // Only never-submitted queued work is eligible for this terminal transition.
        // Reservation consumption and failure commit together; retries cannot refund twice.
        if (b) await settleQuota(ctx, attempt.reservation, false);
        await ctx.db.patch(attempt._id, { phase: "failed", terminal: true, settled: true, reservation: undefined, fileDeleted: true });
        await ctx.db.patch(c._id, { state: "failed", error: { code: "billing_changed", message: "Your billing plan changed before this chunk was submitted. Its previous reservation was released. " +
          (attempt.attempt === 1 ? "Retry explicitly using your current allowance." : "No retries remain for this chunk.") } });
        await bump(ctx, c.parent); drained = true; continue;
      }
    }
    if (ids.length >= 2 - inv.jobs.length) continue;
    const work = await ctx.db.insert("deletionWork", { owner: c.owner, kind: "gemini", startedAt: Date.now(), finished: false, ambiguous: true,
      knowledgeVersion: 1, generationStarted: false, generationFinished: false, ...(geminiProjectRef() ? { providerConfig: geminiProjectRef() } : {}) });
    await ctx.db.patch(attempt._id, { phase: "claimed", due: Date.now() + 240_000, work });
    await ctx.db.patch(c._id, { state: "running" }); await bump(ctx, c.parent);
    ids.push(attempt._id);
    await ctx.scheduler.runAfter(0, internal.batchJobs.run, { id: attempt._id, fence: attempt.fence });
  }
  await ctx.db.patch(inv._id, { jobs: [...inv.jobs, ...ids] }); return { ids, drained };
} });
export const job = internalMutation({ args: { id: v.id("transcriptionAttempts"), fence: v.number() }, handler: async (ctx, { id, fence }) => {
  const a = await ctx.db.get(id); if (!a || a.fence !== fence || a.terminal || a.phase !== "claimed") return null;
  const c = await ctx.db.get(a.chunk), p = await ctx.db.get(a.parent);
  if (!c || !p || !c.audio || await deletionFor(ctx, a.owner)) return null;
  await ctx.db.patch(a._id, { phase: "preparing" }); // one executor, before any action-local failure can settle
  return { ...a, audio: c.audio, duration: geometry(p.manifest.source.duration)[c.index] };
} });
export const phase = internalMutation({ args: { id: v.id("transcriptionAttempts"), fence: v.number(), phase: v.union(v.literal("uploading"), v.literal("generating"), v.literal("finished")) }, handler: async (ctx, args) => {
  const a = await ctx.db.get(args.id);
  if (!a || a.fence !== args.fence || a.terminal || !a.work) return conflict();
  if (args.phase !== "finished") { requireEnabled(); allowOwner(a.owner); await requireActive(ctx, a.owner); if (!billableEnabled()) return conflict(); }
  const expected = { uploading: "preparing", generating: "uploading", finished: "generating" }[args.phase];
  if (a.phase !== expected) return conflict();
  if (args.phase !== "uploading") {
    const w = await ctx.db.get(a.work); if (!w) return conflict();
    await ctx.db.patch(w._id, args.phase === "generating" ? { generationStarted: true } : { generationFinished: true });
  }
  await ctx.db.patch(a._id, { phase: args.phase, generationFinished: args.phase === "finished" });
} });
export const finish = internalMutation({ args: { id: v.id("transcriptionAttempts"), fence: v.number(), rawText: v.optional(v.string()), known: v.boolean(), fileDeleted: v.boolean() }, handler: async (ctx, args) => {
  const a = await ctx.db.get(args.id); if (!a || a.fence !== args.fence || a.terminal) return;
  const c = await ctx.db.get(a.chunk), p = await ctx.db.get(a.parent), deleting = !!await deletionFor(ctx, a.owner);
  let valid = args.rawText !== undefined && a.generationFinished && !!p;
  if (valid && p && c) { try { validateResult(args.rawText!, geometry(p.manifest.source.duration)[c.index]); } catch { valid = false; } }
  const known = a.generationFinished || (args.known && !["generating", "unknown"].includes(a.phase));
  if (known && !a.settled) await settleQuota(ctx, a.reservation, valid && !deleting);
  await ctx.db.patch(a._id, { phase: known ? (valid ? "succeeded" : "failed") : "unknown", terminal: known, settled: a.settled || known, reservation: known ? undefined : a.reservation, fileDeleted: args.fileDeleted });
  if (c && p && !deleting && c.fence === args.fence && c.attempt === a.attempt) {
    await ctx.db.patch(c._id, { state: known ? (valid ? "succeeded" : "failed") : "unknown", rawText: valid ? args.rawText : undefined,
      error: valid ? undefined : { code: known ? "failed" : "unknown", message: known ? "This chunk did not produce a valid complete result." : "Remote outcome is unknown. Do not resubmit this chunk." } });
    await bump(ctx, p._id);
  }
  if (known) { const inv = await inventory(ctx); await ctx.db.patch(inv._id, { jobs: inv.jobs.filter(id => id !== a._id) }); }
  if (a.work) {
    const work = await ctx.db.get(a.work);
    if (work) {
      if (known && args.fileDeleted) { await ctx.db.delete(work._id); await ctx.db.patch(a._id, { work: undefined }); }
      else await ctx.db.patch(work._id, { finished: true, ambiguous: true, fileDeleted: args.fileDeleted });
    }
  }
  const d = await deletionFor(ctx, a.owner); if (d) await ctx.scheduler.runAfter(0, internal.deletion.cleanup, { id: d._id });
  if (known) await ctx.scheduler.runAfter(0, internal.batchJobs.dispatch, {});
} });
export const recover = internalMutation({ args: {}, handler: async ctx => {
  const inv = await ctx.db.query("transcriptionInventory").withIndex("by_key", q => q.eq("key", "batch")).unique();
  if (!inv) return;
  for (const id of inv.jobs) {
    const a = await ctx.db.get(id); if (!a || a.terminal || a.due > Date.now()) continue;
    // Expiration is observation only; no slot release or paid retry.
    const c = await ctx.db.get(a.chunk);
    if (c && !await deletionFor(ctx, a.owner)) await ctx.db.patch(c._id, { state: "unknown", error: { code: "unknown", message: "Work stopped responding. Refresh or contact the app owner; do not resubmit." } });
    await bump(ctx, a.parent);
  }
  if (enabled() && billableEnabled()) await ctx.scheduler.runAfter(0, internal.batchJobs.dispatch, {});
} });

// Internal exact-target operator attestation. No HTTP retry can manufacture this
// evidence; timeouts and file absence alone are never sufficient.
export const reconcile = internalMutation({ args: { id: v.id("transcriptionAttempts"), owner: v.string(), fence: v.number(), evidence: v.string(),
  remoteStopped: v.literal(true), filesReconciled: v.literal(true) }, handler: async (ctx, args) => {
  const a = await ctx.db.get(args.id);
  if (!a || a.owner !== args.owner || a.fence !== args.fence || !/^[A-Za-z0-9_-]{1,100}$/.test(args.evidence)) return conflict();
  if (a.terminal && !a.work) return;
  if (!a.settled) await settleQuota(ctx, a.reservation, false);
  const inv = await inventory(ctx); await ctx.db.patch(inv._id, { jobs: inv.jobs.filter(id => id !== a._id) });
  if (a.work) await ctx.db.delete(a.work);
  await ctx.db.patch(a._id, { terminal: true, settled: true, reservation: undefined, phase: a.phase === "succeeded" ? "succeeded" : "failed", fileDeleted: true, work: undefined, evidence: args.evidence });
  const c = await ctx.db.get(a.chunk);
  if (c && !await deletionFor(ctx, a.owner) && c.fence === a.fence && c.state !== "succeeded") {
    await ctx.db.patch(c._id, { state: "failed", error: { code: "reconciled_failure", message: "The unresolved operation was reconciled without a usable result." } }); await bump(ctx, a.parent);
  }
  const d = await deletionFor(ctx, a.owner); if (d) await ctx.scheduler.runAfter(0, internal.deletion.cleanup, { id: d._id });
  if (enabled() && billableEnabled()) await ctx.scheduler.runAfter(0, internal.batchJobs.dispatch, {});
} });
export const reconcileAdmission = internalMutation({ args: { batchId: v.id("transcriptionBatches"), index: v.number(), owner: v.string(), fence: v.number(), work: v.id("deletionWork"),
  evidence: v.string(), storageReconciled: v.literal(true), actionStopped: v.literal(true) }, handler: async (ctx, args) => {
  const p = await ctx.db.get(args.batchId), w = await ctx.db.get(args.work);
  if (!p || p.owner !== args.owner || !w || w.owner !== args.owner || w.kind !== "upload" || !/^[A-Za-z0-9_-]{1,100}$/.test(args.evidence)) return conflict();
  const c = await slot(ctx, p._id, args.index);
  if (c.state !== "admitting" || c.fence !== args.fence || c.uploadWork !== w._id) return conflict();
  if (w.audio) await ctx.storage.delete(w.audio);
  await ctx.db.delete(w._id);
  // The immutable manifest remains. Only exact reconciliation makes a fresh local
  // storage admission safe; this never resubmits generation or invents a result.
  await ctx.db.patch(c._id, { state: "missing", fence: c.fence + 1, uploadWork: undefined,
    error: { code: "upload_reconciled", message: "The incomplete upload was reconciled. Upload this immutable chunk again." }, admissionEvidence: args.evidence });
  await bump(ctx, p._id);
} });

// Called by deletion BEFORE removing quota buckets. Unresolved attempts retain only
// operational evidence; their parent/chunk content can be removed without resurrection.
export async function deleteBatchContent(ctx: MutationCtx, owner: string): Promise<boolean> {
  const rows = await ctx.db.query("transcriptionChunks").withIndex("by_owner", q => q.eq("owner", owner)).take(8);
  for (const c of rows) {
    const attempts = await ctx.db.query("transcriptionAttempts").withIndex("by_chunk", q => q.eq("chunk", c._id)).take(2);
    for (const a of attempts) {
      if (!a.settled) await settleQuota(ctx, a.reservation, false);
      if (!a.work) await ctx.db.delete(a._id);
      else await ctx.db.patch(a._id, { settled: true, reservation: undefined });
    }
    if (c.audio) await ctx.storage.delete(c.audio);
    await ctx.db.delete(c._id);
  }
  if (rows.length) return true;
  const parents = await ctx.db.query("transcriptionBatches").withIndex("by_owner", q => q.eq("owner", owner)).take(8);
  for (const p of parents) await ctx.db.delete(p._id);
  const attempts = await ctx.db.query("transcriptionAttempts").withIndex("by_owner", q => q.eq("owner", owner)).take(50);
  for (const a of attempts) if (!a.work || !await ctx.db.get(a.work)) await ctx.db.delete(a._id);
  return parents.length > 0;
}
export async function reconcileBatchWork(ctx: MutationCtx, work: Id<"deletionWork">) {
  const a = await ctx.db.query("transcriptionAttempts").withIndex("by_work", q => q.eq("work", work)).unique();
  if (!a) return;
  if (!a.settled) await settleQuota(ctx, a.reservation, false);
  const inv = await inventory(ctx); await ctx.db.patch(inv._id, { jobs: inv.jobs.filter(id => id !== a._id) });
  await ctx.db.delete(a._id);
}
