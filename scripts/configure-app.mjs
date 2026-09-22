import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";
import { execFileSync } from "node:child_process";

// Copy ONLY public client configuration; never source .env.local as shell code.
const local = existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const plist = process.argv[2];
if (!plist) throw new Error("Expected the app Info.plist path.");
for (const [variable, property] of [
  ["CLERK_PUBLISHABLE_KEY", "ClerkPublishableKey"],
  ["CONVEX_SITE_URL", "ConvexSiteURL"],
]) {
  const value = (process.env[variable] ?? local[variable] ?? "").trim();
  if (!value) continue;
  if (variable === "CLERK_PUBLISHABLE_KEY" && !/^pk_(test|live)_[A-Za-z0-9+/=]+$/.test(value)) {
    throw new Error("Only a Clerk Publishable Key may be bundled. Never supply a secret key.");
  }
  if (variable === "CONVEX_SITE_URL" && !/^https:\/\/[a-z0-9-]+\.convex\.site\/?$/.test(value)) {
    throw new Error("Expected the public HTTPS Convex site URL.");
  }
  execFileSync("/usr/libexec/PlistBuddy", ["-c", `Add :${property} string ${value}`, plist]);
}
