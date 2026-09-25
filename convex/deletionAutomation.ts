import { v } from "convex/values";
import { internalAction, internalMutation, internalQuery } from "./_generated/server";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { automationEnabled, executeDeletion, geminiProjectRef, LEASE_MS, MAX_ATTEMPTS, retryDelay } from "./deletionAdapter";
import { canDrainFileWork, classification, exactRequest, publishIntent } from "./deletionAutomationState";
import { fail } from "./limits";
import { preflightEnabled } from "./preflightAdapter";
import { reconcileBatchWork } from "./batches";

const providers = ["apple", "clerk", "revenuecat", "gemini", "residuals"] as const;
const refArgs = { id: v.id("deletions"), owner: v.string() };
const fenceArgs = { id: v.id("deletionStages"), owner: v.string(), fence: v.number(), target: v.string(), config: v.string() };
type Fence = { id: Id<"deletionStages">; owner: string; fence: number; target: string; config: string };
function matches(stage: Doc<"deletionStages"> | null, args: Fence): stage is Doc<"deletionStages"> {
  return !!stage && stage.owner === args.owner && stage.fence === args.fence && stage.target === args.target && stage.config === args.config &&
    stage.state === "running" && stage.leaseUntil !== undefined && stage.leaseUntil > Date.now();
}

// Called after bounded local cleanup; also provides explicit recovery for old requests.
export const start = internalMutation({ args: refArgs, handler: async (ctx, { id, owner }) => {
  const d = await exactRequest(ctx, id, owner);
  if (!automationEnabled()) return;
  const epoch = (d.discoveryEpoch ?? 0) + 1;
  await ctx.db.patch(id, { automationRevision: d.automationRevision ?? 0, discoveryComplete: false, discoveryEpoch: epoch });
  for (const kind of providers) {
    const existing = await ctx.db.query("deletionStages").withIndex("by_request_key", q => q.eq("request", id).eq("key", kind)).unique();
    if (!existing) {
      const stage = await ctx.db.insert("deletionStages", { request: id, owner, key: kind, kind, target: d.subject,
        config: "unimplemented", state: d[kind] ? "manual" : "queued", fence: 0, attempts: 0,
        nextAttemptAt: Date.now(), updatedAt: Date.now(), ...(d[kind] ? { code: "legacy_operator_confirmation" } : {}) });
      if (!d[kind]) await ctx.scheduler.runAfter(0, internal.deletionAutomation.run, { id: stage });
    }
  }
  await ctx.scheduler.runAfter(0, internal.deletionAutomation.discover, { id, owner, epoch, cursor: null });
  await publishIntent(ctx, id);
  if (preflightEnabled()) await ctx.scheduler.runAfter(0, internal.deletionPreflight.start, { id, owner });
} });

export const discover = internalMutation({ args: { ...refArgs, epoch: v.number(), cursor: v.union(v.null(), v.string()) },
  handler: async (ctx, { id, owner, epoch, cursor }) => {
    const d = await exactRequest(ctx, id, owner);
    if (!automationEnabled() || d.discoveryEpoch !== epoch) return;
    const page = await ctx.db.query("deletionWork").withIndex("by_owner", q => q.eq("owner", owner)).paginate({ cursor, numItems: 32 });
    let drained = false;
    for (const work of page.page) {
      // Never race an active upload/generation/finally block. Unknown uploads stay exceptions.
      if (work.kind !== "gemini" || !work.finished || !work.file) continue;
      const key = `file:${work._id}`;
      const existing = await ctx.db.query("deletionStages").withIndex("by_request_key", q => q.eq("request", id).eq("key", key)).unique();
      if (existing) continue; // Do not retarget, change config, reopen, or reset attempts.
      const config = work.providerConfig ?? "unverified";
      const valid = /^files\/[A-Za-z0-9_-]+$/.test(work.file);
      const verifiedConfig = !!work.providerConfig && config === geminiProjectRef();
      const state = work.fileDeleted ? "succeeded" : valid && verifiedConfig ? "queued" : "blocked";
      const stage = await ctx.db.insert("deletionStages", { request: id, owner, key, kind: "geminiFile", target: work.file, config,
        work: work._id, state, fence: 0, attempts: 0, nextAttemptAt: Date.now(), updatedAt: Date.now(),
        ...(work.fileDeleted ? { code: "previous_file_acknowledgement" } : state === "blocked" ? { code: valid ? "unverified_config" : "invalid_target" } : {}) });
      if (state === "queued") await ctx.scheduler.runAfter(0, internal.deletionAutomation.run, { id: stage });
      if (canDrainFileWork(work)) { await reconcileBatchWork(ctx, work._id); await ctx.db.delete(work._id); drained = true; }
    }
    if (page.isDone) await ctx.db.patch(id, { discoveryComplete: true });
    else await ctx.scheduler.runAfter(0, internal.deletionAutomation.discover, { id, owner, epoch, cursor: page.continueCursor });
    if (drained) await ctx.scheduler.runAfter(0, internal.deletion.cleanup, { id });
    await publishIntent(ctx, id);
  } });

