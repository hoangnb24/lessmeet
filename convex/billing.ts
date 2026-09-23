import { v } from "convex/values";
import { internalMutation, type MutationCtx } from "./_generated/server";
import type { Doc, Id } from "./_generated/dataModel";
import { enforcementEnabled, FREE, PRO, monthlyWindow, requireBillingSetup, VERIFICATION_TTL } from "./billingPolicy";
import { fail } from "./limits";

const account = (ctx: MutationCtx, owner: string) => ctx.db.query("billingAccounts").withIndex("by_owner", q => q.eq("owner", owner)).unique();

export const beginVerification = internalMutation({
  args: { owner: v.string(), subject: v.string() },
  handler: async (ctx, { owner, subject }) => {
    requireBillingSetup();
    const previous = await account(ctx, owner);
    if (previous && previous.subject !== subject) fail(403, "Billing account identity mismatch.");
    const revision = (previous?.revision ?? 0) + 1;
    if (previous) await ctx.db.patch(previous._id, { revision, verifiedAt: undefined });
    else await ctx.db.insert("billingAccounts", { owner, subject, revision });
    return revision;
  },
});

export const applyVerification = internalMutation({
  args: { owner: v.string(), subject: v.string(), revision: v.number(), observedAt: v.number(),
    plan: v.union(v.literal("free"), v.literal("pro")), expiresAt: v.union(v.number(), v.null()), anchor: v.union(v.number(), v.null()) },
  handler: async (ctx, args) => {
    requireBillingSetup();
    const a = await account(ctx, args.owner);
    if (!a || a.subject !== args.subject || a.revision !== args.revision ||
        args.observedAt < (a.observedAt ?? 0)) fail(409, "Subscription verification was superseded. Try again.");
    if (Math.abs(Date.now() - args.observedAt) > VERIFICATION_TTL) fail(503, "Subscription verification expired. Try again.");
    // Pin the initial subscription anniversary: product switches, refunds,
    // repeated syncs and repurchases must not manufacture a fresh monthly grant.
    await ctx.db.patch(a._id, { plan: args.plan, expiresAt: args.expiresAt,
      anchor: a.anchor ?? args.anchor ?? undefined, observedAt: args.observedAt, verifiedAt: Date.now() });
    return args.revision;
  },
});

export async function verifiedAccount(ctx: MutationCtx, owner: string, revision: number | undefined) {
  requireBillingSetup();
  const a = await account(ctx, owner), now = Date.now();
  if (!a || revision === undefined || a.revision !== revision || a.verifiedAt === undefined ||
      now - a.verifiedAt > VERIFICATION_TTL || !a.plan || (a.plan === "pro" && (!a.expiresAt || a.expiresAt <= now))) {
    fail(409, "A fresh subscription verification is required. Try again.");
  }
  return a;
}
function windowFor(a: Doc<"billingAccounts">) {
  if (a.plan !== "pro") return { key: "free", end: null, limits: FREE };
  if (a.anchor === undefined) fail(503, "Subscription period is unavailable.");
  const window = monthlyWindow(a.anchor, Date.now());
  return { key: `pro:${window.start}`, end: Math.min(window.end, a.expiresAt!), limits: PRO };
}
async function bucketFor(ctx: MutationCtx, owner: string, key: string) {
  return ctx.db.query("quotaBuckets").withIndex("by_owner_window", q => q.eq("owner", owner).eq("window", key)).unique();
}

export const status = internalMutation({
  args: { revision: v.optional(v.number()) },
  handler: async (ctx, { revision }) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) fail(401, "Sign in to LessMeet first.");
    if (!enforcementEnabled()) return { userId: identity.subject, enforcement: false, plan: "development" as const,
      periodEndsAt: null, transcriptionSeconds: { limit: 0, used: 0, reserved: 0 }, questions: { limit: 0, used: 0, reserved: 0 } };
    const a = await verifiedAccount(ctx, identity.tokenIdentifier, revision);
    const window = windowFor(a), bucket = await bucketFor(ctx, a.owner, window.key);
    return { userId: identity.subject, enforcement: true, plan: a.plan!, periodEndsAt: window.end,
      transcriptionSeconds: { limit: window.limits.seconds, used: bucket?.secondsUsed ?? 0, reserved: bucket?.secondsReserved ?? 0 },
      questions: { limit: window.limits.questions, used: bucket?.questionsUsed ?? 0, reserved: bucket?.questionsReserved ?? 0 } };
  },
});

export type Reservation = { bucket: Id<"quotaBuckets">; seconds: number; questions: number };
export async function reserveQuota(ctx: MutationCtx, owner: string, revision: number | undefined, seconds: number, questions: number): Promise<Reservation | undefined> {
  if (!enforcementEnabled()) return undefined;
  const a = await verifiedAccount(ctx, owner, revision), window = windowFor(a);
  if (!Number.isSafeInteger(seconds) || seconds < 0 || !Number.isSafeInteger(questions) || questions < 0 || seconds + questions <= 0) fail(400, "Invalid usage amount.");
  let bucket = await bucketFor(ctx, owner, window.key);
  if (!bucket) {
    const id = await ctx.db.insert("quotaBuckets", { owner, window: window.key, secondsUsed: 0, secondsReserved: 0, questionsUsed: 0, questionsReserved: 0 });
    bucket = (await ctx.db.get(id))!;
  }
  if (bucket.secondsUsed + bucket.secondsReserved + seconds > window.limits.seconds ||
      bucket.questionsUsed + bucket.questionsReserved + questions > window.limits.questions) {
    fail(429, "Your AI allowance is exhausted. No AI request was started.");
  }
  await ctx.db.patch(bucket._id, { secondsReserved: bucket.secondsReserved + seconds, questionsReserved: bucket.questionsReserved + questions });
  return { bucket: bucket._id, seconds, questions };
}

// Called ONLY alongside consuming the matching recording/chat lease. Both writes
// commit in the same Convex transaction; retries or late completions cannot settle twice.
export async function settleQuota(ctx: MutationCtx, reservation: Reservation | undefined, success: boolean) {
  if (!reservation) return;
  const b = await ctx.db.get(reservation.bucket);
  if (!b || b.secondsReserved < reservation.seconds || b.questionsReserved < reservation.questions) fail(500, "Usage accounting is unavailable.");
  await ctx.db.patch(b._id, {
    secondsReserved: b.secondsReserved - reservation.seconds, questionsReserved: b.questionsReserved - reservation.questions,
    secondsUsed: b.secondsUsed + (success ? reservation.seconds : 0), questionsUsed: b.questionsUsed + (success ? reservation.questions : 0),
  });
}
