import { v } from "convex/values";
import { internalAction, internalMutation, internalQuery, type MutationCtx, type QueryCtx } from "./_generated/server";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { classification, exactRequest } from "./deletionAutomationState";
import { MAX_ATTEMPTS, retryDelay } from "./deletionAdapter";
import { contactBinding, notificationsEnabled, payloadFor, readContact, relayEmail, sendConfig,
  sendNotification, SEND_LEASE_MS, validEmail, validProviderId, WINDOW_MS } from "./notificationAdapter";

const requestArgs = { id: v.id("deletions"), owner: v.string() };
const sendArgs = { id: v.id("deletionSends"), owner: v.string() };
const terminal = (s: Doc<"deletionSends">) => s.state === "pending" || s.state === "exception";
async function contactFor(ctx: QueryCtx | MutationCtx, id: Id<"deletions">) {
  return ctx.db.query("deletionContacts").withIndex("by_request", q => q.eq("request", id)).unique();
}
async function sendFor(ctx: QueryCtx | MutationCtx, id: Id<"deletions">) {
  return ctx.db.query("deletionSends").withIndex("by_request", q => q.eq("request", id)).unique();
}
async function ready(ctx: QueryCtx | MutationCtx, d: Doc<"deletions">) {
  const intent = await ctx.db.query("deletionOutbox").withIndex("by_request", q => q.eq("request", d._id)).unique();
  // Recheck authoritative flags and work classification, not merely mutable intent labels.
  if (!intent || intent.owner !== d.owner || intent.revision !== d.automationRevision ||
      intent.classification !== "scope_complete" || !intent.localComplete || !intent.providersComplete ||
      !(d.localComplete && d.clerk && d.apple && d.revenuecat && d.gemini && d.residuals) ||
      await classification(ctx, d) !== "scope_complete" ||
      await ctx.db.query("deletionWork").withIndex("by_owner", q => q.eq("owner", d.owner)).first()) return null;
  return intent;
}
function boundContact(c: Doc<"deletionContacts">, d: Doc<"deletions">) {
  const binding = contactBinding();
  return binding && c.owner === d.owner && c.subject === d.subject && c.issuer === binding.issuer &&
    c.instance === binding.instance && c.owner === `${c.issuer}|${c.subject}` &&
    c.code === "verified_primary" && validEmail(c.email) && !relayEmail(c.email);
}

