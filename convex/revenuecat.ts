import type { ActionCtx } from "./_generated/server";
import { internal } from "./_generated/api";
import { enforcementEnabled, parseEntitlement, requireBillingSetup, unavailable } from "./billingPolicy";

export async function refreshBilling(ctx: ActionCtx, identity: { tokenIdentifier: string; subject: string }): Promise<number | undefined> {
  await ctx.runQuery(internal.deletion.check, { owner: identity.tokenIdentifier });
  if (!enforcementEnabled()) return undefined;
  requireBillingSetup();
  const key = process.env.REVENUECAT_SECRET_API_KEY;
  if (!key || !key.startsWith("sk_")) unavailable();
  const owner = identity.tokenIdentifier, subject = identity.subject;
  const revision = await ctx.runMutation(internal.billing.beginVerification, { owner, subject });
  const work = await ctx.runMutation(internal.deletion.beginWork, { owner, kind: "billing" });
  let responseFinished = false;
  let payload: unknown;
  try {
    const response = await fetch(`https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(subject)}`, {
      headers: { Authorization: `Bearer ${key}`, Accept: "application/json" },
      redirect: "error", signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) unavailable();
    // Bounded response, including chunked responses. Never log subscriber data or keys.
    const reader = response.body?.getReader();
    if (!reader) unavailable();
    const chunks: Uint8Array[] = []; let size = 0;
    try {
      while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        size += chunk.value.length;
        if (size > 512 * 1024) { await reader.cancel(); unavailable(); }
        chunks.push(chunk.value);
      }
    } finally { reader.releaseLock(); }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    payload = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    responseFinished = true;
  } catch { unavailable(); }
  finally { await ctx.runMutation(internal.deletion.finishWork, { id: work, ambiguous: !responseFinished }); }
  const entitlement = parseEntitlement(payload, subject, Date.now());
  return ctx.runMutation(internal.billing.applyVerification, { owner, subject, revision, ...entitlement });
}
