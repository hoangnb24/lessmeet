import { defineTable } from "convex/server";
import { v } from "convex/values";

export const chatExchange = v.object({ clientMessageId: v.string(), contextDigest: v.string(), message: v.string(), reply: v.string() });
export const chatRequest = { batchId: v.string(), clientMessageId: v.string(), expectedContextDigest: v.string(), expectedHistoryRevision: v.number(), message: v.string() };
export const batchChatTables = {
  batchChatContexts: defineTable({ owner: v.string(), parent: v.id("transcriptionBatches"), digest: v.string(), text: v.string() })
    .index("by_parent_digest", ["parent", "digest"]).index("by_owner", ["owner"]),
  batchChats: defineTable({ owner: v.string(), parent: v.id("transcriptionBatches"), revision: v.number(), exchanges: v.array(chatExchange),
    pending: v.optional(v.id("batchChatOperations")) }).index("by_parent", ["parent"]).index("by_owner", ["owner"]),
  batchChatOperations: defineTable({ owner: v.string(), parent: v.id("transcriptionBatches"), clientMessageId: v.string(), subject: v.string(),
    expectedRevision: v.optional(v.number()), contextDigest: v.optional(v.string()), message: v.optional(v.string()), context: v.optional(v.id("batchChatContexts")), historyText: v.optional(v.string()),
    revision: v.number(), fence: v.number(), phase: v.union(v.literal("queued"), v.literal("preparing"), v.literal("intent"), v.literal("terminal")),
    state: v.union(v.literal("queued"), v.literal("running"), v.literal("unknown"), v.literal("succeeded"), v.literal("failed")),
    quota: v.union(v.literal("reserved"), v.literal("consumed"), v.literal("released"), v.literal("not_enforced")),
    reservation: v.optional(v.object({ bucket: v.id("quotaBuckets"), seconds: v.number(), questions: v.number() })),
    work: v.optional(v.id("deletionWork")), due: v.number(), deleted: v.boolean(), text: v.optional(v.string()),
    error: v.optional(v.object({ code: v.string(), message: v.string() })), evidence: v.optional(v.string()),
  }).index("by_owner_parent_key", ["owner", "parent", "clientMessageId"]).index("by_owner_deleted", ["owner", "deleted"])
    .index("by_owner", ["owner"]).index("by_work", ["work"]).index("by_state_due", ["state", "due"]),
};