// Internal inventory never exposes the address/payload to public native status.
export const inventory = internalQuery({ args: requestArgs, handler: async (ctx, { id, owner }) => {
  const d = await exactRequest(ctx, id, owner), c = await contactFor(ctx, id), s = await sendFor(ctx, id);
  const eligible = !!await ready(ctx, d);
  return { contact: c ? { code: c.code, capturedAt: c.capturedAt } : { code: "contact_missing" },
    send: s ? { id: s._id, state: s.state, delivery: s.delivery, code: s.code, attempts: s.attempts,
      fence: s.fence, due: s.due, firstAttemptAt: s.firstAttemptAt, providerId: s.providerId } : null,
    completionEligible: eligible,
    availability: !notificationsEnabled() ? "email_disabled" : !sendConfig() ? "send_config_missing" :
      !c ? "contact_missing" : !boundContact(c, d) ? (c.email ? "contact_binding" : c.code) : !eligible ? "completion_pending" : "ready" };
} });
export const contactTarget = internalQuery({ args: requestArgs, handler: async (ctx, { id, owner }) => {
  const d = await exactRequest(ctx, id, owner);
  return { subject: d.subject, existing: !!(await contactFor(ctx, id))?.email };
} });
export const captureContact = internalAction({ args: requestArgs, handler: async (ctx, args): Promise<void> => {
  if (!notificationsEnabled()) return;
  const target = await ctx.runQuery(internal.deletionNotifications.contactTarget, args);
  if (target.existing) return;
  const binding = contactBinding();
  const result = binding ? await readContact({ ...binding, owner: args.owner, subject: target.subject }) : { code: "contact_binding" };
  await ctx.runMutation(internal.deletionNotifications.saveContact, { ...args, subject: target.subject,
    issuer: binding?.issuer ?? "", instance: binding?.instance ?? "", ...result });
} });
export const saveContact = internalMutation({ args: { ...requestArgs, subject: v.string(), issuer: v.string(), instance: v.string(),
  code: v.string(), email: v.optional(v.string()) }, handler: async (ctx, args) => {
  if (!notificationsEnabled()) return;
  const d = await exactRequest(ctx, args.id, args.owner), binding = contactBinding();
  if (d.subject !== args.subject) return;
  const existing = await contactFor(ctx, d._id);
  // Once captured, never refresh/repoint a recipient, including from concurrent lookups.
  if (existing?.email || await sendFor(ctx, d._id)) return;
  const codes = ["contact_disabled", "contact_binding", "contact_secret_missing", "contact_instance_mismatch",
    "contact_subject_mismatch", "contact_missing_verified_primary", "contact_relay_exception", "contact_lookup_failed", "verified_primary"];
  let code = codes.includes(args.code) ? args.code : "contact_lookup_failed";
  let email: string | undefined;
  if (args.email !== undefined) {
    if (process.env.CLERK_CONTACT_INVENTORY_ENABLED === "true" && binding?.issuer === args.issuer && binding.instance === args.instance && args.owner === `${args.issuer}|${args.subject}` &&
        code === "verified_primary" && validEmail(args.email) && !relayEmail(args.email)) email = args.email;
    else code = "contact_binding";
  } else if (code === "verified_primary") code = "contact_missing_verified_primary";
  const value = { request: d._id, owner: d.owner, subject: d.subject, issuer: args.issuer, instance: args.instance,
    email, code, capturedAt: Date.now() };
  if (existing) await ctx.db.patch(existing._id, value); else await ctx.db.insert("deletionContacts", value);
  await ctx.scheduler.runAfter(0, internal.deletionNotifications.freeze, { id: d._id, owner: d.owner });
} });

