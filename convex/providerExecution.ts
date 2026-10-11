import { v } from "convex/values";
import { internalAction, internalMutation, internalQuery, type QueryCtx } from "./_generated/server";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { appleDeletionTransport } from "./appleDeletionTransport";
import { revenuecatDeletionTransport } from "./revenuecatDeletionTransport";
import { appleIdentity, evidenceRef, executionProvider, providerExecutionConfig, providerExecutionEnabled } from "./providerExecutionContract";
import { LEASE_MS, MAX_ATTEMPTS, retryDelay } from "./deletionAdapter";
import { exactRequest, manualStage, publishIntent } from "./deletionAutomationState";
import { fail } from "./limits";

type Row = Doc<"deletionProviderExecutions">;
const refArgs = { id: v.id("deletions"), owner: v.string() };
const fenceArgs = { execution: v.id("deletionProviderExecutions"), owner: v.string(), fence: v.number() };
type Fence = { execution: Id<"deletionProviderExecutions">; owner: string; fence: number };
const running = (s: Row | null, a: Fence): s is Row => !!s && s.owner === a.owner && s.fence === a.fence && s.state === "running" &&
  s.leaseUntil !== undefined && s.leaseUntil > Date.now();

async function targetMatches(ctx: QueryCtx, s: Row) {
  const d = await ctx.db.get(s.request), stage = await ctx.db.get(s.stage);
  return !!d && d.owner === s.owner && d.subject === s.subject && d.requestedAt === s.requestedAt && d.localComplete && !d[s.provider] &&
    !!stage && stage.request === d._id && stage.owner === s.owner && stage.kind === s.provider && stage.target === s.subject &&
    stage.fence === s.stageFence && stage.config === s.config && stage.code === "provider_execution_owned";
}
async function authorizedTarget(ctx: QueryCtx, s: Row) {
  if (!providerExecutionEnabled(s.provider) || providerExecutionConfig(s.provider) !== s.config || !await targetMatches(ctx, s)) return false;
  const d = (await ctx.db.get(s.request))!;
  if (s.provider === "apple") return !d.clerk && !!s.apple && s.apple.originalClientId === JSON.parse(s.config).clientId;
  const clerk = s.clerkStage ? await ctx.db.get(s.clerkStage) : null;
  return d.clerk && !!clerk && clerk.request === d._id && clerk.owner === s.owner && clerk.kind === "clerk" &&
    clerk.state === "manual" && clerk.fence === s.clerkFence && clerk.evidence === d.clerkEvidence;
}

// Explicit internal case adoption, never scans live accounts or trusts client IDs.
// safetyEvidence is a private-case reference: original Apple client provenance,
// or RC SDK/quiescence/recreation handling. It contains no token or credential.
export const adopt = internalMutation({ args: { ...refArgs, provider: executionProvider, stageFence: v.number(),
  safetyEvidence: v.string(), apple: v.optional(appleIdentity) }, handler: async (ctx, args) => {
  const d = await exactRequest(ctx, args.id, args.owner);
  if (!evidenceRef(args.safetyEvidence)) fail(400, "Use a private case evidence reference.");
  const existing = await ctx.db.query("deletionProviderExecutions").withIndex("by_request_provider", q => q.eq("request", d._id).eq("provider", args.provider)).unique();
  if (existing) {
    if (existing.stageFence !== args.stageFence + 1 || existing.safetyEvidence !== args.safetyEvidence ||
        existing.apple?.externalAccountId !== args.apple?.externalAccountId || existing.apple?.providerUserId !== args.apple?.providerUserId ||
        existing.apple?.originalClientId !== args.apple?.originalClientId) fail(409, "Provider execution already bound; reconcile its exact revision.");
    return existing._id;
  }
  const config = providerExecutionConfig(args.provider);
  if (!providerExecutionEnabled(args.provider) || !config) fail(409, "Provider execution disabled or unbound.");
  if (!/^user_[A-Za-z0-9]{1,250}$/.test(d.subject) || d.owner !== `${JSON.parse(config).issuer}|${d.subject}`) fail(409, "Provider identity mismatch.");
  const stage = await ctx.db.query("deletionStages").withIndex("by_request_key", q => q.eq("request", d._id).eq("key", args.provider)).unique();
  if (!d.localComplete || d[args.provider] || !stage || stage.owner !== d.owner || stage.kind !== args.provider || stage.target !== d.subject ||
      stage.fence !== args.stageFence || stage.state !== "blocked" || stage.code !== "adapter_unimplemented" || stage.config !== "unimplemented" ||
      stage.attempts >= MAX_ATTEMPTS || stage.evidence) fail(409, "Provider stage is not adoptable.");
  let code = "adopted", state: "queued" | "blocked" = "queued";
  let clerkStage: Id<"deletionStages"> | undefined, clerkFence: number | undefined;
  if (args.provider === "apple") {
    if (d.clerk) fail(409, "Apple revocation must precede Clerk deletion.");
    if (!args.apple) { state = "blocked"; code = "apple_provenance_missing"; }
    else if (!/^[A-Za-z0-9_-]{1,255}$/.test(args.apple.externalAccountId) || !args.apple.providerUserId || args.apple.providerUserId.length > 255 ||
      /[\s\u0000-\u001f\u007f]/.test(args.apple.providerUserId) || args.apple.originalClientId !== JSON.parse(config).clientId)
      fail(409, "Apple original-client binding mismatch.");
  } else {
    if (args.apple) fail(400, "Apple identity is not a RevenueCat input.");
    const clerk = await ctx.db.query("deletionStages").withIndex("by_request_key", q => q.eq("request", d._id).eq("key", "clerk")).unique();
    if (!d.clerk || !clerk || clerk.owner !== d.owner || clerk.state !== "manual" || !clerk.evidence || clerk.evidence !== d.clerkEvidence)
      fail(409, "Reconcile Clerk handling before RevenueCat execution.");
    clerkStage = clerk._id; clerkFence = clerk.fence;
  }
  await ctx.db.patch(stage._id, { config, fence: stage.fence + 1, code: "provider_execution_owned", updatedAt: Date.now() });
  const execution = await ctx.db.insert("deletionProviderExecutions", { request: d._id, owner: d.owner, subject: d.subject, requestedAt: d.requestedAt,
    provider: args.provider, stage: stage._id, stageFence: stage.fence + 1, config, safetyEvidence: args.safetyEvidence,
    ...(args.apple ? { apple: args.apple } : {}), ...(clerkStage ? { clerkStage, clerkFence } : {}),
    phase: "execute", state, fence: 0, attempts: 0, claims: 0, due: Date.now(), mutationIntent: false,
    acknowledged: false, absenceObserved: false, code, createdAt: Date.now(), updatedAt: Date.now() });
  if (state === "queued") await ctx.scheduler.runAfter(0, internal.providerExecution.run, { execution });
  await publishIntent(ctx, d._id);
  return execution;
} });

