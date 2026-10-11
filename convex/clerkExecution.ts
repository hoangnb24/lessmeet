import { v } from "convex/values";
import { internalAction, internalMutation, internalQuery, type QueryCtx, type MutationCtx } from "./_generated/server";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { clerkDeletionTransport, type ClerkBinding, type ClerkOperation } from "./clerkDeletionTransport";
import { appleDisposition, clerkExecutionConfig, clerkExecutionEnabled, destructivePhase,
  MAX_EXECUTION_CLAIMS, observationPhase, validEvidence } from "./clerkExecutionContract";
import { LEASE_MS, MAX_ATTEMPTS, retryDelay } from "./deletionAdapter";
import { exactRequest, manualStage, publishIntent } from "./deletionAutomationState";
import { fail } from "./limits";
import { boundContact } from "./deletionNotifications";
import { googleDeletionTransport, type GoogleAccount } from "./googleDeletionTransport";
import { executionPhase, googleExecutionConfig, googleExecutionEnabled, googlePhase } from "./clerkExecutionContract";

type Row = Doc<"deletionClerkExecutions">;
const exactArgs = { id: v.id("deletions"), owner: v.string() };
const fenceArgs = { execution: v.id("deletionClerkExecutions"), owner: v.string(), fence: v.number() };
type Fence = { execution: Id<"deletionClerkExecutions">; owner: string; fence: number };
const statuses = ["active", "revoked", "ended", "expired", "removed", "abandoned", "replaced", "pending"];
const terminal = (status: string) => statuses.includes(status) && !["active", "pending"].includes(status);
const current = (s: Row | null, a: Fence): s is Row => !!s && s.owner === a.owner && s.fence === a.fence &&
  s.state === "running" && s.leaseUntil !== undefined && s.leaseUntil > Date.now();
const executionSnapshot = (s: Row) => JSON.stringify({ request: s.request, subject: s.subject, requestedAt: s.requestedAt,
  phase: s.phase, config: s.config, googleConfig: s.googleConfig, accounts: s.googleAccounts, index: s.googleIndex,
  googleEvidence: s.googleEvidence, googleComplete: s.googleComplete, googleNotApplicable: s.googleNotApplicable,
  googleOperatorEvidence: s.googleOperatorEvidence,
  appleEvidence: s.appleEvidence, appleFence: s.appleFence, stageFence: s.stageFence });

async function hasContact(ctx: QueryCtx, d: Doc<"deletions">) {
  const c = await ctx.db.query("deletionContacts").withIndex("by_request", q => q.eq("request", d._id)).unique();
  return !!c && !!boundContact(c, d);
}

async function prerequisites(ctx: QueryCtx, s: Row) {
  if (!clerkExecutionEnabled() || s.config !== clerkExecutionConfig()) return false;
  const d = await ctx.db.get(s.request), apple = await ctx.db.get(s.appleStage), stage = await ctx.db.get(s.stage);
  return !!d && d.owner === s.owner && d.subject === s.subject && d.requestedAt === s.requestedAt && d.localComplete && !d.clerk &&
    d.apple && d.appleEvidence === s.appleEvidence && !!apple && apple.request === d._id && apple.owner === s.owner &&
    apple.kind === "apple" && apple.fence === s.appleFence && apple.evidence === s.appleEvidence && apple.state === "manual" &&
    !!stage && stage.request === d._id && stage.owner === s.owner && stage.kind === "clerk" && stage.fence === s.stageFence &&
    stage.config === s.config && stage.target === s.subject && stage.code === "clerk_execution_owned" &&
    stage.state === "blocked" && !stage.evidence &&
    // Historical executions may still observe/reconcile. Never fabricate a contact
    // or authorize a new destructive effect without the durable bound address.
    (!["revokeGoogle", "revokeSession", "deleteUser"].includes(s.phase) || await hasContact(ctx, d)) &&
    (!(googlePhase(s.phase) || destructivePhase(s.phase)) ||
      googleExecutionEnabled() && !!s.googleConfig && s.googleConfig === googleExecutionConfig() &&
      d.googleRequired === true &&
      (!googlePhase(s.phase) || (s.googleAccounts?.length ?? 0) <= 1) &&
      (s.phase !== "revokeGoogle" || s.googleAccounts?.length === 1 && s.googleIndex === 0) &&
      (!destructivePhase(s.phase) || googleProof(s, d)));
}