export const freeze = internalMutation({ args: requestArgs, handler: async (ctx, { id, owner }) => {
  if (!notificationsEnabled()) return null;
  const d = await exactRequest(ctx, id, owner), existing = await sendFor(ctx, id);
  if (existing) return existing._id;
  const intent = await ready(ctx, d), c = await contactFor(ctx, id), config = sendConfig();
  if (!intent || !c || !boundContact(c, d) || !config) return null;
  const send = await ctx.db.insert("deletionSends", { request: id, intent: intent._id, revision: intent.revision,
    owner, subject: d.subject, recipient: c.email!, contact: c._id, config, payload: payloadFor(c.email!),
    completion: { localComplete: true, clerk: true, apple: true, revenuecat: true, gemini: true, residuals: true },
    key: `lessmeet-deletion/${id}/completion-v1`, createdAt: Date.now(), state: "queued", delivery: "pending",
    code: "frozen", attempts: 0, fence: 0, due: Date.now() });
  await ctx.scheduler.runAfter(0, internal.deletionNotifications.dispatch, { id: send, owner });
  return send;
} });
async function validSend(ctx: MutationCtx, s: Doc<"deletionSends">) {
  const d = await ctx.db.get(s.request), c = await ctx.db.get(s.contact);
  if (!d || d.owner !== s.owner || d.subject !== s.subject || !c || c.request !== d._id || !boundContact(c, d) ||
      c.email !== s.recipient || s.payload !== payloadFor(s.recipient) || s.config !== sendConfig() ||
      s.key !== `lessmeet-deletion/${s.request}/completion-v1`) return false;
  const intent = await ready(ctx, d);
  return !!intent && intent._id === s.intent && intent.revision === s.revision;
}
export const claim = internalMutation({ args: sendArgs, handler: async (ctx, { id, owner }) => {
  if (!notificationsEnabled()) return null;
  const s = await ctx.db.get(id), now = Date.now();
  if (!s || s.owner !== owner || terminal(s) || s.due > now || (s.state === "running" && (s.leaseUntil ?? Infinity) > now)) return null;
  const firstAttemptAt = s.firstAttemptAt ?? now;
  let code: string | undefined;
  if (!await validSend(ctx, s)) code = "send_binding_or_completion_changed";
  else if (now + SEND_LEASE_MS >= firstAttemptAt + WINDOW_MS) code = "send_window_expired";
  else if (s.attempts >= MAX_ATTEMPTS) code = "send_attempts_exhausted";
  if (code) {
    await ctx.db.patch(id, { state: "exception", code, fence: s.fence + 1, leaseUntil: undefined }); return null;
  }
  const update = { state: "running" as const, code: "sending_delivery_unknown", attempts: s.attempts + 1,
    fence: s.fence + 1, firstAttemptAt, leaseUntil: now + SEND_LEASE_MS, due: now + SEND_LEASE_MS };
  await ctx.db.patch(id, update);
  // Watchdog is committed before any HTTP side effect; cron recovers lost scheduling too.
  await ctx.scheduler.runAfter(SEND_LEASE_MS, internal.deletionNotifications.dispatch, { id, owner });
  return { ...s, ...update };
} });
export const finish = internalMutation({ args: { ...sendArgs, fence: v.number(),
  state: v.union(v.literal("pending"), v.literal("retry"), v.literal("exception")), code: v.string(),
  providerId: v.optional(v.string()), retryAfterMs: v.optional(v.number()) }, handler: async (ctx, args) => {
  const s = await ctx.db.get(args.id), now = Date.now();
  if (!s || s.owner !== args.owner || s.state !== "running" || s.fence !== args.fence || (s.leaseUntil ?? 0) <= now) return;
  const allowed = ["email_disabled", "send_config_mismatch", "send_window_expired", "send_secret_missing", "send_temporary",
    "send_concurrent", "send_conflict", "send_rejected", "send_unknown", "provider_accepted_delivery_pending"];
  let state = args.state, code = allowed.includes(args.code) ? args.code : "send_unknown";
  if (state === "pending" && (code !== "provider_accepted_delivery_pending" || !validProviderId(args.providerId))) {
    state = "retry"; code = "send_unknown";
  }
  let due = now;
  if (!await validSend(ctx, s)) { state = "exception"; code = "send_binding_or_completion_changed"; }
  if (state === "retry") {
    due += retryDelay(s.attempts, 0, args.retryAfterMs ?? 0);
    if (!Number.isSafeInteger(due) || due + SEND_LEASE_MS >= s.firstAttemptAt! + WINDOW_MS) { state = "exception"; code = "send_window_expired"; due = now; }
    else if (s.attempts >= MAX_ATTEMPTS) { state = "exception"; code = "send_attempts_exhausted"; }
  }
  await ctx.db.patch(s._id, { state, code, due, leaseUntil: undefined,
    ...(validProviderId(args.providerId) ? { providerId: args.providerId } : {}) });
  if (state === "retry") await ctx.scheduler.runAfter(due - now, internal.deletionNotifications.dispatch, { id: s._id, owner: s.owner });
} });
export const dispatch = internalAction({ args: sendArgs, handler: async (ctx, args): Promise<void> => {
  const s = await ctx.runMutation(internal.deletionNotifications.claim, args);
  if (!s) return;
  const result = await sendNotification({ config: s.config, payload: s.payload, key: s.key,
    firstAttemptAt: s.firstAttemptAt, leaseUntil: s.leaseUntil });
  await ctx.runMutation(internal.deletionNotifications.finish, { ...args, fence: s.fence, ...result });
} });
export const recover = internalMutation({ args: {}, handler: async ctx => {
  if (!notificationsEnabled()) return;
  for (const state of ["queued", "retry", "running"] as const) {
    const rows = await ctx.db.query("deletionSends").withIndex("by_state_due", q => q.eq("state", state).lte("due", Date.now())).take(32);
    for (const row of rows) await ctx.scheduler.runAfter(0, internal.deletionNotifications.dispatch, { id: row._id, owner: row.owner });
  }
} });
