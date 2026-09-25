import { v } from "convex/values";
import { internalAction } from "./_generated/server";
import { internal } from "./_generated/api";
import { refreshBilling } from "./revenuecat";
import { replyToBatchContext } from "./gemini";
import { validReply } from "./batchChatContext";

export const run = internalAction({ args: { id: v.id("batchChatOperations") }, handler: async (ctx, { id }) => {
  const job = await ctx.runMutation(internal.batchChat.claim, { id });
  if (!job) return;
  let outcome: "completed" | "failed_before_submission" | "unknown" = "failed_before_submission";
  let text: string | undefined;
  try {
    const billingRevision = await refreshBilling(ctx, { tokenIdentifier: job.owner, subject: job.subject });
    const response = await replyToBatchContext(job.context, job.history, job.question, async () => {
      const allowed = await ctx.runMutation(internal.batchChat.intent, { id, fence: job.fence, billingRevision });
      if (!allowed) throw new Error("Chat authorization no longer active");
    });
    // Match the pinned Interactions terminal-status set, never infer remote
    // termination from an SDK return or a lossy unified finish reason.
    const terminal = response.providerStatus !== undefined && ["completed", "failed", "cancelled", "incomplete"].includes(response.providerStatus);
    outcome = terminal ? "completed" : "unknown";
    if (response.providerStatus === "completed" && response.finishReason === "stop" && validReply(response.text)) text = response.text;
  } catch { /* Durable intent, not exception text, decides known-vs-unknown. */ }
  const result = { id, fence: job.fence, outcome, text };
  // Retry only persistence of the observed outcome, never the provider call.
  for (let attempt = 0; attempt < 2; attempt++) {
    try { await ctx.runMutation(internal.batchChat.finish, result); return; } catch { /* same immutable result/fence */ }
  }
  await ctx.scheduler.runAfter(0, internal.batchChat.finish, result);
} });