function googleProof(s: Row, d: Doc<"deletions">) {
  return s.googleComplete === true && !!s.googleEvidence && validEvidence(s.googleEvidence) && d.googleEvidence === s.googleEvidence &&
    (s.googleNotApplicable === true ? d.googleStatus === "not_applicable" && s.googleAccounts?.length === 0 &&
      !!s.googleOperatorEvidence && validEvidence(s.googleOperatorEvidence) :
      d.googleStatus === "acknowledged" && s.googleAccounts?.length === 1 &&
        s.googleAccounts.every(a => a.acknowledged && !!a.evidence && validEvidence(a.evidence)));
}
const sortedAccounts = (accounts: GoogleAccount[]) => accounts.map(a => ({ externalAccountId: a.externalAccountId,
  providerUserId: a.providerUserId })).sort((a, b) => a.externalAccountId < b.externalAccountId ? -1 : a.externalAccountId > b.externalAccountId ? 1 : 0);
const sameAccounts = (a: GoogleAccount[], b: GoogleAccount[]) => JSON.stringify(sortedAccounts(a)) === JSON.stringify(sortedAccounts(b));
function validAccounts(accounts: GoogleAccount[]) {
  return accounts.length <= 16 && accounts.every(a => /^[A-Za-z0-9_-]{1,250}$/.test(a.externalAccountId) &&
    /^[A-Za-z0-9_-]{1,250}$/.test(a.providerUserId)) && new Set(accounts.map(a => a.externalAccountId)).size === accounts.length &&
    new Set(accounts.map(a => a.providerUserId)).size === accounts.length;
}
async function invalidateGoogle(ctx: MutationCtx, s: Row) {
  const d = await ctx.db.get(s.request);
  if (d && (d.googleRequired || s.googleConfig)) await ctx.db.patch(d._id, {
    googleStatus: "exception", googleEvidence: undefined, updatedAt: Date.now() });
  await ctx.db.patch(s._id, { googleComplete: false, googleEvidence: undefined });
}

// Explicit adoption only. No cron scans for accounts, no reuse of preflight snapshots.
// Disposition is a trusted operator attestation backed by the private Apple case.
export const adopt = internalMutation({ args: { ...exactArgs, stageFence: v.number(), appleFence: v.number(),
  appleEvidence: v.string(), disposition: appleDisposition }, handler: async (ctx, args) => {
  const d = await exactRequest(ctx, args.id, args.owner);
  const existing = await ctx.db.query("deletionClerkExecutions").withIndex("by_request", q => q.eq("request", d._id)).unique();
  if (existing) {
    if (existing.owner !== args.owner || existing.appleFence !== args.appleFence || existing.appleEvidence !== args.appleEvidence ||
        existing.appleDisposition !== args.disposition || existing.stageFence !== args.stageFence + 1) fail(409, "Execution already bound; reconcile its exact revision.");
    return existing._id; // Never reset budgets or rebind evidence/configuration.
  }
  const config = clerkExecutionConfig();
  if (!clerkExecutionEnabled() || !config) fail(409, "Clerk execution is disabled or unbound.");
  const googleConfig = googleExecutionConfig();
  if (!googleExecutionEnabled() || !googleConfig) fail(409, "Google execution is disabled or unbound.");
  const binding = JSON.parse(config) as ClerkBinding;
  if (!/^user_[A-Za-z0-9]{1,250}$/.test(d.subject) || d.owner !== `${binding.issuer}|${d.subject}`) fail(409, "Clerk identity mismatch.");
  const stage = await ctx.db.query("deletionStages").withIndex("by_request_key", q => q.eq("request", d._id).eq("key", "clerk")).unique();
  const apple = await ctx.db.query("deletionStages").withIndex("by_request_key", q => q.eq("request", d._id).eq("key", "apple")).unique();
  if (!d.localComplete || d.clerk || !stage || stage.owner !== d.owner || stage.target !== d.subject || stage.kind !== "clerk" ||
      stage.fence !== args.stageFence || stage.state !== "blocked" || stage.code !== "adapter_unimplemented" ||
      stage.config !== "unimplemented" || stage.attempts >= MAX_ATTEMPTS || stage.evidence) fail(409, "Clerk stage is not adoptable.");
  if (!d.apple || !validEvidence(args.appleEvidence) || d.appleEvidence !== args.appleEvidence || !apple || apple.owner !== d.owner ||
      apple.kind !== "apple" || apple.state !== "manual" || apple.fence !== args.appleFence || apple.evidence !== args.appleEvidence)
    fail(409, "Verified Apple disposition required.");
  if (!await hasContact(ctx, d)) fail(409, "Verified durable non-relay email contact required. Capture the exact account contact or record a manual exception before Clerk deletion.");
  await ctx.db.patch(stage._id, { config, fence: stage.fence + 1, code: "clerk_execution_owned", updatedAt: Date.now() });
  const execution = await ctx.db.insert("deletionClerkExecutions", { request: d._id, owner: d.owner, subject: d.subject,
    requestedAt: d.requestedAt, stage: stage._id, stageFence: stage.fence + 1, config,
    appleStage: apple._id, appleFence: apple.fence, appleEvidence: args.appleEvidence, appleDisposition: args.disposition,
    googleConfig, googleIndex: 0, googleComplete: false,
    phase: "inventoryUser", state: "queued", sessions: [], offset: 0, sessionIndex: 0, inventoryComplete: false,
    mutationUncertain: false, userDeleteAcknowledged: false, userAbsenceObserved: false,
    fence: 0, attempts: 0, claims: 0, due: Date.now(), code: "adopted", createdAt: Date.now(), updatedAt: Date.now() });
  await ctx.scheduler.runAfter(0, internal.clerkExecution.run, { execution });
  await ctx.db.patch(d._id, { googleRequired: true, googleStatus: "pending", googleEvidence: undefined, updatedAt: Date.now() });
  await publishIntent(ctx, d._id);
  return execution;
} });

