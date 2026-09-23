import { v } from "convex/values";
import { internalMutation, internalQuery, type MutationCtx, type QueryCtx } from "./_generated/server";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { byteLength, CHAT_TIMEOUT, fail, JOB_TIMEOUT, MAX_HISTORY, MAX_REPLY, MAX_TRANSCRIPT, MAX_TURNS, validateMessage } from "./limits";
import { reserveQuota, settleQuota, verifiedAccount } from "./billing";
import { enforcementEnabled } from "./billingPolicy";

async function owned(ctx: QueryCtx | MutationCtx, rawId: string) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) fail(401, "Sign in to LessMeet first.");
  const id = ctx.db.normalizeId("recordings", rawId);
  const recording = id ? await ctx.db.get(id) : null;
  if (!recording || recording.owner !== identity.tokenIdentifier) fail(404, "Recording not found.");
  return recording;
}

export const create = internalMutation({
  args: { audio: v.id("_storage"), mimeType: v.string(), seconds: v.optional(v.number()), revision: v.optional(v.number()) },
  handler: async (ctx, args): Promise<Id<"recordings">> => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) fail(401, "Sign in to LessMeet first.");
    const transcriptionReservation = await reserveQuota(ctx, identity.tokenIdentifier, args.revision, args.seconds ?? 0, 0);
    const id = await ctx.db.insert("recordings", {
      owner: identity.tokenIdentifier, subject: identity.subject, audio: args.audio, mimeType: args.mimeType,
      status: "queued", messages: [], transcriptionReservation, jobDeadline: Date.now() + JOB_TIMEOUT,
    });
    await ctx.scheduler.runAfter(0, internal.jobs.transcribe, { id });
    await ctx.scheduler.runAfter(JOB_TIMEOUT, internal.recordings.expireJob, { id });
    return id;
  },
});

export const get = internalQuery({
  args: { id: v.string() },
  handler: async (ctx, { id }) => {
    const r = await owned(ctx, id);
    return { recordingId: r._id, status: r.status, transcript: r.transcript, messages: r.messages, error: r.error };
  },
});

export const claimJob = internalMutation({
  args: { id: v.id("recordings") },
  handler: async (ctx, { id }) => {
    const r = await ctx.db.get(id);
    if (!r || r.status !== "queued") return null;
    await ctx.db.patch(id, { status: "processing" });
    return { audio: r.audio, mimeType: r.mimeType, owner: r.owner, subject: r.subject };
  },
});

// Scheduled jobs have no caller JWT. The owner/subject comes only from the
// server-created recording; old development jobs cannot bypass new enforcement.
export const authorizeJob = internalMutation({
  args: { id: v.id("recordings"), revision: v.optional(v.number()) },
  handler: async (ctx, { id, revision }) => {
    const r = await ctx.db.get(id);
    if (!r || r.status !== "processing" || (r.jobDeadline !== undefined && Date.now() >= r.jobDeadline)) fail(409, "Transcription expired.");
    if (enforcementEnabled()) {
      const a = await verifiedAccount(ctx, r.owner, revision);
      if (!r.transcriptionReservation) fail(409, "Upload this recording again to reserve an AI allowance.");
      const bucket = await ctx.db.get(r.transcriptionReservation.bucket);
      if (!bucket || bucket.owner !== r.owner || (bucket.window === "free") !== (a.plan === "free")) fail(409, "Subscription changed. Upload this recording again.");
    }
  },
});

