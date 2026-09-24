import { automationEnabled, ACTION_TIMEOUT_MS } from "./deletionAdapter";
import { CLERK_API_VERSION, contactBinding } from "./notificationAdapter";
import { PAGE_SIZE, MAX_ITEMS, type Binding, type Target, type PageResult, type Code } from "./preflightContract";

export const preflightEnabled = () => automationEnabled() && process.env.DELETION_PREFLIGHT_ENABLED === "true" &&
  process.env.DELETION_PREFLIGHT_RETENTION_APPROVED === "true";
const ref = (value: string | undefined): value is string => !!value && /^[A-Za-z0-9_-]{1,100}$/.test(value);
export const identifier = (value: unknown, max = 256): value is string => typeof value === "string" &&
  value.length > 0 && value.length <= max && !/[\s\u0000-\u001f\u007f]/.test(value);
export function preflightConfig(provider: Target["provider"]): string | null {
  const binding = contactBinding();
  const revision = provider === "clerk" ? process.env.CLERK_PREFLIGHT_CONFIG_REF : process.env.REVENUECAT_PREFLIGHT_CONFIG_REF;
  if (!binding || !ref(revision)) return null;
  const config: Binding = { revision, ...binding, wireVersion: provider === "clerk" ? CLERK_API_VERSION : "v2" };
  if (provider === "revenuecat") {
    const project = process.env.REVENUECAT_PREFLIGHT_PROJECT_ID;
    if (!project || !/^proj[A-Za-z0-9_-]{1,100}$/.test(project) || process.env.REVENUECAT_PREFLIGHT_PROJECT_VERIFIED !== "true") return null;
    config.project = project;
  }
  return JSON.stringify(config);
}
export function bindingMatches(input: Target): boolean {
  const config = preflightConfig(input.provider);
  if (!config || input.config !== config || !/^user_[A-Za-z0-9]{1,250}$/.test(input.subject)) return false;
  const binding = JSON.parse(config) as Binding;
  return input.owner === `${binding.issuer}|${input.subject}`;
}
const blocked = (code: Code): PageResult => ({ state: "blocked", code });
const statuses = ["active", "revoked", "ended", "expired", "removed", "abandoned", "replaced", "pending"];
export const validSession = (s: { id: unknown; status: unknown }) => identifier(s.id) && /^sess_[A-Za-z0-9]+$/.test(s.id) && statuses.includes(s.status as string);
export const aliasPath = (project: string, subject: string) => `/v2/projects/${encodeURIComponent(project)}/customers/${encodeURIComponent(subject)}/aliases`;
// Never fetch a provider-supplied URL. Validate the complete route/query, then rebuild it.
export function aliasCursor(next: unknown, project: string, subject: string): string | null {
  if (next === null) return "";
  if (typeof next !== "string" || next.length > 6000 || !next.startsWith(`${aliasPath(project, subject)}?`)) return null;
  try {
    const u = new URL(next, "https://api.revenuecat.com");
    if (u.origin !== "https://api.revenuecat.com" || u.pathname !== aliasPath(project, subject) || u.hash || u.username || u.password) return null;
    const keys = [...u.searchParams.keys()];
    if (keys.some(k => k !== "starting_after" && k !== "limit") || new Set(keys).size !== keys.length ||
        (u.searchParams.has("limit") && u.searchParams.get("limit") !== String(PAGE_SIZE))) return null;
    const cursor = u.searchParams.get("starting_after");
    return identifier(cursor, 1500) ? cursor : null;
  } catch { return null; }
}
async function readJSON(response: Response): Promise<any> {
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
function delay(value: string | null) {
  const n = value && /^\d+(\.\d+)?$/.test(value) ? Number(value) * 1000 : Date.parse(value ?? "") - Date.now();
  return Number.isFinite(n) && n >= 0 && n <= Number.MAX_SAFE_INTEGER - Date.now() ? n : 0;
}
class Stop { constructor(readonly result: PageResult) {} }

export async function readPreflightPage(input: Target): Promise<PageResult> {
  if (!preflightEnabled()) return blocked("disabled");
  if (!bindingMatches(input)) return blocked("config_changed");
  const config = JSON.parse(input.config) as Binding;
  const key = input.provider === "clerk" ? process.env.CLERK_CONTACT_SECRET_KEY : process.env.REVENUECAT_PREFLIGHT_SECRET_KEY;
  if (!key) return blocked("missing_secret");
  const controller = new AbortController(); let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([(async (): Promise<PageResult> => {
      const get = async (path: string, allowAbsence = false) => {
        controller.signal.throwIfAborted();
        if (!preflightEnabled() || !bindingMatches(input)) throw new Stop(blocked("config_changed"));
        const clerk = input.provider === "clerk";
        const response = await fetch(`${clerk ? "https://api.clerk.com" : "https://api.revenuecat.com"}${path}`, {
          method: "GET", redirect: "error", signal: controller.signal,
          headers: { Authorization: `Bearer ${key}`, Accept: "application/json", ...(clerk ? { "Clerk-API-Version": CLERK_API_VERSION } : {}) },
        });
        if ([408, 423, 429].includes(response.status) || response.status >= 500) {
          let retryAfterMs = delay(response.headers.get("retry-after"));
          if (!clerk) {
            try { const body = await readJSON(response); if (Number.isSafeInteger(body?.backoff_ms) && body.backoff_ms >= 0 && body.backoff_ms <= Number.MAX_SAFE_INTEGER - Date.now()) retryAfterMs = Math.max(retryAfterMs, body.backoff_ms); } catch { /* sanitized transient */ }
          } else { void response.body?.cancel().catch(() => {}); }
          throw new Stop({ state: "retry", code: "provider_temporary", retryAfterMs });
        }
        if (response.status !== 200 && !(allowAbsence && response.status === 404)) {
          void response.body?.cancel().catch(() => {}); throw new Stop(blocked("provider_rejected"));
        }
        let body: any;
        try { body = await readJSON(response); } catch { throw new Stop(blocked("malformed_response")); }
        if (response.status === 404) {
          const missing = clerk ? Array.isArray(body?.errors) && body.errors.length === 1 && body.errors[0]?.code === "resource_not_found" : body?.type === "resource_missing";
          throw new Stop(blocked(missing ? "resource_absent_inventory_unavailable" : "malformed_response"));
        }
        return body;
      };
      if (input.provider === "clerk") {
        if (!["user", "sessions"].includes(input.phase)) return blocked("identity_mismatch");
        const instance = await get("/v1/instance");
        if (instance?.object !== "instance" || instance.id !== config.instance) return blocked("instance_mismatch");
        if (input.phase === "user") {
          if (input.cursor !== "") return blocked("invalid_continuation");
          const user = await get(`/v1/users/${input.subject}`, true);
          if (user?.object !== "user" || user.id !== input.subject) return blocked("identity_mismatch");
          if (!Array.isArray(user.external_accounts) || user.external_accounts.length > 128) return blocked("malformed_response");
          const externalAccounts = [];
          for (const e of user.external_accounts) {
            if (!e || !["external_account", "facebook_account", "google_account"].includes(e.object) || !identifier(e.id) ||
                !identifier(e.provider) || !identifier(e.provider_user_id)) return blocked("malformed_response");
            externalAccounts.push({ id: e.id as string, provider: e.provider as string, providerUserId: e.provider_user_id as string });
          }
          if (new Set(externalAccounts.map(e => e.id)).size !== externalAccounts.length) return blocked("malformed_response");
          return { state: "page", code: "inventory_observed", externalAccounts };
        }
        if (!/^\d+$/.test(input.cursor) || Number(input.cursor) > MAX_ITEMS || Number(input.cursor) % PAGE_SIZE !== 0) return blocked("invalid_continuation");
        // Pinned 2026-05-12 Session.List is a REST array, NOT SDK {data,totalCount}.
        // No active-only filter: nothing in this lane mutates the enumerated set.
        const rows = await get(`/v1/sessions?user_id=${input.subject}&limit=${PAGE_SIZE}&offset=${input.cursor}`);
        if (!Array.isArray(rows) || rows.length > PAGE_SIZE) return blocked("malformed_response");
        const sessions = [];
        for (const s of rows) {
          if (s?.object !== "session" || s.user_id !== input.subject) return blocked("identity_mismatch");
          if (!validSession(s)) return blocked("malformed_response");
          sessions.push({ id: s.id as string, status: s.status as string });
        }
        return { state: "page", code: "inventory_observed", sessions,
          ...(sessions.length === PAGE_SIZE ? { next: String(Number(input.cursor) + PAGE_SIZE) } : {}) };
      }
      if (!config.project || !["customer", "aliases"].includes(input.phase)) return blocked("identity_mismatch");
      if (input.phase === "customer") {
        if (input.cursor !== "") return blocked("invalid_continuation");
        const customer = await get(`/v2/projects/${config.project}/customers/${input.subject}`, true);
        if (customer?.object !== "customer" || customer.id !== input.subject) return blocked("identity_mismatch");
        if (customer.project_id !== config.project) return blocked("project_mismatch");
        return { state: "page", code: "inventory_observed" };
      }
      if (input.cursor !== "" && !identifier(input.cursor, 1500)) return blocked("invalid_continuation");
      const path = aliasPath(config.project, input.subject);
      const params = new URLSearchParams({ limit: String(PAGE_SIZE) });
      if (input.cursor) params.set("starting_after", input.cursor);
      const body = await get(`${path}?${params}`, true);
      if (body?.object !== "list" || body.url !== path || !Array.isArray(body.items) || body.items.length > PAGE_SIZE) return blocked("malformed_response");
      const aliases: string[] = [];
      for (const a of body.items) {
        if (a?.object !== "customer.alias" || !identifier(a.id, 1500)) return blocked("malformed_response");
        aliases.push(a.id);
      }
      const next = aliasCursor(body.next_page, config.project, input.subject);
      if (next === null || (next && (!aliases.length || aliases.at(-1) !== next || next === input.cursor))) return blocked("invalid_continuation");
      return { state: "page", code: "inventory_observed", aliases, ...(next ? { next } : {}) };
    })(), new Promise<PageResult>(resolve => {
      timer = setTimeout(() => { controller.abort(); resolve({ state: "retry", code: "transport_unknown" }); }, ACTION_TIMEOUT_MS);
    })]);
  } catch (e) { return e instanceof Stop ? e.result : { state: "retry", code: "transport_unknown" }; }
  finally { if (timer !== undefined) clearTimeout(timer); }
}