export const claim = internalMutation({ args: { execution: v.id("deletionClerkExecutions") }, handler: async (ctx, { execution }) => {
  const s = await ctx.db.get(execution);
  if (!s || !clerkExecutionEnabled() || !["queued", "retry"].includes(s.state) || s.due > Date.now()) return null;
  if (s.phase === "revokeGoogle" && s.mutationUncertain) {
    await invalidateGoogle(ctx, s);
    await ctx.db.patch(s._id, { state: "blocked", code: "google_revoke_unresolved", updatedAt: Date.now() });
    return null;
  }
  if (!await prerequisites(ctx, s)) {
    const d = await ctx.db.get(s.request);
    const code = destructivePhase(s.phase) && d && !await hasContact(ctx, d) ? "contact_required_manual_exception" : "prerequisite_changed";
    await invalidateGoogle(ctx, s);
    await ctx.db.patch(s._id, { state: "blocked", code, updatedAt: Date.now() }); return null;
  }
  if (s.attempts >= MAX_ATTEMPTS || s.claims >= MAX_EXECUTION_CLAIMS) {
    await ctx.db.patch(s._id, { state: "exhausted", code: "attempts_exhausted", updatedAt: Date.now() }); return null;
  }
  const leaseUntil = Date.now() + LEASE_MS;
  await ctx.db.patch(s._id, { state: "running", fence: s.fence + 1, attempts: s.attempts + 1, claims: s.claims + 1,
    leaseUntil, due: leaseUntil, updatedAt: Date.now(), ...((destructivePhase(s.phase) || s.phase === "revokeGoogle") ? { mutationUncertain: true } : {}) });
  if (s.phase === "revokeGoogle") await ctx.db.patch(s.request, { googleStatus: "revoking", googleEvidence: undefined });
  await ctx.scheduler.runAt(leaseUntil, internal.clerkExecution.expire, { execution, owner: s.owner, fence: s.fence + 1 });
  return (await ctx.db.get(execution))!;
} });

export const authorized = internalQuery({ args: { ...fenceArgs, phase: v.optional(executionPhase),
  googleIndex: v.optional(v.number()), snapshot: v.optional(v.string()) }, handler: async (ctx, args) => {
  const s = await ctx.db.get(args.execution);
  return current(s, args) && (args.phase === undefined || s.phase === args.phase) &&
    (args.googleIndex === undefined || s.googleIndex === args.googleIndex) &&
    (args.snapshot === undefined || executionSnapshot(s) === args.snapshot) &&
    (s.phase !== "revokeGoogle" || !!s.googleAccounts?.[s.googleIndex ?? -1] &&
      !s.googleAccounts[s.googleIndex!].acknowledged) && await prerequisites(ctx, s);
} });

const transportResult = v.object({ state: v.union(v.literal("observed"), v.literal("acknowledgement"), v.literal("absence_observed"),
  v.literal("session_revoked"), v.literal("unknown"), v.literal("blocked")), code: v.string(), httpStatus: v.optional(v.number()),
  sessionStatus: v.optional(v.string()), sessions: v.optional(v.array(v.object({ id: v.string(), status: v.string() }))), nextOffset: v.optional(v.number()) });

