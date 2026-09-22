import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export const message = v.object({ role: v.union(v.literal("user"), v.literal("assistant")), text: v.string() });
export default defineSchema({
  recordings: defineTable({
    owner: v.string(),
    audio: v.id("_storage"),
    mimeType: v.string(),
    status: v.union(v.literal("queued"), v.literal("processing"), v.literal("ready"), v.literal("failed")),
    transcript: v.optional(v.string()),
    messages: v.array(message),
    error: v.optional(v.string()),
    chatLease: v.optional(v.string()),
  }),
});
