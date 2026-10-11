// Fixed origins, no SDK retries, no provider response/error logging.
export const SENDER = "notifications@lessmeet.2m0r.com";
export const CLERK_API_VERSION = "2026-05-12";
export const validProviderId = (id: unknown): id is string => typeof id === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id);
export const WINDOW_MS = 24 * 3600_000;
export const SEND_TIMEOUT_MS = 20_000;
export const SEND_LEASE_MS = 90_000;
export const notificationsEnabled = () => process.env.DELETION_EMAIL_ENABLED === "true" &&
  process.env.DELETION_CONTACT_RETENTION_APPROVED === "true";
export const contactCaptureEnabled = () => process.env.CLERK_CONTACT_INVENTORY_ENABLED === "true" &&
  process.env.DELETION_CONTACT_RETENTION_APPROVED === "true";
export function sendConfig() {
  const ref = process.env.RESEND_DELETION_CONFIG_REF;
  return ref && /^[A-Za-z0-9_-]{1,100}$/.test(ref) ? ref : undefined;
}
export function contactBinding() {
  const issuer = process.env.CLERK_JWT_ISSUER_DOMAIN, instance = process.env.CLERK_CONTACT_INSTANCE_ID;
  if (!issuer || !/^https:\/\/[a-zA-Z0-9.-]+$/.test(issuer) || !instance || !/^ins_[A-Za-z0-9]+$/.test(instance) ||
      process.env.CLERK_CONTACT_ISSUER !== issuer) return null;
  return { issuer, instance };
}
export function validEmail(email: unknown): email is string {
  return typeof email === "string" && email.length <= 254 && /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$/.test(email);
}
export const relayEmail = (email: string) => email.toLowerCase().endsWith("@privaterelay.appleid.com");
export function payloadFor(recipient: string) {
  return JSON.stringify({ from: SENDER, to: [recipient], subject: "LessMeet account deletion update",
    text: "The recorded scope of your LessMeet account deletion is complete. Local recordings on your devices and Apple subscriptions are unchanged. This message does not certify removal beyond that recorded scope." });
}