const googleResult = v.object({ state: v.union(v.literal("inventory"), v.literal("acknowledgement"), v.literal("blocked"), v.literal("unknown")),
  code: v.string(), httpStatus: v.optional(v.number()), accounts: v.optional(v.array(v.object({ externalAccountId: v.string(), providerUserId: v.string() }))) });

export const finishGoogle = internalMutation({ args: { ...fenceArgs, snapshot: v.optional(v.string()), result: googleResult }, handler: async (ctx, args) => {
  const s = await ctx.db.get(args.execution);
  if (!current(s, args) || !googlePhase(s.phase)) return false;
  const r = args.result;
  let change: Partial<Row> = { state: "blocked", leaseUntil: undefined, code: "google_exception", updatedAt: Date.now() };
  let status: Doc<"deletions">["googleStatus"] = "exception";
  if ((args.snapshot === undefined || args.snapshot === executionSnapshot(s)) && await prerequisites(ctx, s)) {
    if (s.phase === "revokeGoogle") {
      const target = s.googleAccounts?.[s.googleIndex ?? -1];
      if (target && !target.acknowledged && r.state === "acknowledgement" && r.code === "google_revoke_acknowledged" && r.httpStatus === 200) {
        const accounts = s.googleAccounts!.map((a, i) => i === s.googleIndex ? { ...a, acknowledged: true,
          evidence: `google_revoke_${s._id}_${s.fence}_${i}` } : a);
        const index = s.googleIndex! + 1;
        Object.assign(change, { googleAccounts: accounts, googleIndex: index, mutationUncertain: false,
          state: "queued", phase: "verifyGoogleInventory", attempts: 0, due: Date.now(), code: r.code });
        status = "pending";
      } else change.code = "google_revoke_unresolved";
    } else if (r.state === "unknown") {
      const exhausted = s.attempts >= MAX_ATTEMPTS || s.claims >= MAX_EXECUTION_CLAIMS;
      Object.assign(change, { state: exhausted ? "exhausted" : "retry", code: "google_inventory_unknown", due: Date.now() + retryDelay(s.attempts, Math.random()) });
      status = "pending";
    } else if (r.state === "inventory" && r.code === "google_inventory_observed" && r.httpStatus === 200 && r.accounts && validAccounts(r.accounts)) {
      if (s.phase === "inventoryGoogle") {
        Object.assign(change, { googleAccounts: sortedAccounts(r.accounts).map(a => ({ ...a, acknowledged: false })), googleIndex: 0,
          mutationUncertain: false, code: r.accounts.length ? "google_inventory_observed" : "google_empty_inventory_operator_required" });
        status = "pending";
        if (r.accounts.length === 1) Object.assign(change, { state: "queued", phase: "revokeGoogle", attempts: 0, due: Date.now() });
        else if (r.accounts.length > 1) {
          // Clerk lookup is provider-wide and may refresh every returned token.
          // Never fetch the next target after acknowledging an earlier target.
          change.code = "google_multiple_accounts_operator_required"; status = "exception";
        }
      } else if (s.googleAccounts && sameAccounts(r.accounts, s.googleAccounts) &&
          (s.googleNotApplicable ? !r.accounts.length && !!s.googleOperatorEvidence && validEvidence(s.googleOperatorEvidence) :
            r.accounts.length === 1 && s.googleAccounts.every(a => a.acknowledged && !!a.evidence && validEvidence(a.evidence)))) {
        // This ref identifies this exact fenced proof. It contains no token or contact.
        const evidence = `google_${s._id}_${s.fence}`;
        Object.assign(change, { googleComplete: true, googleEvidence: evidence, mutationUncertain: false, state: "queued",
          phase: "inventorySessions", attempts: 0, due: Date.now(), code: "google_inventory_verified" });
        status = s.googleNotApplicable ? "not_applicable" : "acknowledged";
      } else change.code = "google_inventory_changed";
    }
  } else change.code = s.phase === "revokeGoogle" ? "google_revoke_unresolved" : "prerequisite_changed";
  if (status === "exception") await invalidateGoogle(ctx, s);
  await ctx.db.patch(s._id, change);
  await ctx.db.patch(s.request, { googleStatus: status, googleEvidence: change.googleEvidence, updatedAt: Date.now() });
  if (change.state === "queued" || change.state === "retry") await ctx.scheduler.runAt(change.due!, internal.clerkExecution.run, { execution: s._id });
  await publishIntent(ctx, s.request);
  return true;
} });

