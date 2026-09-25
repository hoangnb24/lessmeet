import { describe, expect, it, vi } from "vitest";
import { getFunctionName } from "convex/server";
import { run } from "../../convex/batchChatJobs";
import { internal } from "../../convex/_generated/api";

const mocks = vi.hoisted(() => ({ provider: vi.fn(), billing: vi.fn() }));
vi.mock("../../convex/gemini", () => ({ replyToBatchContext: mocks.provider }));
vi.mock("../../convex/revenuecat", () => ({ refreshBilling: mocks.billing }));

describe("batch chat persistence faults (action handler, no network)", () => {
  for (const failures of [1, 2]) it(`retries only settlement after ${failures} lost persistence acknowledgments`, async () => {
    mocks.billing.mockResolvedValue(7);
    mocks.provider.mockReset().mockImplementation(async (_c, _h, _q, intent) => {
      await intent(); return { text: "Observed reply", finishReason: "stop", providerStatus: "completed" };
    });
    let finishCount = 0;
    const runMutation = vi.fn(async (ref, _args) => {
      const name = getFunctionName(ref);
      if (name === getFunctionName(internal.batchChat.claim)) return { owner: "issuer|alice", subject: "alice", fence: 1, context: "{}", history: "[]", question: "Question" };
      if (name === getFunctionName(internal.batchChat.intent)) return true;
      if (name === getFunctionName(internal.batchChat.finish)) { if (++finishCount <= failures) throw new Error("Synthetic persistence transport loss"); return; }
      throw new Error("Unexpected mutation");
    });
    const runAfter = vi.fn();
    const handler = (run as unknown as { _handler: (ctx: unknown, args: unknown) => Promise<void> })._handler;
    await handler({ runMutation, scheduler: { runAfter } }, { id: "synthetic-op" });
    expect(mocks.provider).toHaveBeenCalledTimes(1);
    const finishes = runMutation.mock.calls.filter(([ref]) => getFunctionName(ref) === getFunctionName(internal.batchChat.finish));
    expect(finishes).toHaveLength(2); expect(finishes[0][1]).toEqual(finishes[1][1]);
    expect(finishes[0][1]).toMatchObject({ outcome: "completed", text: "Observed reply" });
    if (failures === 2) {
      expect(runAfter).toHaveBeenCalledTimes(1);
      expect(getFunctionName(runAfter.mock.calls[0][1])).toBe(getFunctionName(internal.batchChat.finish));
      expect(runAfter.mock.calls[0][2]).toEqual(finishes[0][1]);
    } else expect(runAfter).not.toHaveBeenCalled();
  });
  it.each(["in_progress", "requires_action", "unexpected", undefined])("does not infer termination from unified stop with status %s", async providerStatus => {
    mocks.billing.mockResolvedValue(7);
    mocks.provider.mockReset().mockImplementation(async (_c, _h, _q, intent) => {
      await intent(); return { text: "Not proven complete", finishReason: "stop", providerStatus };
    });
    const runMutation = vi.fn(async (ref, _args) => {
      const name = getFunctionName(ref);
      if (name === getFunctionName(internal.batchChat.claim)) return { owner: "issuer|alice", subject: "alice", fence: 1, context: "{}", history: "[]", question: "Question" };
      if (name === getFunctionName(internal.batchChat.intent)) return true;
    });
    await (run as unknown as { _handler: (ctx: unknown, args: unknown) => Promise<void> })._handler({ runMutation }, { id: "synthetic-op" });
    const finish = runMutation.mock.calls.find(([ref]) => getFunctionName(ref) === getFunctionName(internal.batchChat.finish))!;
    expect(finish[1]).toMatchObject({ outcome: "unknown", text: undefined }); expect(mocks.provider).toHaveBeenCalledTimes(1);
  });
});