// Offline/manual email content only. The trusted operator supplies the saved,
// bound recipient separately. This helper does not read flags or accept a case.
export type ManualDeletionUpdate = { requestedAt: number } & (
  { kind: "received" } |
  { kind: "exception"; now: number; reason: string; nextUpdateAt: number } |
  { kind: "completion"; result: { operatorAccepted: true; evidence: string; completedScope: string; retainedLimits: string } }
);
export function manualDeletionEmailDraft(input: ManualDeletionUpdate) {
  const deadlineAt = input.requestedAt + 7 * 24 * 3600_000;
  const timestamp = (value: number) => Number.isSafeInteger(value) && value >= 0 && value <= 8.64e15;
  const text = (value: unknown): value is string => typeof value === "string" && value.trim().length > 0;
  if (!timestamp(input.requestedAt) || !timestamp(deadlineAt)) throw new Error("Valid request receipt timestamp required.");
  const timing = `We received your LessMeet account deletion request on ${new Date(input.requestedAt).toISOString()}. Normal cases complete within 7 calendar days, by ${new Date(deadlineAt).toISOString()}.`;
  const limits = "Local recordings on your devices and Apple subscriptions are unchanged. This update does not certify removal of all copies or legal compliance.";
  let update: string;
  if (input.kind === "received") update = "We will use email for status and completion updates. If an exception occurs, we will explain the reason and give the next update time.";
  else if (input.kind === "exception") {
    if (!text(input.reason) || !timestamp(input.now) || input.now < input.requestedAt ||
        !timestamp(input.nextUpdateAt) || input.nextUpdateAt <= input.now) throw new Error("Exception reason and future next update required.");
    update = `Exception: ${input.reason.trim()} Next email update by ${new Date(input.nextUpdateAt).toISOString()}. Deletion remains pending for the unresolved scope.`;
  } else if (input.kind === "completion") {
    const r = input.result;
    if (!r || r.operatorAccepted !== true || !text(r.evidence) || !/^[A-Za-z0-9_-]{1,100}$/.test(r.evidence) ||
        !text(r.completedScope) || !text(r.retainedLimits)) throw new Error("Explicit operator-accepted scope, evidence and retained limits required.");
    update = `The accepted scope is complete: ${r.completedScope.trim()} Retained or unresolved scope and limits: ${r.retainedLimits.trim()}`;
  } else throw new Error("Manual update kind required.");
  return { subject: "LessMeet account deletion update", text: `${timing}\n\n${update}\n\n${limits}`, deadlineAt };
}
async function json(response: Response): Promise<any> {
  const reader = response.body?.getReader();
  if (!reader) throw new Error("body");
  const chunks: Uint8Array[] = []; let size = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read(); if (done) break;
      size += value.length;
      if (size > 64 * 1024) { void reader.cancel().catch(() => {}); throw new Error("size"); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
}
async function bounded<T>(operation: (signal: AbortSignal) => Promise<T>): Promise<T> {
  const controller = new AbortController(); let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([operation(controller.signal), new Promise<never>((_, reject) => {
      timer = setTimeout(() => { controller.abort(); reject(new Error("timeout")); }, SEND_TIMEOUT_MS);
    })]);
  } finally { if (timer !== undefined) clearTimeout(timer); }
}
export type ContactResult = { code: string; email?: string };
export async function readContact(input: { owner: string; subject: string; issuer: string; instance: string }): Promise<ContactResult> {
  if (!contactCaptureEnabled()) return { code: "contact_disabled" };
  const binding = contactBinding();
  if (!binding || binding.issuer !== input.issuer || binding.instance !== input.instance ||
      input.owner !== `${input.issuer}|${input.subject}` || !/^user_[A-Za-z0-9]+$/.test(input.subject)) return { code: "contact_binding" };
  const key = process.env.CLERK_CONTACT_SECRET_KEY;
  if (!key) return { code: "contact_secret_missing" };
  try {
    return await bounded(async signal => {
      const get = async (path: string) => {
        signal.throwIfAborted();
        const response = await fetch(`https://api.clerk.com/v1/${path}`, {
          method: "GET", headers: { Authorization: `Bearer ${key}`, "Clerk-API-Version": CLERK_API_VERSION }, redirect: "error", signal,
        });
        if (response.status !== 200) { void response.body?.cancel().catch(() => {}); throw new Error("rejected"); }
        return json(response);
      };
      const instance = await get("instance");
      if (instance?.object !== "instance" || instance.id !== input.instance) return { code: "contact_instance_mismatch" };
      const user = await get(`users/${input.subject}`);
      if (user?.object !== "user" || user.id !== input.subject || typeof user.primary_email_address_id !== "string" || !Array.isArray(user.email_addresses)) return { code: "contact_subject_mismatch" };
      const matches = user.email_addresses.filter((e: any) => e?.id === user.primary_email_address_id);
      if (matches.length !== 1 || matches[0]?.object !== "email_address" || matches[0]?.verification?.status !== "verified" || !validEmail(matches[0]?.email_address)) return { code: "contact_missing_verified_primary" };
      const email: string = matches[0].email_address;
      if (relayEmail(email)) return { code: "contact_relay_exception" };
      return { code: "verified_primary", email };
    });
  } catch { return { code: "contact_lookup_failed" }; }
}
export type SendResult = { state: "pending" | "retry" | "exception"; code: string; providerId?: string; retryAfterMs?: number };
export async function sendNotification(input: { config: string; payload: string; key: string; firstAttemptAt: number; leaseUntil: number }): Promise<SendResult> {
  if (!notificationsEnabled()) return { state: "exception", code: "email_disabled" };
  if (!sendConfig() || sendConfig() !== input.config) return { state: "exception", code: "send_config_mismatch" };
  // Margin includes the entire bounded HTTP operation and scheduler/lease delay.
  if (Date.now() + SEND_TIMEOUT_MS >= input.firstAttemptAt + WINDOW_MS || Date.now() + SEND_TIMEOUT_MS >= input.leaseUntil) return { state: "exception", code: "send_window_expired" };
  const secret = process.env.RESEND_API_KEY;
  if (!secret) return { state: "exception", code: "send_secret_missing" };
  try {
    return await bounded(async signal => {
      const response = await fetch("https://api.resend.com/emails", { method: "POST", redirect: "error", signal,
        headers: { Authorization: `Bearer ${secret}`, "Content-Type": "application/json", "Idempotency-Key": input.key }, body: input.payload });
      if (response.status === 429 || response.status === 408 || response.status >= 500) {
        const value = response.headers.get("retry-after");
        const delay = value && /^\d+(\.\d+)?$/.test(value) ? Number(value) * 1000 : Date.parse(value ?? "") - Date.now();
        void response.body?.cancel().catch(() => {});
        return { state: "retry", code: "send_temporary", ...(Number.isFinite(delay) && delay >= 0 ? { retryAfterMs: delay } : {}) };
      }
      if (response.status === 409) {
        const body = await json(response);
        return body?.name === "concurrent_idempotent_requests" ? { state: "retry", code: "send_concurrent" } : { state: "exception", code: "send_conflict" };
      }
      if (response.status !== 200) { void response.body?.cancel().catch(() => {}); return { state: "exception", code: "send_rejected" }; }
      const body = await json(response);
      if (!validProviderId(body?.id)) return { state: "retry", code: "send_unknown" };
      return { state: "pending", code: "provider_accepted_delivery_pending", providerId: body.id };
    });
  } catch { return { state: "retry", code: "send_unknown" }; }
}