export const invalidateGoogleProof = internalMutation({ args: fenceArgs, handler: async (ctx, args) => {
  const s = await ctx.db.get(args.execution);
  if (!current(s, args)) return;
  await invalidateGoogle(ctx, s);
  await ctx.db.patch(s._id, { state: "blocked", leaseUntil: undefined, code: "google_inventory_changed", updatedAt: Date.now(),
    ...(destructivePhase(s.phase) ? { phase: observationPhase(s.phase), mutationUncertain: true } : {}) });
  await publishIntent(ctx, s.request);
} });

export const finish = internalMutation({ args: { ...fenceArgs, snapshot: v.optional(v.string()), result: transportResult }, handler: async (ctx, args) => {
  const s = await ctx.db.get(args.execution);
  if (!current(s, args)) return false;
  if ((args.snapshot !== undefined && args.snapshot !== executionSnapshot(s)) || !await prerequisites(ctx, s)) {
    const d = await ctx.db.get(s.request);
    const code = destructivePhase(s.phase) && d && !await hasContact(ctx, d) ? "contact_required_manual_exception" : "prerequisite_changed";
    await invalidateGoogle(ctx, s);
    await ctx.db.patch(s._id, { state: "blocked", code, leaseUntil: undefined, updatedAt: Date.now(),
      ...(destructivePhase(s.phase) ? { phase: observationPhase(s.phase), mutationUncertain: true } : {}) });
    return false;
  }
  const r = args.result;
  let change: Partial<Row> = { state: "blocked", code: "unexpected_observation", leaseUntil: undefined, updatedAt: Date.now() };
  const queue = (phase: Row["phase"]) => { change = { ...change, state: "queued", phase, attempts: 0, due: Date.now() }; };
  const nextSession = (evidence: string, status?: string) => {
    const sessions = s.sessions.map((session, i) => i === s.sessionIndex ? { ...session, ...(status ? { status } : {}), evidence } : session);
    const sessionIndex = s.sessionIndex + 1;
    queue(sessionIndex < sessions.length ? "observeSession" : "deleteUser");
    Object.assign(change, { sessions, sessionIndex, mutationUncertain: false, code: evidence });
  };
  if (destructivePhase(s.phase)) {
    // Every unsuccessful mutation result goes through GET, including malformed
    // acknowledgements. Never blindly replay a possibly submitted mutation.
    queue(observationPhase(s.phase));
    change.code = "mutation_outcome_unknown";
    change.mutationUncertain = true;
    if (s.phase === "revokeSession" && r.state === "session_revoked" && r.code === "exact_session_revoked" && r.httpStatus === 200)
      nextSession("exact_session_revoked", "revoked");
    else if (s.phase === "deleteUser" && r.state === "acknowledgement" && r.code === "user_delete_acknowledged_observation_required" && r.httpStatus === 200)
      Object.assign(change, { userDeleteAcknowledged: true, code: "delete_acknowledged_observation_required" });
  } else if (r.state === "unknown") {
    const exhausted = s.attempts >= MAX_ATTEMPTS || s.claims >= MAX_EXECUTION_CLAIMS;
    Object.assign(change, { state: exhausted ? "exhausted" : "retry", code: "observation_unknown", due: Date.now() + retryDelay(s.attempts, Math.random()) });
  } else if (s.phase === "inventoryUser" && r.state === "observed" && r.code === "user_bound" && r.httpStatus === 200) {
    queue("inventoryGoogle"); change.code = "user_observed";
  } else if (s.phase === "inventorySessions" && r.state === "observed" && r.code === "sessions_observed" && r.httpStatus === 200 && r.sessions) {
    const page = r.sessions, ids = new Set(s.sessions.map(x => x.id));
    const valid = page.length <= 32 && page.every(x => /^sess_[A-Za-z0-9]{1,250}$/.test(x.id) && statuses.includes(x.status) && !ids.has(x.id)) &&
      new Set(page.map(x => x.id)).size === page.length && (page.length === 32 ? r.nextOffset === s.offset + 32 : r.nextOffset === undefined);
    if (valid) {
      change.sessions = [...s.sessions, ...page];
      if (r.nextOffset !== undefined && r.nextOffset >= 256) change.code = "inventory_limit";
      else {
        queue(r.nextOffset !== undefined ? "inventorySessions" : change.sessions.length ? "observeSession" : "deleteUser");
        Object.assign(change, { offset: r.nextOffset ?? s.offset, inventoryComplete: r.nextOffset === undefined, code: "sessions_observed" });
      }
    } else change.code = "inventory_changed";
  } else if (s.phase === "observeSession") {
    if (r.state === "absence_observed" && r.code === "session_absent_not_revoked" && r.httpStatus === 404) nextSession("absence_not_revocation");
    else if (r.state === "observed" && r.code === "session_bound" && r.httpStatus === 200 && r.sessionStatus && statuses.includes(r.sessionStatus)) {
      if (terminal(r.sessionStatus)) nextSession("terminal_observed_not_revocation", r.sessionStatus);
      else if (s.mutationUncertain) change.code = "session_mutation_unresolved";
      else { queue("revokeSession"); change.code = "session_requires_revocation"; }
    }
  } else if (s.phase === "observeUser") {
    if (r.state === "absence_observed" && r.code === "user_absent" && r.httpStatus === 404)
      Object.assign(change, { state: "observed", userAbsenceObserved: true, mutationUncertain: false, code: "bounded_scope_observed_operator_required" });
    else if (r.state === "observed" && r.code === "user_bound" && r.httpStatus === 200) change.code = "user_mutation_unresolved";
  }
  await ctx.db.patch(s._id, change);
  if (change.state === "queued" || change.state === "retry") await ctx.scheduler.runAt(change.due!, internal.clerkExecution.run, { execution: s._id });
  await publishIntent(ctx, s.request);
  return true;
} });

