// Injectable, default-off v2 transport. Queued deletion is never completion.
export const REVENUECAT_TRANSPORT_TIMEOUT_MS = 20_000;
export const REVENUECAT_TRANSPORT_MAX_BYTES = 64 * 1024;
export type RevenuecatTransportInput = {
  enabled?: boolean;
  binding: { issuer: string; owner: string; subject: string; project: string; revision: string };
  operation: "deleteCustomer" | "observeCustomer";
  credential: string;
  fetch: (url: string, init: RequestInit) => Promise<Response>;
  authorize?: () => Promise<boolean>;
};
export type RevenuecatTransportResult = {
  state: "acknowledgement" | "absence_observed" | "observed" | "unknown" | "blocked";
  code: string;
  httpStatus?: number;
  retryAfterMs?: number;
};
const record = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);
const result = (state: RevenuecatTransportResult["state"], code: string, httpStatus?: number): RevenuecatTransportResult =>
  ({ state, code, ...(httpStatus === undefined ? {} : { httpStatus }) });
class Stop { constructor(readonly value: RevenuecatTransportResult) {} }
function block(code: string, status?: number): never { throw new Stop(result("blocked", code, status)); }

export async function revenuecatDeletionTransport(input: RevenuecatTransportInput): Promise<RevenuecatTransportResult> {
  if (input.enabled !== true) return result("blocked", "disabled");
  const binding = Object.freeze({ ...input.binding });
  const { operation, credential, fetch: transport, authorize } = input;
  if (typeof binding.issuer !== "string" || !/^https:\/\/[A-Za-z0-9.-]+$/.test(binding.issuer) ||
      typeof binding.subject !== "string" || !/^user_[A-Za-z0-9]{1,250}$/.test(binding.subject) ||
      typeof binding.project !== "string" || !/^proj[A-Za-z0-9_-]{1,100}$/.test(binding.project) ||
      binding.owner !== `${binding.issuer}|${binding.subject}` ||
      typeof binding.revision !== "string" || !/^[A-Za-z0-9_-]{1,100}$/.test(binding.revision)) return result("blocked", "invalid_binding");
  if (operation !== "deleteCustomer" && operation !== "observeCustomer") return result("blocked", "invalid_operation");
  if (typeof transport !== "function" || typeof credential !== "string" || !credential || credential.length > 4096 ||
      /[\s\u0000-\u001f\u007f]/.test(credential)) return result("blocked", "missing_transport_or_credential");
  const path = `/v2/projects/${binding.project}/customers/${binding.subject}`;
  const controller = new AbortController();
  const deadline = Date.now() + REVENUECAT_TRANSPORT_TIMEOUT_MS;
  let submitted = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = () => result("unknown", submitted ? "deletion_outcome_unknown" : "transport_timeout");
  const alive = () => {
    if (controller.signal.aborted || Date.now() >= deadline) { controller.abort(); throw new Stop(timeout()); }
  };
  const cancel = (response: Response) => { void response.body?.cancel().catch(() => {}); };
  async function json(response: Response): Promise<Record<string, unknown>> {
    const reader = response.body?.getReader();
    if (!reader) block("malformed_response", response.status);
    const chunks: Uint8Array[] = []; let size = 0;
    const abort = () => { void reader.cancel().catch(() => {}); };
    controller.signal.addEventListener("abort", abort, { once: true });
    try {
      for (;;) {
        alive();
        const { value, done } = await reader.read();
        alive();
        if (done) break;
        size += value.byteLength;
        if (size > REVENUECAT_TRANSPORT_MAX_BYTES) { abort(); block("response_too_large", response.status); }
        chunks.push(value);
      }
      const bytes = new Uint8Array(size); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      let body: unknown;
      try { body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
      catch { block("malformed_response", response.status); }
      alive();
      if (!record(body)) block("malformed_response", response.status);
      return body;
    } finally { controller.signal.removeEventListener("abort", abort); reader.releaseLock(); }
  }
  async function request(route: string, method: "GET" | "DELETE") {
    alive();
    if (method === "DELETE") {
      if (typeof authorize !== "function") block("authorization_prerequisite_missing");
      let allowed: boolean;
      try { allowed = await authorize(); } catch { alive(); block("authorization_check_failed"); }
      alive();
      if (allowed !== true) block("authorization_withdrawn");
      submitted = true;
    }
    const response = await transport(`https://api.revenuecat.com${route}`, {
      method, redirect: "error", signal: controller.signal,
      headers: { Authorization: `Bearer ${credential}`, Accept: "application/json" },
    });
    if (controller.signal.aborted || Date.now() >= deadline) { cancel(response); alive(); }
    const status = response.status;
    if (method === "DELETE" && status !== 200) {
      cancel(response); throw new Stop(result("unknown", "deletion_outcome_unknown", status));
    }
    if (method === "GET" && ([408, 423, 429].includes(status) || status >= 500)) {
      const hint = response.headers.get("retry-after");
      const delay = hint && /^\d+(\.\d+)?$/.test(hint) ? Number(hint) * 1000 : Date.parse(hint ?? "") - Date.now();
      const validDelay = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= Number.MAX_SAFE_INTEGER - Date.now();
      let retryAfterMs = validDelay(delay) ? Math.ceil(delay) : 0;
      try {
        const body = await json(response);
        if (Number.isSafeInteger(body.backoff_ms) && validDelay(body.backoff_ms)) retryAfterMs = Math.max(retryAfterMs, body.backoff_ms);
      } catch { alive(); /* Bad transient bodies never become observations. */ }
      throw new Stop({ ...result("unknown", "provider_temporary", status), retryAfterMs });
    }
    if (status !== 200 && status !== 404) { cancel(response); block("provider_rejected", status); }
    const body = await json(response);
    if (status === 404) {
      if (body.type !== "resource_missing") block("malformed_response", status);
      throw new Stop(operation === "observeCustomer" ? result("absence_observed", "customer_absent", status) : result("blocked", "inventory_unavailable", status));
    }
    return body;
  }
  try {
    const expired = new Promise<RevenuecatTransportResult>(resolve => {
      timer = setTimeout(() => { controller.abort(); resolve(timeout()); }, REVENUECAT_TRANSPORT_TIMEOUT_MS);
    });
    return await Promise.race([expired, (async (): Promise<RevenuecatTransportResult> => {
      const customer = await request(path, "GET");
      if (customer.object !== "customer" || customer.id !== binding.subject || customer.project_id !== binding.project) block("customer_identity_mismatch", 200);
      if (operation === "observeCustomer") return result("observed", "customer_present", 200);
      const aliases = await request(`${path}/aliases?limit=32`, "GET");
      if (aliases.object !== "list" || aliases.url !== `${path}/aliases` || !Array.isArray(aliases.items) || aliases.items.length > 32) block("malformed_response", 200);
      const ids = new Set<string>();
      for (const alias of aliases.items) {
        if (!record(alias) || alias.object !== "customer.alias" || typeof alias.id !== "string" ||
            !alias.id.length || alias.id.length > 1500 || /[\s\u0000-\u001f\u007f]/.test(alias.id) || ids.has(alias.id)) block("malformed_response", 200);
        ids.add(alias.id);
      }
      if (aliases.next_page !== null || [...ids].some(id => id !== binding.subject)) block("alias_ownership_unverified", 200);
      const ack = await request(path, "DELETE");
      if (ack.object !== "customer" || ack.id !== binding.subject || !Number.isSafeInteger(ack.deleted_at) || (ack.deleted_at as number) < 0)
        throw new Stop(result("unknown", "deletion_outcome_unknown", 200));
      return result("acknowledgement", "customer_delete_queued", 200);
    })()]);
  } catch (error) {
    if (submitted) return result("unknown", "deletion_outcome_unknown", error instanceof Stop ? error.value.httpStatus : undefined);
    return error instanceof Stop ? error.value : result("unknown", "transport_unknown");
  } finally { if (timer !== undefined) clearTimeout(timer); }
}
