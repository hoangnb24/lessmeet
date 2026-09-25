import { defineTable } from "convex/server";
import { v } from "convex/values";
export const rational = v.object({ value: v.number(), timescale: v.number() });
export const manifestValue = v.object({ version: v.literal(1), source: v.object({ sha256: v.string(), bytes: v.number(), duration: rational }), chunks: v.array(v.object({ sha256: v.string(), bytes: v.number() })) });
const reservation = v.object({ bucket: v.id("quotaBuckets"), seconds: v.number(), questions: v.number() });
export const batchTables = {
  transcriptionBatches: defineTable({ owner: v.string(), subject: v.string(), issuer: v.string(), clientBatchId: v.string(), manifestDigest: v.string(), manifest: manifestValue,
    revision: v.number(), sealed: v.boolean(), createdAt: v.number() }).index("by_owner_key", ["owner", "clientBatchId"]).index("by_owner", ["owner"]),
  transcriptionChunks: defineTable({ parent: v.id("transcriptionBatches"), owner: v.string(), index: v.number(), state: v.union(...["missing", "admitting", "uploaded", "queued", "running", "unknown", "succeeded", "failed"].map(s => v.literal(s))),
    attempt: v.number(), fence: v.number(), quota: v.number(), audio: v.optional(v.id("_storage")), uploadWork: v.optional(v.id("deletionWork")), metadata: v.optional(v.string()),
    rawText: v.optional(v.string()), admissionEvidence: v.optional(v.string()), error: v.optional(v.object({ code: v.string(), message: v.string() })) })
    .index("by_parent", ["parent"]).index("by_owner", ["owner"]).index("by_state", ["state"]).index("by_owner_state", ["owner", "state"]),
  transcriptionAttempts: defineTable({ parent: v.id("transcriptionBatches"), chunk: v.id("transcriptionChunks"), owner: v.string(), attempt: v.number(), fence: v.number(), requestId: v.string(),
    phase: v.string(), work: v.optional(v.id("deletionWork")), due: v.number(), reservation: v.optional(reservation), settled: v.boolean(), terminal: v.boolean(),
    generationFinished: v.boolean(), fileDeleted: v.boolean(), evidence: v.optional(v.string()) }).index("by_chunk", ["chunk"]).index("by_owner", ["owner"]).index("by_work", ["work"]),
  transcriptionInventory: defineTable({ key: v.literal("batch"), jobs: v.array(v.id("transcriptionAttempts")), dispatchFence: v.number(), dispatchUntil: v.number() }).index("by_key", ["key"]),
};