export const run = internalAction({ args: { execution: v.id("deletionClerkExecutions") }, handler: async (ctx, { execution }): Promise<void> => {
  const s: Row | null = await ctx.runMutation(internal.clerkExecution.claim, { execution });
  if (!s) return;
  const args = { execution, owner: s.owner, fence: s.fence };
  const snapshot = executionSnapshot(s);
  const authorize = async () => ctx.runQuery(internal.clerkExecution.authorized, { ...args, phase: s.phase,
    snapshot,
    ...(s.googleIndex === undefined ? {} : { googleIndex: s.googleIndex }) });
  if (!await authorize()) return;
  const googleInput = () => ({ enabled: googleExecutionEnabled(), binding: { ...JSON.parse(s.config), ...JSON.parse(s.googleConfig!),
    owner: s.owner, subject: s.subject }, credential: process.env.CLERK_DELETION_SECRET_KEY ?? "", fetch, authorize });
  if (googlePhase(s.phase)) {
    const result = await googleDeletionTransport({ ...googleInput(), operation: s.phase === "revokeGoogle" ? "revoke" : "inventory",
      ...(s.phase === "revokeGoogle" ? { accounts: s.googleAccounts, target: s.googleAccounts?.[s.googleIndex ?? -1] } : {}) });
    await ctx.runMutation(internal.clerkExecution.finishGoogle, { ...args, snapshot, result });
    return;
  }
  const clerkAuthorize = async () => {
    if (!await authorize()) return false;
    // Inventory uses metadata only. It must never refresh a token after acknowledgement.
    const r = await googleDeletionTransport({ ...googleInput(), operation: "inventory" });
    if (r.state !== "inventory" || r.code !== "google_inventory_observed" || r.httpStatus !== 200 || !r.accounts ||
        !s.googleAccounts || !sameAccounts(r.accounts, s.googleAccounts)) {
      await ctx.runMutation(internal.clerkExecution.invalidateGoogleProof, args);
      return false;
    }
    // Last await before Clerk dispatch: recheck the exact fence and all prerequisites.
    return authorize();
  };
  const operations: Partial<Record<Row["phase"], ClerkOperation>> = { inventoryUser: "getUser", inventorySessions: "listSessions",
    observeSession: "getSession", revokeSession: "revokeSession", deleteUser: "deleteUser", observeUser: "getUser" };
  const result = await clerkDeletionTransport({ enabled: clerkExecutionEnabled(), binding: { ...JSON.parse(s.config), owner: s.owner, subject: s.subject },
    operation: operations[s.phase]!, credential: process.env.CLERK_DELETION_SECRET_KEY ?? "", fetch,
    ...(s.phase === "inventorySessions" ? { offset: s.offset } : {}),
    ...(["observeSession", "revokeSession"].includes(s.phase) ? { sessionId: s.sessions[s.sessionIndex]?.id } : {}),
    appleDispositionRevision: `${s.appleFence}`, authorize: clerkAuthorize });
  await ctx.runMutation(internal.clerkExecution.finish, { ...args, snapshot, result });
} });

