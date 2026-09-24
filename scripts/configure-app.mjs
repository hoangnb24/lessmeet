import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";
import { execFileSync } from "node:child_process";

// Copy ONLY public client configuration; never source .env.local as shell code.
const plist = process.argv[2];
if (!plist) throw new Error("Expected the app Info.plist path.");
const mode = process.argv[3] ?? "dev";
if (!["dev", "sandbox-dev", "store"].includes(mode)) throw new Error("Unknown packaging mode.");
// Signed modes use only explicitly supplied public values, never local secrets.
const local = mode === "dev" && existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const entries = [["LessMeetPackagingMode", mode]];
for (const [variable, property] of [
  ["CLERK_PUBLISHABLE_KEY", "ClerkPublishableKey"],
  ["CONVEX_SITE_URL", "ConvexSiteURL"],
  ["REVENUECAT_PUBLIC_APPLE_KEY", "RevenueCatPublicAppleKey"],
  ["LESSMEET_PRIVACY_URL", "LessMeetPrivacyURL"],
  ["LESSMEET_TERMS_URL", "LessMeetTermsURL"],
]) {
  const value = (process.env[variable] ?? local[variable] ?? "").trim();
  if (!value) {
    const internalLegal = mode === "sandbox-dev" && ["LESSMEET_PRIVACY_URL", "LESSMEET_TERMS_URL"].includes(variable);
    if (mode !== "dev" && !internalLegal) throw new Error(`Missing required public configuration: ${variable}`);
    continue;
  }
  if (variable === "CLERK_PUBLISHABLE_KEY" && !/^pk_(test|live)_[A-Za-z0-9+/=]+$/.test(value)) {
    throw new Error("Only a Clerk Publishable Key may be bundled. Never supply a secret key.");
  }
  if (variable === "CONVEX_SITE_URL" && !/^https:\/\/[a-z0-9-]+\.convex\.site\/?$/.test(value)) {
    throw new Error("Expected the public HTTPS Convex site URL.");
  }
  if (mode === "sandbox-dev" && variable === "CONVEX_SITE_URL" && value.replace(/\/$/, "") !== "https://zany-octopus-315.convex.site") {
    throw new Error("sandbox-dev requires the approved public sandbox backend.");
  }
  if (variable === "REVENUECAT_PUBLIC_APPLE_KEY" && !/^appl_[A-Za-z0-9]+$/.test(value)) {
    throw new Error("Only a public RevenueCat Apple SDK key may be bundled, never a secret key.");
  }
  if (variable === "LESSMEET_PRIVACY_URL" || variable === "LESSMEET_TERMS_URL") {
    let url;
    try { url = new URL(value); } catch { throw new Error("Expected a public HTTPS legal URL."); }
    if (url.protocol !== "https:" || !url.hostname || url.username || url.password || /[\s'"\\]/.test(value)) {
      throw new Error("Expected a public HTTPS legal URL without credentials or whitespace.");
    }
  }
  entries.push([property, value]);
}
// Store-only restrictions: URL shape does not establish deployment provenance.
// build-app additionally requires the explicit public Store approval record.
if (mode === "store") {
  const values = Object.fromEntries(entries);
  if (!values.ClerkPublishableKey.startsWith("pk_live_")) {
    throw new Error("store requires a production Clerk publishable key.");
  }
  if (values.ConvexSiteURL.replace(/\/$/, "") === "https://zany-octopus-315.convex.site") {
    throw new Error("store rejects the known development backend; a production approval is also required.");
  }
}
// Validate every field before writing anything. Never include values in errors.
if (plist !== "--check") {
  for (const [property, value] of entries) {
    try {
      execFileSync("/usr/libexec/PlistBuddy", ["-c", `Add :${property} string ${value}`, plist], { stdio: "pipe" });
    } catch { throw new Error(`Could not configure public property: ${property}`); }
  }
}