export const claim = internalMutation({ args: { id: v.id("deletionStages") }, handler: async (ctx, { id }) => {
  const s = await ctx.db.get(id);
  if (!s || !automationEnabled() || !["queued", "retry"].includes(s.state) || s.nextAttemptAt > Date.now()) return null;
  const d = await exactRequest(ctx, s.request, s.owner);
  if (s.attempts >= MAX_ATTEMPTS) {
    await ctx.db.patch(id, { state: "exhausted", code: "attempts_exhausted", updatedAt: Date.now() });
    await publishIntent(ctx, d._id); return null;
  }
  if (s.kind === "geminiFile") {
    const w = s.work ? await ctx.db.get(s.work) : null;
    if (!w || w.owner !== s.owner || w.file !== s.target || w.providerConfig !== s.config || !w.finished || w.kind !== "gemini") {
      await ctx.db.patch(id, { state: "blocked", code: "work_target_mismatch", updatedAt: Date.now() });
      await publishIntent(ctx, d._id); return null;
    }
  } else if (s.target !== d.subject) {
    await ctx.db.patch(id, { state: "blocked", code: "identity_mismatch", updatedAt: Date.now() });
    await publishIntent(ctx, d._id); return null;
  }
  const leaseUntil = Date.now() + LEASE_MS;
  await ctx.db.patch(id, { state: "running", fence: s.fence + 1, attempts: s.attempts + 1, leaseUntil,
    nextAttemptAt: leaseUntil, updatedAt: Date.now() });
  // Watchdog is committed with the claim, not entrusted to action finally.
  await ctx.scheduler.runAt(leaseUntil, internal.deletionAutomation.expire, { id, fence: s.fence + 1 });
  await publishIntent(ctx, d._id);
  return (await ctx.db.get(id))!;
} });

export const authorized = internalQuery({ args: fenceArgs, handler: async (ctx, args) => {
  const s = await ctx.db.get(args.id);
  if (!automationEnabled() || !matches(s, args)) return false;
  const d = await ctx.db.get(s.request);
  if (!d || d.owner !== s.owner) return false;
  if (s.kind !== "geminiFile") return s.target === d.subject;
  const w = s.work ? await ctx.db.get(s.work) : null;
  return !!w && w.owner === s.owner && w.file === s.target && w.providerConfig === s.config && w.finished;
} });

export const finish = internalMutation({ args: { ...fenceArgs, result: v.object({
  state: v.union(v.literal("succeeded"), v.literal("retry"), v.literal("blocked")), code: v.string(),
  httpStatus: v.optional(v.number()), retryAfterMs: v.optional(v.number()),
}) }, handler: async (ctx, args) => {
  const s = await ctx.db.get(args.id);
  if (!matches(s, args)) return false;
  await exactRequest(ctx, s.request, s.owner);
  let result = args.result;
  // Only allow sanitized adapter categories; never persist arbitrary upstream messages.
  const allowed = ["automation_disabled", "adapter_unimplemented", "invalid_target", "config_mismatch", "missing_secret",
    "deleted", "absent", "provider_temporary", "provider_rejected", "malformed_response", "transport_unknown"];
  if (!allowed.includes(result.code) || (result.httpStatus !== undefined && (!Number.isInteger(result.httpStatus) || result.httpStatus < 100 || result.httpStatus > 599)) ||
    (result.retryAfterMs !== undefined && (!Number.isFinite(result.retryAfterMs) || result.retryAfterMs < 0 || result.retryAfterMs > Number.MAX_SAFE_INTEGER - Date.now()))) {
    result = { state: "blocked", code: "malformed_response" };
  }
  if (result.state === "succeeded" && (s.kind !== "geminiFile" || !((result.code === "deleted" && result.httpStatus === 200) || (result.code === "absent" && result.httpStatus === 404)))) {
    result = { state: "blocked", code: "malformed_response" };
  }
  const work = s.work ? await ctx.db.get(s.work) : null;
  if (s.kind === "geminiFile" && (!work || work.owner !== s.owner || work.file !== s.target || work.providerConfig !== s.config || !work.finished || s.config !== geminiProjectRef())) {
    result = { state: "blocked", code: "config_mismatch" };
  }
  const exhausted = result.state === "retry" && s.attempts >= MAX_ATTEMPTS;
  const state = exhausted ? "exhausted" : result.state;
  const nextAttemptAt = state === "retry" ? Date.now() + retryDelay(s.attempts, Math.random(), result.retryAfterMs) : s.nextAttemptAt;
  await ctx.db.patch(s._id, { state, code: result.code, httpStatus: result.httpStatus, leaseUntil: undefined, nextAttemptAt, updatedAt: Date.now() });
  if (state === "retry") await ctx.scheduler.runAt(nextAttemptAt, internal.deletionAutomation.run, { id: s._id });
  if (state === "succeeded" && work) {
    await ctx.db.patch(work._id, { fileDeleted: true });
    if (canDrainFileWork({ ...work, fileDeleted: true })) { await reconcileBatchWork(ctx, work._id); await ctx.db.delete(work._id); }
    await ctx.scheduler.runAfter(0, internal.deletion.cleanup, { id: s.request });
  }
  await publishIntent(ctx, s.request);
  return true;
} });

