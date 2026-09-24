import { v, type Infer } from "convex/values";

// Inventory observations only: none of these states is provider deletion success.
export const provider = v.union(v.literal("clerk"), v.literal("revenuecat"));
export const phase = v.union(v.literal("user"), v.literal("sessions"), v.literal("customer"), v.literal("aliases"));
export const externalAccount = v.object({ id: v.string(), provider: v.string(), providerUserId: v.string() });
export const session = v.object({ id: v.string(), status: v.string() });
export const codes = ["inventory_observed", "apple_provenance_unverified", "alias_ownership_unverified",
  "config_unverified", "config_changed", "identity_mismatch", "instance_mismatch", "project_mismatch",
  "missing_secret", "provider_rejected", "provider_temporary", "transport_unknown", "malformed_response",
  "resource_absent_inventory_unavailable", "pagination_changed", "pagination_limit", "invalid_continuation",
  "attempts_exhausted", "lease_expired_unknown", "disabled"] as const;
export type Code = typeof codes[number];
export const pageResult = v.object({
  state: v.union(v.literal("page"), v.literal("blocked"), v.literal("retry")), code: v.string(),
  externalAccounts: v.optional(v.array(externalAccount)), sessions: v.optional(v.array(session)),
  aliases: v.optional(v.array(v.string())), next: v.optional(v.string()),
  retryAfterMs: v.optional(v.number()),
});
export type PageResult = Infer<typeof pageResult>;
export const PAGE_SIZE = 32;
export const MAX_PAGES = 8;
export const MAX_ITEMS = PAGE_SIZE * MAX_PAGES;
export const MAX_CLAIMS = 64;
export type Binding = { revision: string; issuer: string; instance: string; wireVersion: string; project?: string };
export type Target = { provider: "clerk" | "revenuecat"; owner: string; subject: string; config: string;
  phase: Infer<typeof phase>; cursor: string };
