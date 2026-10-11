import { v } from "convex/values";
import { automationEnabled } from "./deletionAdapter";
import { contactBinding } from "./notificationAdapter";

export const executionProvider = v.union(v.literal("apple"), v.literal("revenuecat"));
export type ExecutionProvider = "apple" | "revenuecat";
export const appleIdentity = v.object({ externalAccountId: v.string(), providerUserId: v.string(), originalClientId: v.string() });
export const evidenceRef = (s: string) => /^[A-Za-z0-9_-]{1,100}$/.test(s);
export const providerExecutionEnabled = (kind: ExecutionProvider) => automationEnabled() &&
  process.env[kind === "apple" ? "APPLE_DELETION_ENABLED" : "REVENUECAT_DELETION_ENABLED"] === "true";
export function providerExecutionConfig(kind: ExecutionProvider): string | null {
  const binding = contactBinding();
  const revision = process.env[kind === "apple" ? "APPLE_DELETION_CONFIG_REF" : "REVENUECAT_DELETION_CONFIG_REF"];
  if (!binding || !revision || !evidenceRef(revision)) return null;
  if (kind === "apple") {
    const clientId = process.env.APPLE_DELETION_CLIENT_ID, teamId = process.env.APPLE_DELETION_TEAM_ID, keyId = process.env.APPLE_DELETION_KEY_ID;
    if (!clientId || !/^[A-Za-z0-9.-]{1,255}$/.test(clientId) || !teamId || !/^[A-Z0-9]{10}$/.test(teamId) || !keyId || !/^[A-Z0-9]{10}$/.test(keyId)) return null;
    return JSON.stringify({ ...binding, revision, clientId, teamId, keyId });
  }
  const project = process.env.REVENUECAT_DELETION_PROJECT_ID;
  if (!project || !/^proj[A-Za-z0-9_-]{1,100}$/.test(project)) return null;
  return JSON.stringify({ ...binding, revision, project });
}
