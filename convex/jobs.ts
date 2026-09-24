import { v } from "convex/values";
import { internalAction } from "./_generated/server";
import { internal } from "./_generated/api";
import { MAX_AUDIO } from "./limits";
import { GeminiFailure, safeFailure, transcribeAudio } from "./gemini";
import { billableEnabled, billablePausedMessage } from "./billable";
import { refreshBilling } from "./revenuecat";
import { enforcementEnabled } from "./billingPolicy";

export const transcribe = internalAction({
  args: { id: v.id("recordings") },
  handler: async (ctx, { id }) => {
    const job = await ctx.runMutation(internal.recordings.claimJob, { id });
    if (!job) return;
    let work;
    let fileDeleted = false;
    let generationStarted = false;
    let generationFinished = false;
    try {
      if (!billableEnabled()) throw new GeminiFailure(billablePausedMessage);
      if (enforcementEnabled() && !job.subject) throw new GeminiFailure("Upload this recording again to verify billing.");
      const revision = await refreshBilling(ctx, { tokenIdentifier: job.owner, subject: job.subject ?? "" });
      const audio = await ctx.storage.get(job.audio);
      if (!audio || audio.size === 0 || audio.size > MAX_AUDIO) {
        throw new GeminiFailure("Stored audio is missing or outside the 18 MiB limit. Upload a valid recording again.");
      }
      await ctx.runMutation(internal.recordings.authorizeJob, { id, revision });
      work = await ctx.runMutation(internal.deletion.beginWork, { owner: job.owner, kind: "gemini" });
      const result = await transcribeAudio(audio, job.mimeType, {
        checkActive: () => ctx.runQuery(internal.deletion.check, { owner: job.owner }),
        uploaded: file => ctx.runMutation(internal.deletion.track, { id: work!, file }),
        deleted: () => { fileDeleted = true; },
        generationStarted: async () => {
          generationStarted = true;
          await ctx.runMutation(internal.deletion.generation, { id: work!, phase: "started" });
        },
        generationFinished: async () => {
          await ctx.runMutation(internal.deletion.generation, { id: work!, phase: "finished" });
          generationFinished = true;
        },
      });
      await ctx.runMutation(internal.recordings.finishJob, { id, transcript: result.text, error: result.warning });
    } catch (error) {
      await ctx.runMutation(internal.recordings.finishJob, { id, error: safeFailure(error) });
    } finally {
      if (work) await ctx.runMutation(internal.deletion.finishWork, {
        id: work, ambiguous: !fileDeleted || (generationStarted && !generationFinished), fileDeleted,
      });
    }
  },
});
