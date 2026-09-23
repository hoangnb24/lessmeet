import { fail } from "./limits";

export const enforcementEnabled = () => process.env.BILLING_ENFORCEMENT_ENABLED === "true";
export function requireBillingSetup() {
  if (enforcementEnabled() && process.env.REVENUECAT_ORIGINAL_USER_POLICY_CONFIRMED !== "true") {
    fail(503, "Billing setup is incomplete. The app owner must verify the original-user restore policy before enabling billing.");
  }
}
export const FREE = { seconds: 7_200, questions: 20 };
export const PRO = { seconds: 72_000, questions: 200 };
export const VERIFICATION_TTL = 30_000;
export type Entitlement = { plan: "free" | "pro"; expiresAt: number | null; anchor: number | null; observedAt: number };

// Always calculate anniversaries from the ORIGINAL day, never from February's
// clamped day. Annual purchases use precisely the same monthly windows.
export function monthlyWindow(anchor: number, now: number) {
  const start = new Date(anchor), current = new Date(now);
  const anniversary = (months: number) => {
    const month = start.getUTCMonth() + months;
    const lastDay = new Date(Date.UTC(start.getUTCFullYear(), month + 1, 0)).getUTCDate();
    return Date.UTC(start.getUTCFullYear(), month, Math.min(start.getUTCDate(), lastDay),
      start.getUTCHours(), start.getUTCMinutes(), start.getUTCSeconds(), start.getUTCMilliseconds());
  };
  let months = (current.getUTCFullYear() - start.getUTCFullYear()) * 12 + current.getUTCMonth() - start.getUTCMonth();
  if (anniversary(months) > now) months--;
  return { start: anniversary(months), end: anniversary(months + 1) };
}

function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) unavailable();
  return value as Record<string, unknown>;
}
function date(value: unknown): number {
  if (typeof value !== "string" || !/^\d{4}-\d\d-\d\dT/.test(value)) unavailable();
  const result = Date.parse(value);
  if (!Number.isFinite(result) || result <= 0) unavailable();
  return result;
}
export function unavailable(): never { fail(503, "Subscription verification is unavailable. No AI request was started; try again later."); }

// REST v1 Customer Info, NOT the client CustomerInfo or subscriber attributes.
// https://www.revenuecat.com/docs/api-v1/customer-info-model
export function parseEntitlement(value: unknown, subject: string, now: number): Entitlement {
  const root = object(value), subscriber = object(root.subscriber);
  const observedAt = root.request_date_ms;
  if (typeof observedAt !== "number" || !Number.isSafeInteger(observedAt) || Math.abs(now - observedAt) > VERIFICATION_TTL) unavailable();
  if (subscriber.original_app_user_id !== subject) {
    fail(403, "This purchase belongs to a different original account. Sign in with the original account or contact support.");
  }
  const entitlements = object(subscriber.entitlements), subscriptions = object(subscriber.subscriptions);
  const free: Entitlement = { plan: "free", expiresAt: null, anchor: null, observedAt };
  if (!Object.hasOwn(entitlements, "lessmeet_pro")) return free;
  const entitlement = object(entitlements.lessmeet_pro);
  const product = entitlement.product_identifier;
  if (product !== "com.lessmeet.app.pro.monthly" && product !== "com.lessmeet.app.pro.yearly") unavailable();
  const subscription = object(subscriptions[product]);
  // No lifetime, promotional, family-shared or unidentified environment grants.
  const expiresAt = Math.min(date(entitlement.expires_date), date(subscription.expires_date));
  const anchor = date(subscription.original_purchase_date);
  const purchasedAt = date(subscription.purchase_date);
  date(entitlement.purchase_date);
  if (anchor > purchasedAt || purchasedAt > now || anchor >= expiresAt || typeof subscription.is_sandbox !== "boolean" ||
      subscription.store !== "app_store" || subscription.ownership_type !== "PURCHASED") unavailable();
  if (subscription.is_sandbox && process.env.REVENUECAT_ALLOW_SANDBOX !== "true") {
    fail(403, "Sandbox purchases are not enabled on this server.");
  }
  if (subscription.refunded_at !== null) {
    date(subscription.refunded_at); // Missing/malformed revocation evidence fails closed.
    return free;
  }
  // unsubscribe_detected_at means cancelled renewal, NOT revoked access.
  // Grace periods are intentionally not extended beyond verified expiry.
  return expiresAt <= now ? free : { plan: "pro", expiresAt, anchor, observedAt };
}
