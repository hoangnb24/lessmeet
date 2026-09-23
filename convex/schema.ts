import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export const message = v.object({ role: v.union(v.literal("user"), v.literal("assistant")), text: v.string() });
const reservation = v.object({ bucket: v.id("quotaBuckets"), seconds: v.number(), questions: v.number() });
export default defineSchema({
  billingAccounts: defineTable({ owner: v.string(), subject: v.string(), revision: v.number(),
    observedAt: v.optional(v.number()), verifiedAt: v.optional(v.number()),
    plan: v.optional(v.union(v.literal("free"), v.literal("pro"))),
    expiresAt: v.optional(v.union(v.number(), v.null())), anchor: v.optional(v.number()),
  }).index("by_owner", ["owner"]),
  quotaBuckets: defineTable({ owner: v.string(), window: v.string(), secondsUsed: v.number(), secondsReserved: v.number(),
    questionsUsed: v.number(), questionsReserved: v.number(),
  }).index("by_owner_window", ["owner", "window"]),
  recordings: defineTable({
    owner: v.string(),
    audio: v.id("_storage"),
    mimeType: v.string(),
    status: v.union(v.literal("queued"), v.literal("processing"), v.literal("ready"), v.literal("failed")),
    transcript: v.optional(v.string()),
    messages: v.array(message),
    error: v.optional(v.string()),
    chatLease: v.optional(v.string()),
    subject: v.optional(v.string()),
    jobDeadline: v.optional(v.number()),
    chatDeadline: v.optional(v.number()),
    transcriptionReservation: v.optional(reservation),
    chatReservation: v.optional(reservation),
  }),
});