export const claim = internalMutation({ args: { execution: v.id("deletionProviderExecutions") }, handler: async (ctx, { execution }) => {
  const s = await ctx.db.get(execution);
  if (!s || !providerExecutionEnabled(s.provider) || !["queued", "retry"].includes(s.state) || s.due > Date.now()) return null;
  if (!await authorizedTarget(ctx, s)) {
    await ctx.db.patch(s._id, { state: "blocked", code: "prerequisite_changed", updatedAt: Date.now() });
    await publishIntent(ctx, s.request); return null;
  }
  if (s.attempts >= MAX_ATTEMPTS || s.claims >= MAX_ATTEMPTS + 1 || (s.phase === "execute" && s.mutationIntent)) {
    await ctx.db.patch(s._id, { state: "exhausted", code: "attempts_exhausted", updatedAt: Date.now() });
    await publishIntent(ctx, s.request); return null;
  }
  const leaseUntil = Date.now() + LEASE_MS;
  await ctx.db.patch(s._id, { state: "running", fence: s.fence + 1, attempts: s.attempts + 1, claims: s.claims + 1,
    mutationIntent: s.mutationIntent || s.phase === "execute", leaseUntil, due: leaseUntil, updatedAt: Date.now() });
  await ctx.scheduler.runAt(leaseUntil, internal.providerExecution.expire, { execution, owner: s.owner, fence: s.fence + 1 });
  await publishIntent(ctx, s.request);
  return (await ctx.db.get(s._id))!;
} });
export const authorized = internalQuery({ args: fenceArgs, handler: async (ctx, args) => {
  const s = await ctx.db.get(args.execution);
  return running(s, args) && await authorizedTarget(ctx, s);
} });

// Sanitize codes at the persistence boundary, even though adapters are internal.
const codes = new Set(["disabled", "invalid_binding", "invalid_operation", "missing_transport_or_credential", "invalid_client_secret",
  "malformed_response", "response_too_large", "authorization_prerequisite_missing", "authorization_check_failed", "authorization_withdrawn",
  "transport_timeout", "transport_unknown", "provider_rejected", "provider_temporary", "inventory_unavailable", "alias_ownership_unverified",
  "customer_identity_mismatch", "customer_delete_queued", "customer_absent", "customer_present", "deletion_outcome_unknown",
  "clerk_response_rejected", "instance_mismatch", "user_identity_mismatch", "apple_identity_inventory_unverified", "apple_identity_unverified",
  "token_inventory_unverified", "token_identity_or_shape_unverified", "token_expiry_unknown", "token_expired", "token_expiry_units_unverified",
  "apple_response_rejected", "apple_acknowledgement_body_unexpected", "apple_revocation_acknowledged"]);
