// Action-local, injectable transport. No handlers, environment reads or retries.
// Source: clerk/openapi-specs bapi/2026-05-12.yml; Apple /auth/revoke.
export const APPLE_TRANSPORT_TIMEOUT_MS = 20_000;
export const APPLE_TRANSPORT_MAX_BYTES = 64 * 1024;
export type AppleBinding = Readonly<{
  issuer: string; instance: string; owner: string; subject: string; revision: string;
  clientId: string; teamId: string; keyId: string; externalAccountId: string;
  providerUserId: string; provenanceEvidence: string;
}>;
export type AppleTransportInput = {
  enabled?: boolean; binding: AppleBinding; clerkCredential: string; clientSecret: string;
  fetch: (url: string, init: RequestInit) => Promise<Response>;
  authorize: () => Promise<boolean>;
};
export type AppleTransportResult = {
  state: "acknowledgement" | "unknown" | "blocked"; code: string; httpStatus?: number;
};
const result = (state: AppleTransportResult["state"], code: string, httpStatus?: number): AppleTransportResult =>
  ({ state, code, ...(httpStatus === undefined ? {} : { httpStatus }) });
const record = (x: unknown): x is Record<string, unknown> => !!x && typeof x === "object" && !Array.isArray(x);
const text = (x: unknown, max = 4096): x is string => typeof x === "string" && x.length > 0 && x.length <= max && !/[\s\u0000-\u001f\u007f]/.test(x);
const ref = (x: unknown): x is string => typeof x === "string" && /^[A-Za-z0-9_-]{1,100}$/.test(x);
const apple = (x: unknown) => x === "apple" || x === "oauth_apple";
class Stop { constructor(readonly value: AppleTransportResult) {} }
function block(code: string, status?: number): never { throw new Stop(result("blocked", code, status)); }

// Structural consistency only. Signature authenticity depends on trusted provisioning.
function secretValid(secret: string, b: AppleBinding): boolean {
  try {
    if (!text(secret, 8192)) return false;
    const parts = secret.split(".");
    if (parts.length !== 3 || parts.some(p => !/^[A-Za-z0-9_-]+$/.test(p))) return false;
    const decode = (p: string) => Uint8Array.from(atob(p.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - p.length % 4) % 4)), c => c.charCodeAt(0));
    const parse = (p: string): unknown => JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(decode(p)));
    const h = parse(parts[0]), p = parse(parts[1]), now = Math.floor(Date.now() / 1000);
    return record(h) && record(p) && h.alg === "ES256" && h.kid === b.keyId &&
      h.crit === undefined && decode(parts[2]).length === 64 && p.iss === b.teamId &&
      p.sub === b.clientId && p.aud === "https://appleid.apple.com" &&
      typeof p.iat === "number" && Number.isSafeInteger(p.iat) && p.iat >= 0 && p.iat <= now &&
      typeof p.exp === "number" && Number.isSafeInteger(p.exp) && p.exp > now + 60 &&
      p.exp > p.iat && p.exp - p.iat <= 15_777_000;
  } catch { return false; }
}

function checkExpiry(expiry: unknown) {
  if (typeof expiry !== "number" || !Number.isSafeInteger(expiry) || expiry <= 0)
    block("token_expiry_unknown", 200);
  // The pinned schema says Unix timestamp but does not explicitly state units.
  // Never guess from magnitude: require freshness under BOTH seconds and ms.
  // A seconds-scale future value remains manual pending authoritative unit proof.
  const now = Date.now();
  if (expiry <= now / 1000) block("token_expired", 200);
  if (expiry <= now + 60_000) block("token_expiry_units_unverified", 200);
}

