import type { ClerkBinding } from "./clerkDeletionTransport";

export type GoogleAccount = { externalAccountId: string; providerUserId: string };
export type GoogleBinding = ClerkBinding & { clientId: string; authorizedPartyId: string; projectRef: string };
export type GoogleTransportInput = {
  enabled?: boolean;
  binding: GoogleBinding;
  operation: "inventory" | "revoke";
  accounts?: GoogleAccount[];
  target?: GoogleAccount;
  credential: string;
  fetch: (url: string, init: RequestInit) => Promise<Response>;
  authorize: () => Promise<boolean>;
};
export type GoogleTransportResult = {
  state: "inventory" | "acknowledgement" | "blocked" | "unknown";
  code: string;
  httpStatus?: number;
  accounts?: GoogleAccount[];
};

export const GOOGLE_TRANSPORT_TIMEOUT_MS = 20_000;
export const GOOGLE_TRANSPORT_MAX_BYTES = 64 * 1024;
// Clerk OpenAPI 3b078e5e0c17ad5261f06cb00e0a0943614dacb0, bapi/2026-05-12.yml.
const API_VERSION = "2026-05-12";
const record = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);
const id = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9_-]{1,250}$/.test(v);
const ref = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9_-]{1,100}$/.test(v);
const clientId = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9_-]{1,250}\.apps\.googleusercontent\.com$/.test(v);
const google = (v: unknown) => v === "google" || v === "oauth_google";
const scopes = new Set(["openid", "profile", "email", "https://www.googleapis.com/auth/userinfo.profile",
  "https://www.googleapis.com/auth/userinfo.email"]);
const result = (state: GoogleTransportResult["state"], code: string, httpStatus?: number): GoogleTransportResult =>
  ({ state, code, ...(httpStatus === undefined ? {} : { httpStatus }) });
class Stop { constructor(readonly value: GoogleTransportResult) {} }
function block(code: string, status?: number): never { throw new Stop(result("blocked", code, status)); }
const sort = (accounts: GoogleAccount[]) => accounts.sort((a, b) => a.externalAccountId < b.externalAccountId ? -1 :
  a.externalAccountId > b.externalAccountId ? 1 : 0);
function validAccounts(value: unknown): value is GoogleAccount[] {
  if (!Array.isArray(value) || value.length > 16) return false;
  const external = new Set<string>(), provider = new Set<string>();
  for (const a of value) {
    if (!record(a) || !id(a.externalAccountId) || !id(a.providerUserId) ||
        external.has(a.externalAccountId) || provider.has(a.providerUserId)) return false;
    external.add(a.externalAccountId); provider.add(a.providerUserId);
  }
  return true;
}
const sameAccounts = (a: GoogleAccount[], b: GoogleAccount[]) => a.length === b.length &&
  a.every((v, i) => v.externalAccountId === b[i].externalAccountId && v.providerUserId === b[i].providerUserId);