const resultArgs = v.object({ state: v.union(v.literal("acknowledgement"), v.literal("absence_observed"), v.literal("observed"), v.literal("unknown"), v.literal("blocked")),
  code: v.string(), httpStatus: v.optional(v.number()), retryAfterMs: v.optional(v.number()) });
export const finish = internalMutation({ args: { ...fenceArgs, result: resultArgs }, handler: async (ctx, args) => {
  const s = await ctx.db.get(args.execution);
  if (!running(s, args)) return false;
  if (!await authorizedTarget(ctx, s)) {
    await ctx.db.patch(s._id, { state: "blocked", code: "prerequisite_changed", leaseUntil: undefined, updatedAt: Date.now(),
      ...(s.provider === "revenuecat" ? { phase: "observe" as const } : {}) });
    await publishIntent(ctx, s.request); return false;
  }
  let r = args.result;
  if (!codes.has(r.code) || (r.httpStatus !== undefined && (!Number.isInteger(r.httpStatus) || r.httpStatus < 100 || r.httpStatus > 599)) ||
      (r.retryAfterMs !== undefined && (!Number.isFinite(r.retryAfterMs) || r.retryAfterMs < 0 || r.retryAfterMs > Number.MAX_SAFE_INTEGER - Date.now())))
    r = { state: "unknown", code: "malformed_response" };
  const change: Partial<Row> = { state: "blocked", code: r.code, leaseUntil: undefined, updatedAt: Date.now() };
  if (s.provider === "apple") {
    if (r.state === "acknowledgement" && r.code === "apple_revocation_acknowledged" && r.httpStatus === 200)
      Object.assign(change, { state: "observed", acknowledged: true });
    // No programmatic readback endpoint; uncertainty stays operator-only, never replay.
  } else if (s.phase === "execute") {
    const ack = r.state === "acknowledgement" && r.code === "customer_delete_queued" && r.httpStatus === 200;
    if (ack || r.state === "unknown") Object.assign(change, { phase: "observe", state: "queued", attempts: 0, due: Date.now(), acknowledged: ack });
    // Missing inventory/alias conflicts are blocked before DELETE, not auto-complete.
  } else if (r.state === "absence_observed" && r.code === "customer_absent" && r.httpStatus === 404) {
    Object.assign(change, { state: "observed", absenceObserved: true });
  } else if (r.state === "unknown" || (r.state === "observed" && r.code === "customer_present" && r.httpStatus === 200)) {
    Object.assign(change, { state: s.attempts >= MAX_ATTEMPTS ? "exhausted" : "retry",
      due: Date.now() + retryDelay(s.attempts, Math.random(), r.retryAfterMs), code: r.state === "observed" ? "deletion_pending" : r.code });
  }
  await ctx.db.patch(s._id, change);
  if (change.state === "queued" || change.state === "retry") await ctx.scheduler.runAt(change.due!, internal.providerExecution.run, { execution: s._id });
  await publishIntent(ctx, s.request);
  return true;
} });

export const run = internalAction({ args: { execution: v.id("deletionProviderExecutions") }, handler: async (ctx, { execution }): Promise<void> => {
  const s: Row | null = await ctx.runMutation(internal.providerExecution.claim, { execution });
  if (!s) return;
  const args = { execution, owner: s.owner, fence: s.fence };
  if (!await ctx.runQuery(internal.providerExecution.authorized, args)) return;
  const binding = { ...JSON.parse(s.config), owner: s.owner, subject: s.subject };
  const authorize = async () => ctx.runQuery(internal.providerExecution.authorized, args);
  const result = s.provider === "apple"
    ? await appleDeletionTransport({ enabled: providerExecutionEnabled("apple"), binding: { ...binding,
      externalAccountId: s.apple!.externalAccountId, providerUserId: s.apple!.providerUserId, provenanceEvidence: s.safetyEvidence },
      clerkCredential: process.env.APPLE_DELETION_CLERK_SECRET_KEY ?? "", clientSecret: process.env.APPLE_DELETION_CLIENT_SECRET ?? "", fetch, authorize })
    : await revenuecatDeletionTransport({ enabled: providerExecutionEnabled("revenuecat"), binding,
      operation: s.phase === "execute" ? "deleteCustomer" : "observeCustomer", credential: process.env.REVENUECAT_DELETION_SECRET_KEY ?? "", fetch, authorize });
  await ctx.runMutation(internal.providerExecution.finish, { ...args, result });
} });