export const expire = internalMutation({ args: fenceArgs, handler: async (ctx, args) => {
  const s = await ctx.db.get(args.execution);
  if (!s || s.owner !== args.owner || s.fence !== args.fence || s.state !== "running" || s.leaseUntil === undefined || s.leaseUntil > Date.now()) return;
  if (s.phase === "revokeGoogle") {
    await invalidateGoogle(ctx, s);
    await ctx.db.patch(s._id, { state: "blocked", fence: s.fence + 1, leaseUntil: undefined, mutationUncertain: true,
      code: "google_revoke_unresolved", updatedAt: Date.now() });
    await publishIntent(ctx, s.request);
    return;
  }
  if (!await prerequisites(ctx, s)) await invalidateGoogle(ctx, s);
  const mutating = destructivePhase(s.phase), exhausted = s.claims >= MAX_EXECUTION_CLAIMS || (!mutating && s.attempts >= MAX_ATTEMPTS);
  const due = Date.now() + retryDelay(s.attempts, Math.random());
  await ctx.db.patch(s._id, { state: exhausted ? "exhausted" : "retry", fence: s.fence + 1, leaseUntil: undefined, due,
    code: "lease_expired_unknown", updatedAt: Date.now(), ...(mutating ? { phase: observationPhase(s.phase), attempts: 0, mutationUncertain: true } : {}) });
  if (!exhausted && clerkExecutionEnabled()) await ctx.scheduler.runAt(due, internal.clerkExecution.run, { execution: s._id });
} });

// Invoked by existing deletion recovery cron; no additional periodic workload.
export const recover = internalMutation({ args: {}, handler: async ctx => {
  if (!clerkExecutionEnabled()) return;
  for (const state of ["queued", "retry", "running"] as const) {
    const rows = await ctx.db.query("deletionClerkExecutions").withIndex("by_state_due", q => q.eq("state", state).lte("due", Date.now())).take(16);
    for (const s of rows) {
      if (state === "running") await ctx.scheduler.runAfter(0, internal.clerkExecution.expire, { execution: s._id, owner: s.owner, fence: s.fence });
      else await ctx.scheduler.runAfter(0, internal.clerkExecution.run, { execution: s._id });
    }
  }
} });

export const inventory = internalQuery({ args: exactArgs, handler: async (ctx, { id, owner }) => {
  await exactRequest(ctx, id, owner);
  return ctx.db.query("deletionClerkExecutions").withIndex("by_request", q => q.eq("request", id)).unique();
} });

export const resolveGoogle = internalMutation({ args: { ...fenceArgs, stageFence: v.number(), googleConfig: v.string(),
  evidence: v.string(), disposition: appleDisposition, target: v.optional(v.object({ externalAccountId: v.string(), providerUserId: v.string() })) },
  handler: async (ctx, args) => {
    const s = await ctx.db.get(args.execution);
    if (!s || s.owner !== args.owner || s.fence !== args.fence || s.state !== "blocked" || s.stageFence !== args.stageFence ||
        !validEvidence(args.evidence) || s.googleConfig !== args.googleConfig || !await prerequisites(ctx, s) ||
        s.claims >= MAX_EXECUTION_CLAIMS) fail(409, "Resolve the exact non-running Google scope and current prerequisites.");
    let accounts = s.googleAccounts, index = s.googleIndex ?? 0, phase: Row["phase"];
    let notApplicable = false;
    if (args.disposition === "historical_non_applicability_verified") {
      if (s.phase !== "inventoryGoogle" || s.code !== "google_empty_inventory_operator_required" ||
          accounts?.length !== 0 || args.target) fail(409, "Observed empty Google inventory required.");
      notApplicable = true; phase = "verifyGoogleInventory";
    } else {
      const target = accounts?.[index];
      if (s.phase !== "revokeGoogle" || s.code !== "google_revoke_unresolved" || !s.mutationUncertain ||
          !target || target.acknowledged || !args.target || !sameAccounts([target], [args.target])) fail(409, "Exact ambiguous Google target required.");
      accounts = accounts!.map((a, i) => i === index ? { ...a, acknowledged: true, evidence: args.evidence } : a);
      index++; phase = "verifyGoogleInventory";
    }
    // Preserve budgets. Attestation resolves one target, not an entire inventory.
    await ctx.db.patch(s._id, { state: "queued", phase, googleAccounts: accounts, googleIndex: index, googleNotApplicable: notApplicable,
      ...(notApplicable ? { googleOperatorEvidence: args.evidence } : {}),
      googleComplete: false, googleEvidence: undefined, mutationUncertain: false, fence: s.fence + 1, due: Date.now(), updatedAt: Date.now() });
    await ctx.db.patch(s.request, { googleStatus: "pending", googleEvidence: undefined, updatedAt: Date.now() });
    await ctx.scheduler.runAfter(0, internal.clerkExecution.run, { execution: s._id });
    await publishIntent(ctx, s.request);
} });

