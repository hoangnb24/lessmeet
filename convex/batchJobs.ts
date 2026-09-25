import { v } from "convex/values";
import { internalAction } from "./_generated/server";
import { internal } from "./_generated/api";
import { refreshBilling } from "./revenuecat";
import { transcribeBatchAudio } from "./gemini";
import { batchMedia } from "./batchMedia";

export const dispatch = internalAction({ args: {}, handler: async ctx => {
  const lease = await ctx.runMutation(internal.batches.beginDispatch, {});
  if (!lease) return;
  let drained = false;
  try {
    const revision = await refreshBilling(ctx, { tokenIdentifier: lease.owner, subject: lease.subject });
    const result = await ctx.runMutation(internal.batches.claim, { owner: lease.owner, dispatchFence: lease.fence, revision });
    drained = result?.drained ?? false;
  } catch { /* No provider submission; bounded cron retries verification, never generation. */ }
  finally { await ctx.runMutation(internal.batches.endDispatch, { fence: lease.fence, drained }); }
} });
export const run = internalAction({ args: { id: v.id("transcriptionAttempts"), fence: v.number() }, handler: async (ctx, args) => {
  const job = await ctx.runMutation(internal.batches.job, args);
  if (!job) return;
  let rawText: string | undefined, intent = false, fileDeleted = false;
  try {
    const audio = await ctx.storage.get(job.audio);
    if (!audio) throw new Error("Missing admitted audio");
    batchMedia(await audio.arrayBuffer(), job.duration);
    await ctx.runMutation(internal.batches.phase, { ...args, phase: "uploading" });
    intent = true;
    const result = await transcribeBatchAudio(audio, {
      checkActive: () => ctx.runQuery(internal.deletion.check, { owner: job.owner }),
      uploaded: file => ctx.runMutation(internal.deletion.track, { id: job.work!, file }),
      deleted: () => { fileDeleted = true; },
      generationStarted: () => ctx.runMutation(internal.batches.phase, { ...args, phase: "generating" }),
      generationFinished: () => ctx.runMutation(internal.batches.phase, { ...args, phase: "finished" }),
    });
    rawText = result.text;
  } catch { /* Typed durable phase, not an exception string, establishes known vs unknown. */ }
  await ctx.runMutation(internal.batches.finish, { ...args, rawText, known: !intent || fileDeleted, fileDeleted: !intent || fileDeleted });
} });