export const expire = internalMutation({ args: fenceArgs, handler: async (ctx, args) => {
  const s = await ctx.db.get(args.execution);
  if (!s || s.owner !== args.owner || s.fence !== args.fence || s.state !== "running" || s.leaseUntil === undefined || s.leaseUntil > Date.now()) return;
  const canObserve = s.provider === "revenuecat" && (s.phase === "execute" || s.attempts < MAX_ATTEMPTS) && s.claims < MAX_ATTEMPTS + 1;
  const due = Date.now() + retryDelay(s.attempts, Math.random());
  await ctx.db.patch(s._id, { state: canObserve ? "retry" : "blocked", fence: s.fence + 1, leaseUntil: undefined, due,
    code: "lease_expired_unknown", updatedAt: Date.now(), ...(s.provider === "revenuecat" ? { phase: "observe" as const, ...(s.phase === "execute" ? { attempts: 0 } : {}) } : {}) });
  if (canObserve && providerExecutionEnabled(s.provider)) await ctx.scheduler.runAt(due, internal.providerExecution.run, { execution: s._id });
  await publishIntent(ctx, s.request);
} });
export const recover = internalMutation({ args: {}, handler: async ctx => {
  // A disabled provider's backlog must not starve the other provider's ready work.
  for (const provider of ["apple", "revenuecat"] as const) {
    if (!providerExecutionEnabled(provider)) continue;
    for (const state of ["queued", "retry", "running"] as const) {
      const rows = await ctx.db.query("deletionProviderExecutions").withIndex("by_provider_state_due", q => q.eq("provider", provider).eq("state", state).lte("due", Date.now())).take(16);
      for (const s of rows) {
        if (state === "running") await ctx.scheduler.runAfter(0, internal.providerExecution.expire, { execution: s._id, owner: s.owner, fence: s.fence });
        else await ctx.scheduler.runAfter(0, internal.providerExecution.run, { execution: s._id });
      }
    }
  }
} });
export const inventory = internalQuery({ args: refArgs, handler: async (ctx, { id, owner }) => {
  await exactRequest(ctx, id, owner);
  return ctx.db.query("deletionProviderExecutions").withIndex("by_request_provider", q => q.eq("request", id)).take(2);
} });

// A generic operator reopening invalidates the frozen stage, but must not strand
// its execution forever. Resolve uncertainty, never rebind/rearm provider calls.
// This only releases the execution hold; completion still needs separate evidence.
export const releaseInvalidated = internalMutation({ args: { ...fenceArgs, stageFence: v.number(), automationRevision: v.number(),
  evidence: v.string(), remoteEffects: v.literal("reconciled") }, handler: async (ctx, args) => {
  const s = await ctx.db.get(args.execution);
  if (!s || s.owner !== args.owner || s.fence !== args.fence || s.state === "running" || s.state === "manual" || !evidenceRef(args.evidence))
    fail(409, "Reconcile the exact non-running invalidated execution first.");
  const d = await exactRequest(ctx, s.request, args.owner), stage = await ctx.db.get(s.stage);
  if (d.subject !== s.subject || d.requestedAt !== s.requestedAt || d.automationRevision !== args.automationRevision || d[s.provider] ||
      !stage || stage.request !== d._id || stage.owner !== s.owner || stage.kind !== s.provider || stage.target !== s.subject ||
      stage.state !== "manual" || stage.code !== "operator_evidence" || stage.fence !== args.stageFence || stage.fence <= s.stageFence)
    fail(409, "Current stage invalidation revision does not match.");
  await ctx.db.patch(s._id, { state: "manual", fence: s.fence + 1, leaseUntil: undefined, evidence: args.evidence,
    code: "stage_invalidation_reconciled", updatedAt: Date.now() });
  await publishIntent(ctx, d._id);
} });

// Human-approved exception route. Operator must verify the actual provider scope
// in the private case, including Apple history or RC aliases/recreation. No API
// acknowledgement, missing token, elapsed deadline or alias assumption suffices.
export const reconcile = internalMutation({ args: { ...fenceArgs, evidence: v.string(), automationRevision: v.number() }, handler: async (ctx, args) => {
  const s = await ctx.db.get(args.execution);
  if (!s || s.owner !== args.owner || s.fence !== args.fence || !["observed", "blocked", "exhausted"].includes(s.state) ||
      !evidenceRef(args.evidence) || !await targetMatches(ctx, s)) fail(409, "Verify the exact terminal provider case before reconciliation.");
  const d = (await ctx.db.get(s.request))!;
  if (d.automationRevision !== args.automationRevision) fail(409, "Deletion revision changed; inspect the exact request again.");
  await ctx.db.patch(s._id, { state: "manual", fence: s.fence + 1, evidence: args.evidence, updatedAt: Date.now() });
  await ctx.db.patch(d._id, { [s.provider]: true, [`${s.provider}Evidence`]: args.evidence, updatedAt: Date.now() });
  await manualStage(ctx, (await ctx.db.get(s.stage))!, args.evidence);
  await publishIntent(ctx, d._id);
} });