export const finishJob = internalMutation({
  args: { id: v.id("recordings"), transcript: v.optional(v.string()), error: v.optional(v.string()) },
  handler: async (ctx, { id, transcript, error }) => {
    const r = await ctx.db.get(id);
    if (!r || r.status !== "processing") return;
    if (r.jobDeadline !== undefined && Date.now() >= r.jobDeadline) {
      await settleQuota(ctx, r.transcriptionReservation, false);
      await ctx.db.patch(id, { status: "failed", error: "Transcription timed out. No allowance was charged.", transcriptionReservation: undefined });
      return;
    }
    if (transcript !== undefined && (!transcript.trim() || byteLength(JSON.stringify(transcript)) > MAX_TRANSCRIPT)) {
      fail(500, "Transcript exceeded the storage limit. Split the recording and try again.");
    }
    await settleQuota(ctx, r.transcriptionReservation, transcript !== undefined);
    await ctx.db.patch(id, { status: transcript === undefined ? "failed" : "ready", transcript, error, transcriptionReservation: undefined });
  },
});

export const expireJob = internalMutation({
  args: { id: v.id("recordings") },
  handler: async (ctx, { id }) => {
    const r = await ctx.db.get(id);
    if (r && (r.status === "queued" || r.status === "processing")) {
      await settleQuota(ctx, r.transcriptionReservation, false);
      await ctx.db.patch(id, { status: "failed", transcriptionReservation: undefined, error: "Transcription timed out. Try a shorter recording; this job will not retry automatically." });
    }
  },
});

export const reserveChat = internalMutation({
  args: { id: v.string(), message: v.string(), lease: v.string(), revision: v.optional(v.number()) },
  handler: async (ctx, args) => {
    const r = await owned(ctx, args.id);
    validateMessage(args.message);
    if (r.status !== "ready" || !r.transcript) fail(409, "Wait for a completed transcript before chatting.");
    if (r.chatLease) fail(409, "A reply is already in progress. Wait for it to finish.");
    // Reserve room for the entire next exchange, never silently drop history.
    if (r.messages.length >= MAX_TURNS * 2 ||
        byteLength(JSON.stringify(r.messages)) + byteLength(JSON.stringify(args.message)) + MAX_REPLY + 128 > MAX_HISTORY) {
      fail(409, "This conversation reached its size limit. No further message was sent to Gemini.");
    }
    const chatReservation = await reserveQuota(ctx, r.owner, args.revision, 0, 1);
    await ctx.db.patch(r._id, { chatLease: args.lease, chatReservation, chatDeadline: Date.now() + CHAT_TIMEOUT });
    await ctx.scheduler.runAfter(CHAT_TIMEOUT, internal.recordings.releaseChat, { id: r._id, lease: args.lease });
    return { id: r._id, transcript: r.transcript, messages: r.messages };
  },
});

export const finishChat = internalMutation({
  args: { id: v.string(), lease: v.string(), message: v.string(), text: v.string() },
  handler: async (ctx, args) => {
    const r = await owned(ctx, args.id);
    if (r.chatLease !== args.lease) fail(409, "The reply timed out and was not saved. Refresh the recording before trying again.");
    if (r.chatDeadline !== undefined && Date.now() >= r.chatDeadline) fail(409, "The reply timed out and was not saved. No allowance was charged.");
    validateMessage(args.message);
    if (!args.text.trim() || byteLength(JSON.stringify(args.text)) > MAX_REPLY) fail(502, "Reply exceeded the limit. Ask a narrower question.");
    const messages = [...r.messages, { role: "user" as const, text: args.message }, { role: "assistant" as const, text: args.text }];
    if (byteLength(JSON.stringify(messages)) > MAX_HISTORY) fail(409, "Conversation storage limit reached.");
    await settleQuota(ctx, r.chatReservation, true);
    await ctx.db.patch(r._id, { messages, chatLease: undefined, chatReservation: undefined, chatDeadline: undefined });
  },
});

export const releaseChat = internalMutation({
  args: { id: v.id("recordings"), lease: v.string() },
  handler: async (ctx, { id, lease }) => {
    const r = await ctx.db.get(id);
    if (r?.chatLease === lease) {
      await settleQuota(ctx, r.chatReservation, false);
      await ctx.db.patch(id, { chatLease: undefined, chatReservation: undefined, chatDeadline: undefined });
    }
  },
});