// Explicit terminal release after the generic Clerk stage was reopened. This is
// evidence-backed reconciliation of possible remote effects, NOT cancellation,
// automatic completion or authority to repeat a mutation.
export const releaseInvalidated = internalMutation({ args: { ...fenceArgs, stageFence: v.number(), automationRevision: v.number(),
  evidence: v.string(), remoteEffects: v.literal("reconciled") }, handler: async (ctx, args) => {
  const s = await ctx.db.get(args.execution);
  if (!s || s.owner !== args.owner || s.fence !== args.fence || s.state === "running" || s.state === "manual" || !validEvidence(args.evidence))
    fail(409, "Reconcile the exact non-running invalidated execution first.");
  const d = await exactRequest(ctx, s.request, args.owner), stage = await ctx.db.get(s.stage);
  if (d.subject !== s.subject || d.requestedAt !== s.requestedAt || d.automationRevision !== args.automationRevision || d.clerk ||
      !stage || stage.request !== d._id || stage.owner !== s.owner || stage.kind !== "clerk" || stage.target !== s.subject ||
      stage.state !== "manual" || stage.code !== "operator_evidence" || stage.fence !== args.stageFence || stage.fence <= s.stageFence)
    fail(409, "Current stage invalidation revision does not match.");
  await invalidateGoogle(ctx, s);
  await ctx.db.patch(s._id, { state: "manual", fence: s.fence + 1, leaseUntil: undefined, evidence: args.evidence,
    code: "stage_invalidation_reconciled", updatedAt: Date.now() });
  await publishIntent(ctx, d._id);
} });

// Read-only recovery after an ambiguous mutation. Never rearms POST/DELETE or
// resets the observation/total budgets; configuration changes need reconciliation.
export const observeAgain = internalMutation({ args: fenceArgs, handler: async (ctx, args) => {
  const s = await ctx.db.get(args.execution);
  if (!s || s.owner !== args.owner || s.fence !== args.fence || s.state !== "blocked" ||
      !["observeSession", "observeUser"].includes(s.phase) || s.attempts >= MAX_ATTEMPTS || s.claims >= MAX_EXECUTION_CLAIMS ||
      !await prerequisites(ctx, s)) fail(409, "Exact observation cannot be resumed.");
  await ctx.db.patch(s._id, { state: "queued", fence: s.fence + 1, due: Date.now(), updatedAt: Date.now() });
  await ctx.scheduler.runAfter(0, internal.clerkExecution.run, { execution: s._id });
} });

// Resume metadata only. A Google revoke exception cannot use this entry point.
export const observeGoogleAgain = internalMutation({ args: fenceArgs, handler: async (ctx, args) => {
  const s = await ctx.db.get(args.execution);
  if (!s || s.owner !== args.owner || s.fence !== args.fence || s.state !== "blocked" ||
      !["inventoryGoogle", "verifyGoogleInventory"].includes(s.phase) || s.attempts >= MAX_ATTEMPTS ||
      s.claims >= MAX_EXECUTION_CLAIMS || s.phase === "inventoryGoogle" &&
        (s.mutationUncertain || s.googleAccounts?.some(a => a.acknowledged)) ||
      !await prerequisites(ctx, s)) fail(409, "Exact Google inventory cannot be resumed.");
  await ctx.db.patch(s._id, { state: "queued", fence: s.fence + 1, due: Date.now(), updatedAt: Date.now() });
  await ctx.scheduler.runAfter(0, internal.clerkExecution.run, { execution: s._id });
} });

// Explicit operator acceptance of residual/session scope, never automatic global proof.
export const reconcile = internalMutation({ args: { ...fenceArgs, evidence: v.string() }, handler: async (ctx, args) => {
  const s = await ctx.db.get(args.execution);
  if (!s || s.owner !== args.owner || s.fence !== args.fence || s.state !== "observed" || !s.inventoryComplete || !s.userAbsenceObserved ||
      s.sessionIndex !== s.sessions.length || s.sessions.some(x => !x.evidence) || !validEvidence(args.evidence) || !await prerequisites(ctx, s))
    fail(409, "Reconcile the exact observed Clerk scope and prerequisites first.");
  await ctx.db.patch(s._id, { state: "manual", fence: s.fence + 1, evidence: args.evidence, code: "operator_scope_accepted", updatedAt: Date.now() });
  await ctx.db.patch(s.request, { clerk: true, clerkEvidence: args.evidence, updatedAt: Date.now() });
  await manualStage(ctx, (await ctx.db.get(s.stage))!, args.evidence);
  await publishIntent(ctx, s.request);
} });