// No retries. Lookup may refresh credentials. A lost POST response needs worker reconciliation.
export async function googleDeletionTransport(input: GoogleTransportInput): Promise<GoogleTransportResult> {
  if (input.enabled !== true) return result("blocked", "disabled");
  const binding = Object.freeze({ ...input.binding });
  const { operation, credential, fetch: transport, authorize } = input;
  if (typeof binding.issuer !== "string" || !/^https:\/\/[a-zA-Z0-9.-]+$/.test(binding.issuer) ||
      typeof binding.instance !== "string" || !/^ins_[A-Za-z0-9]+$/.test(binding.instance) ||
      typeof binding.subject !== "string" || !/^user_[A-Za-z0-9]{1,250}$/.test(binding.subject) ||
      binding.owner !== `${binding.issuer}|${binding.subject}` || !ref(binding.revision) || !ref(binding.projectRef) ||
      !clientId(binding.clientId) || !clientId(binding.authorizedPartyId)) return result("blocked", "invalid_binding");
  if (operation !== "inventory" && operation !== "revoke") return result("blocked", "invalid_operation");
  if (typeof transport !== "function" || typeof authorize !== "function" || typeof credential !== "string" ||
      !credential || credential.length > 4096 || /[\s\u0000-\u001f\u007f]/.test(credential))
    return result("blocked", "missing_transport_or_authorization");
  let expected: GoogleAccount[] = [], target: GoogleAccount | undefined;
  if (operation === "inventory") {
    if (input.accounts !== undefined || input.target !== undefined) return result("blocked", "invalid_target");
  } else {
    if (!validAccounts(input.accounts) || !input.accounts.length || !record(input.target) ||
        !id(input.target.externalAccountId) || !id(input.target.providerUserId) ||
        !input.accounts.some(a => a.externalAccountId === input.target!.externalAccountId &&
          a.providerUserId === input.target!.providerUserId)) return result("blocked", "invalid_target");
    expected = sort(input.accounts.map(a => Object.freeze({ externalAccountId: a.externalAccountId, providerUserId: a.providerUserId })));
    target = Object.freeze({ externalAccountId: input.target.externalAccountId, providerUserId: input.target.providerUserId });
  }
  const controller = new AbortController(), deadline = Date.now() + GOOGLE_TRANSPORT_TIMEOUT_MS;
  let timer: ReturnType<typeof setTimeout> | undefined, bytesRead = 0;
  const alive = () => {
    if (controller.signal.aborted || Date.now() >= deadline) {
      controller.abort(); throw new Stop(result("unknown", "transport_timeout"));
    }
  };
  const cancel = (response: Response) => { void response.body?.cancel().catch(() => {}); };
  async function bytes(response: Response): Promise<Uint8Array> {
    const reader = response.body?.getReader();
    if (!reader) return new Uint8Array();
    const chunks: Uint8Array[] = []; let size = 0;
    const abort = () => { void reader.cancel().catch(() => {}); };
    controller.signal.addEventListener("abort", abort, { once: true });
    try {
      for (;;) {
        alive();
        const { value, done } = await reader.read();
        alive();
        if (done) break;
        bytesRead += value.length; size += value.length;
        if (bytesRead > GOOGLE_TRANSPORT_MAX_BYTES) { abort(); block("response_too_large", response.status); }
        chunks.push(value);
      }
      const body = new Uint8Array(size); let offset = 0;
      for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.length; }
      return body;
    } finally { controller.signal.removeEventListener("abort", abort); reader.releaseLock(); }
  }
  async function permission() {
    alive(); let allowed: boolean;
    try { allowed = await authorize(); }
    catch { alive(); block("authorization_check_failed"); }
    alive();
    if (allowed !== true) block("authorization_withdrawn");
  }
  async function request(url: string, clerk: boolean, post = false, refresh = false): Promise<unknown> {
    if (post || refresh) await permission();
    alive();
    const response = await transport(url, {
      method: post ? "POST" : "GET", redirect: "error", signal: controller.signal,
      headers: clerk ? { Authorization: `Bearer ${credential}`, "Clerk-API-Version": API_VERSION, Accept: "application/json" } :
        post ? { "Content-Type": "application/x-www-form-urlencoded" } : { Accept: "application/json" },
      ...(post ? { body: new URLSearchParams({ token: providerToken }).toString() } : {}),
    });
    if (controller.signal.aborted || Date.now() >= deadline) { cancel(response); alive(); }
    const status = response.status;
    if (status !== 200) {
      cancel(response);
      if (!clerk && !post) block("google_tokeninfo_unavailable", status);
      throw new Stop(result(status === 408 || status === 429 || status >= 500 ? "unknown" : "blocked",
        post ? "google_revoke_rejected" : refresh ? "google_token_lookup_failed" : "provider_rejected", status));
    }
    const body = await bytes(response);
    if (post) return undefined; // Google 200 is an acknowledgement, not propagation evidence.
    try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(body)); }
    catch { block("malformed_response", status); }
  }
  const clerkURL = (path: string) => `https://api.clerk.com/v1/${path}`;
  async function inventory(): Promise<GoogleAccount[]> {
    const instance = await request(clerkURL("instance"), true);
    if (!record(instance) || instance.object !== "instance" || instance.id !== binding.instance) block("instance_identity_mismatch", 200);
    const user = await request(clerkURL(`users/${binding.subject}`), true);
    if (!record(user) || user.object !== "user" || user.id !== binding.subject) block("user_identity_mismatch", 200);
    if (!Array.isArray(user.external_accounts)) block("google_inventory_malformed", 200);
    const accounts: GoogleAccount[] = [];
    for (const entry of user.external_accounts) {
      // Do not classify a malformed or unnamed provider as non-Google.
      if (!record(entry) || typeof entry.provider !== "string" || !/^[a-z][a-z0-9_]{0,100}$/.test(entry.provider))
        block("google_inventory_malformed", 200);
      if (!google(entry.provider)) {
        if (entry.object === "google_account") block("google_inventory_malformed", 200);
        continue;
      }
      if (!["external_account", "google_account"].includes(entry.object as string) || !id(entry.id) || !id(entry.provider_user_id) ||
          !record(entry.verification) || entry.verification.status !== "verified") block("google_account_unverified_or_malformed", 200);
      accounts.push({ externalAccountId: entry.id, providerUserId: entry.provider_user_id });
    }
    if (!validAccounts(accounts)) block("google_inventory_ambiguous_or_overflow", 200);
    return sort(accounts);
  }
  let providerToken = "";
  try {
    return await Promise.race([
      (async (): Promise<GoogleTransportResult> => {
        const observed = await inventory();
        if (operation === "inventory") return { state: "inventory", code: "google_inventory_observed", httpStatus: 200, accounts: observed };
        if (!sameAccounts(observed, expected)) block("google_inventory_changed", 200);
        const rows = await request(clerkURL(`users/${binding.subject}/oauth_access_tokens/oauth_google?paginated=false&limit=32&offset=0`), true, false, true);
        if (!Array.isArray(rows) || rows.length >= 32) block("google_tokens_malformed_or_overflow", 200);
        const seenExternal = new Set<string>(), seenProvider = new Set<string>();
        for (const row of rows) {
          if (!record(row) || row.object !== "oauth_access_token" || !google(row.provider) || !id(row.external_account_id) ||
              !id(row.provider_user_id) || !expected.some(a => a.externalAccountId === row.external_account_id && a.providerUserId === row.provider_user_id) ||
              seenExternal.has(row.external_account_id) || seenProvider.has(row.provider_user_id)) block("google_token_identity_mismatch", 200);
          seenExternal.add(row.external_account_id); seenProvider.add(row.provider_user_id);
          if (typeof row.token !== "string" || !row.token || row.token.length > 8192 || /[\s\u0000-\u001f\u007f]/.test(row.token))
            block("google_token_malformed", 200);
          if (row.external_account_id === target!.externalAccountId) providerToken = row.token;
        }
        if (!providerToken) block("google_target_token_missing", 200);
        // Diagnostic availability is a prerequisite, not a reason to skip identity checks.
        // https://docs.cloud.google.com/docs/authentication/token-types#user-access-tokens
        let info: unknown;
        try { info = await request(`https://oauth2.googleapis.com/tokeninfo?${new URLSearchParams({ access_token: providerToken })}`, false); }
        catch (error) {
          if (error instanceof Stop) throw error;
          alive(); block("google_tokeninfo_unavailable");
        }
        if (!record(info) || info.sub !== target!.providerUserId || info.aud !== binding.clientId || info.azp !== binding.authorizedPartyId)
          block("google_tokeninfo_identity_mismatch", 200);
        const expires = typeof info.expires_in === "number" ? info.expires_in :
          typeof info.expires_in === "string" && /^\d+$/.test(info.expires_in) ? Number(info.expires_in) : NaN;
        if (!Number.isFinite(expires) || expires <= 0 || typeof info.scope !== "string" || !info.scope.trim() ||
            !info.scope.trim().split(/ +/).every(scope => scopes.has(scope))) block("google_tokeninfo_expiry_or_scope_rejected", 200);
        // Metadata only. Do not repeat token lookup after any failure.
        if (!sameAccounts(await inventory(), expected)) block("google_inventory_changed", 200);
        // This revokes the user's grant across all clients in the configured Google project.
        // https://developers.google.com/identity/protocols/oauth2/web-server#tokenrevoke
        await request("https://oauth2.googleapis.com/revoke", false, true);
        return result("acknowledgement", "google_revoke_acknowledged", 200);
      })(),
      new Promise<GoogleTransportResult>(resolve => {
        timer = setTimeout(() => { controller.abort(); resolve(result("unknown", "transport_timeout")); }, GOOGLE_TRANSPORT_TIMEOUT_MS);
      }),
    ]);
  } catch (error) {
    return error instanceof Stop ? error.value : result("unknown", "transport_unknown");
  } finally {
    if (timer !== undefined) clearTimeout(timer);
    providerToken = "";
  }
}
