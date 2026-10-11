import { v } from "convex/values";
import { automationEnabled } from "./deletionAdapter";
import { contactBinding, CLERK_API_VERSION } from "./notificationAdapter";

export const clerkExecutionEnabled = () => automationEnabled() && process.env.CLERK_DELETION_ENABLED === "true";
export const MAX_EXECUTION_CLAIMS = 1024;
export const executionPhase = v.union(v.literal("inventoryUser"), v.literal("inventorySessions"),
  v.literal("inventoryGoogle"), v.literal("revokeGoogle"), v.literal("verifyGoogleInventory"),
  v.literal("observeSession"), v.literal("revokeSession"), v.literal("deleteUser"), v.literal("observeUser"));
export const appleDisposition = v.union(v.literal("revocation_verified"), v.literal("historical_non_applicability_verified"));
export const executionSession = v.object({ id: v.string(), status: v.string(), evidence: v.optional(v.string()) });
export const validEvidence = (value: string) => /^[A-Za-z0-9_-]{1,100}$/.test(value);
export function clerkExecutionConfig(): string | null {
  const binding = contactBinding(), revision = process.env.CLERK_DELETION_CONFIG_REF;
  if (!binding || !revision || !validEvidence(revision)) return null;
  return JSON.stringify({ ...binding, revision, wireVersion: CLERK_API_VERSION });
}
export const destructivePhase = (phase: string) => phase === "revokeSession" || phase === "deleteUser";
export const observationPhase = (phase: string) => phase === "revokeSession" ? "observeSession" as const : "observeUser" as const;
export const googlePhase = (phase: string) => ["inventoryGoogle", "revokeGoogle", "verifyGoogleInventory"].includes(phase);
export const googleExecutionEnabled = () => clerkExecutionEnabled() && process.env.GOOGLE_DELETION_ENABLED === "true";
export function googleExecutionConfig(): string | null {
  const clerkConfig = clerkExecutionConfig(), revision = process.env.GOOGLE_DELETION_CONFIG_REF;
  const clientId = process.env.GOOGLE_DELETION_CLIENT_ID, authorizedPartyId = process.env.GOOGLE_DELETION_AUTHORIZED_PARTY_ID;
  const projectRef = process.env.GOOGLE_DELETION_PROJECT_REF;
  const client = (s: string | undefined) => !!s && /^[A-Za-z0-9_-]{1,250}\.apps\.googleusercontent\.com$/.test(s);
  if (!clerkConfig || !revision || !validEvidence(revision) || !projectRef || !validEvidence(projectRef) ||
      !client(clientId) || !client(authorizedPartyId)) return null;
  return JSON.stringify({ clerkConfig, revision, clientId, authorizedPartyId, projectRef });
}
