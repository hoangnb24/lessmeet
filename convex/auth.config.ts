import type { AuthConfig } from "convex/server";

const domain = process.env.CLERK_JWT_ISSUER_DOMAIN;
if (!domain || !/^https:\/\/[a-zA-Z0-9.-]+\/?$/.test(domain)) {
  throw new Error("Set CLERK_JWT_ISSUER_DOMAIN to this app's Clerk Frontend API URL before deploying.");
}

export default {
  providers: [{ domain, applicationID: "convex" }],
} satisfies AuthConfig;