export async function appleDeletionTransport(input: AppleTransportInput): Promise<AppleTransportResult> {
  if (input.enabled !== true) return result("blocked", "disabled");
  const b = Object.freeze({ ...input.binding });
  const { clerkCredential, clientSecret, fetch: transport, authorize } = input;
  if (!text(b.issuer, 253) || !/^https:\/\/[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*$/.test(b.issuer) ||
      !/^ins_[A-Za-z0-9]{1,250}$/.test(b.instance) || !/^user_[A-Za-z0-9]{1,250}$/.test(b.subject) ||
      b.owner !== `${b.issuer}|${b.subject}` || !ref(b.revision) || !ref(b.provenanceEvidence) ||
      !text(b.clientId, 255) || !/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/.test(b.clientId) ||
      !/^[A-Z0-9]{10}$/.test(b.teamId) || !/^[A-Z0-9]{10}$/.test(b.keyId) ||
      !text(b.externalAccountId, 255) || !/^[A-Za-z0-9_-]+$/.test(b.externalAccountId) ||
      !text(b.providerUserId, 255)) return result("blocked", "invalid_binding");
  if (!text(clerkCredential) || typeof transport !== "function" || typeof authorize !== "function")
    return result("blocked", "missing_transport_or_credential");
  if (!secretValid(clientSecret, b)) return result("blocked", "invalid_client_secret");
  const controller = new AbortController(), deadline = Date.now() + APPLE_TRANSPORT_TIMEOUT_MS;
  let timer: ReturnType<typeof setTimeout> | undefined, postSent = false, bytesRead = 0;
  const alive = () => {
    if (controller.signal.aborted || Date.now() >= deadline) {
      controller.abort(); throw new Stop(result("unknown", "transport_timeout"));
    }
  };
  const cancel = (r: Response) => { void r.body?.cancel().catch(() => {}); };
  async function body(r: Response): Promise<string> {
    alive();
    const reader = r.body?.getReader();
    if (!reader) return "";
    const chunks: Uint8Array[] = []; let size = 0;
    const abort = () => { void reader.cancel().catch(() => {}); };
    controller.signal.addEventListener("abort", abort, { once: true });
    try {
      for (;;) {
        alive(); const { value, done } = await reader.read(); alive();
        if (done) break;
        size += value.length; bytesRead += value.length;
        if (bytesRead > APPLE_TRANSPORT_MAX_BYTES) { abort(); block("response_too_large", r.status); }
        chunks.push(value);
      }
      const bytes = new Uint8Array(size); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      try { return new TextDecoder("utf-8", { fatal: true }).decode(bytes); }
      catch { return block("malformed_response", r.status); }
    } finally { controller.signal.removeEventListener("abort", abort); reader.releaseLock(); }
  }
  async function authorized() {
    alive();
    let allowed: boolean;
    try { allowed = await authorize(); } catch { alive(); return block("authorization_check_failed"); }
    alive();
    if (allowed !== true) block("authorization_withdrawn");
    if (!secretValid(clientSecret, b)) block("invalid_client_secret");
  }
  async function get(path: string): Promise<unknown> {
    alive();
    const r = await transport(`https://api.clerk.com/v1/${path}`, { method: "GET", redirect: "error", signal: controller.signal,
      headers: { Authorization: `Bearer ${clerkCredential}`, "Clerk-API-Version": "2026-05-12", Accept: "application/json" } });
    if (controller.signal.aborted || Date.now() >= deadline) { cancel(r); alive(); }
    if (r.status !== 200) { cancel(r); block("clerk_response_rejected", r.status); }
    const raw = await body(r);
    try { return JSON.parse(raw); } catch { return block("malformed_response", r.status); }
  }
  async function run(): Promise<AppleTransportResult> {
    const instance = await get("instance");
    if (!record(instance) || instance.object !== "instance" || instance.id !== b.instance) block("instance_mismatch", 200);
    const user = await get(`users/${b.subject}`);
    if (!record(user) || user.object !== "user" || user.id !== b.subject || !Array.isArray(user.external_accounts)) block("user_identity_mismatch", 200);
    if (user.external_accounts.some(e => !record(e) || typeof e.provider !== "string")) block("malformed_response", 200);
    const accounts = user.external_accounts.filter(e => apple(e.provider));
    if (accounts.length !== 1) block("apple_identity_inventory_unverified", 200);
    const account = accounts[0];
    if (account.object !== "external_account" || account.id !== b.externalAccountId || account.provider_user_id !== b.providerUserId ||
        !record(account.verification) || account.verification.status !== "verified" || account.verification.strategy !== "oauth_apple")
      block("apple_identity_unverified", 200);
    await authorized(); // This GET may refresh the provider token.
    const tokens = await get(`users/${b.subject}/oauth_access_tokens/oauth_apple?limit=2&offset=0&paginated=false`);
    if (!Array.isArray(tokens) || tokens.length !== 1) block("token_inventory_unverified", 200);
    const token = tokens[0];
    if (!record(token) || token.object !== "oauth_access_token" || !apple(token.provider) ||
        token.external_account_id !== b.externalAccountId || token.provider_user_id !== b.providerUserId ||
        !text(token.token, 16_384) || !record(token.public_metadata) || !(token.label === null || typeof token.label === "string") ||
        (token.scopes !== undefined && (!Array.isArray(token.scopes) || token.scopes.some(s => typeof s !== "string"))) ||
        (token.id_token !== undefined && typeof token.id_token !== "string") || token.token_secret !== undefined)
      block("token_identity_or_shape_unverified", 200);
    checkExpiry(token.expires_at);
    await authorized();
    checkExpiry(token.expires_at); alive();
    const form = new URLSearchParams({ client_id: b.clientId, client_secret: clientSecret, token: token.token, token_type_hint: "access_token" });
    postSent = true;
    const r = await transport("https://appleid.apple.com/auth/revoke", { method: "POST", redirect: "error", signal: controller.signal,
      headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: form.toString() });
    if (controller.signal.aborted || Date.now() >= deadline) { cancel(r); alive(); }
    if (r.status !== 200) { cancel(r); return result(r.status === 400 ? "blocked" : "unknown", "apple_response_rejected", r.status); }
    if (await body(r) !== "") return result("unknown", "apple_acknowledgement_body_unexpected", 200);
    alive();
    return result("acknowledgement", "apple_revocation_acknowledged", 200);
  }
  try {
    return await Promise.race([run(), new Promise<AppleTransportResult>(resolve => {
      timer = setTimeout(() => { controller.abort(); resolve(result("unknown", "transport_timeout")); }, APPLE_TRANSPORT_TIMEOUT_MS);
    })]);
  } catch (e) {
    if (e instanceof Stop) return postSent ? { ...e.value, state: "unknown" } : e.value;
    return result("unknown", "transport_unknown");
  } finally { controller.abort(); if (timer !== undefined) clearTimeout(timer); }
}
