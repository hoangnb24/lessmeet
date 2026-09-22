import { v } from "convex/values";
import { internalAction } from "./_generated/server";
import { internal } from "./_generated/api";
import { MAX_AUDIO } from "./limits";
import { GeminiFailure, safeFailure, transcribeAudio } from "./gemini";
import { billableEnabled, billablePausedMessage } from "./billable";

export const transcribe = internalAction({
  args: { id: v.id("recordings") },
  handler: async (ctx, { id }) => {
    const job = await ctx.runMutation(internal.recordings.claimJob, { id });
    if (!job) return;
    try {
      if (!billableEnabled()) throw new GeminiFailure(billablePausedMessage);
      const audio = await ctx.storage.get(job.audio);
      if (!audio || audio.size === 0 || audio.size > MAX_AUDIO) {
        throw new GeminiFailure("Stored audio is missing or outside the 18 MiB limit. Upload a valid recording again.");
      }
      const result = await transcribeAudio(audio, job.mimeType);
      await ctx.runMutation(internal.recordings.finishJob, { id, transcript: result.text, error: result.warning });
    } catch (error) {
      await ctx.runMutation(internal.recordings.finishJob, { id, error: safeFailure(error) });
    }
  },
});