export const run = internalAction({ args: { id: v.id("deletionStages") }, handler: async (ctx, { id }): Promise<void> => {
  const stage: Doc<"deletionStages"> | null = await ctx.runMutation(internal.deletionAutomation.claim, { id });
  if (!stage) return;
  const args = { id, owner: stage.owner, fence: stage.fence, target: stage.target, config: stage.config };
  if (!await ctx.runQuery(internal.deletionAutomation.authorized, args)) return; // watchdog reconciles an abandoned claim
  const result = await executeDeletion(stage);
  await ctx.runMutation(internal.deletionAutomation.finish, { ...args, result });
} });

export const expire = internalMutation({ args: { id: v.id("deletionStages"), fence: v.number() }, handler: async (ctx, { id, fence }) => {
  const s = await ctx.db.get(id);
  if (!s || s.state !== "running" || s.fence !== fence || s.leaseUntil === undefined || s.leaseUntil > Date.now()) return;
  const state = s.attempts >= MAX_ATTEMPTS ? "exhausted" : "retry";
  const nextAttemptAt = Date.now() + retryDelay(s.attempts, Math.random());
  await ctx.db.patch(id, { state, fence: s.fence + 1, code: "lease_expired_unknown", leaseUntil: undefined, nextAttemptAt, updatedAt: Date.now() });
  if (automationEnabled() && state === "retry") await ctx.scheduler.runAt(nextAttemptAt, internal.deletionAutomation.run, { id });
  await publishIntent(ctx, s.request);
} });

// Backup to per-claim watchdogs and persisted wakeups, bounded by state/due indexes.
export const recover = internalMutation({ args: {}, handler: async ctx => {
  if (!automationEnabled()) return;
  for (const state of ["queued", "retry", "running"] as const) {
    const rows = await ctx.db.query("deletionStages").withIndex("by_state_due", q => q.eq("state", state).lte("nextAttemptAt", Date.now())).take(16);
    for (const s of rows) {
      if (state === "running") await ctx.scheduler.runAfter(0, internal.deletionAutomation.expire, { id: s._id, fence: s.fence });
      else await ctx.scheduler.runAfter(0, internal.deletionAutomation.run, { id: s._id });
    }
  }
} });

export const inventory = internalQuery({ args: { ...refArgs, cursor: v.union(v.null(), v.string()) }, handler: async (ctx, { id, owner, cursor }) => {
  const d = await exactRequest(ctx, id, owner);
  return { enabled: automationEnabled(), classification: await classification(ctx, d),
    stages: await ctx.db.query("deletionStages").withIndex("by_request_key", q => q.eq("request", id)).paginate({ cursor, numItems: 32 }),
    outbox: await ctx.db.query("deletionOutbox").withIndex("by_request", q => q.eq("request", id)).unique() };
} });

// Resume only the SAME blocked target/config, never reset exhausted budgets or operator evidence.
export const resume = internalMutation({ args: { ...refArgs, stage: v.id("deletionStages"), fence: v.number() }, handler: async (ctx, { id, owner, stage, fence }) => {
  await exactRequest(ctx, id, owner);
  const s = await ctx.db.get(stage);
  if (!s || s.request !== id || s.owner !== owner || s.fence !== fence) fail(409, "Deletion stage revision changed.");
  if (!automationEnabled() || s.state !== "blocked" || s.attempts >= MAX_ATTEMPTS || s.kind !== "geminiFile") fail(409, "Deletion stage needs operator reconciliation.");
  await ctx.db.patch(stage, { state: "queued", fence: s.fence + 1, nextAttemptAt: Date.now(), updatedAt: Date.now() });
  await ctx.scheduler.runAfter(0, internal.deletionAutomation.run, { id: stage });
  await publishIntent(ctx, id);
} });
