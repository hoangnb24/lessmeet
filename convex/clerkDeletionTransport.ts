// Unconnected transport only. No Convex handlers, environment access, retries or completion flags.
import { CLERK_API_VERSION } from "./notificationAdapter";

export const CLERK_TRANSPORT_TIMEOUT_MS = 20_000;
export const CLERK_TRANSPORT_MAX_BYTES = 64 * 1024;
export type ClerkBinding = Readonly<{
  issuer: string; instance: string; owner: string; subject: string; revision: string;
}>;
export type ClerkOperation = "verifyInstance" | "getUser" | "deleteUser" | "getSession" | "revokeSession";
export type ClerkAuthorization = Readonly<{
  binding: ClerkBinding; operation: ClerkOperation; sessionId?: string; appleDispositionRevision: string;
}>;
export type ClerkTransportInput = {
  enabled?: boolean;
  binding: ClerkBinding;
  operation: ClerkOperation;
  sessionId?: string;
  credential: string;
  fetch: (url: string, init: RequestInit) => Promise<Response>;
  // Trusted worker evidence reference, NOT proof established by this module.
  appleDispositionRevision?: string;
  authorize?: (context: ClerkAuthorization) => Promise<boolean>;
};
export type ClerkTransportResult = {
  state: "observed" | "acknowledgement" | "absence_observed" | "session_revoked" | "unknown" | "blocked";
  code: string;
  httpStatus?: number;
};
const result = (state: ClerkTransportResult["state"], code: string, httpStatus?: number): ClerkTransportResult =>
  ({ state, code, ...(httpStatus === undefined ? {} : { httpStatus }) });
const ref = (s: unknown): s is string => typeof s === "string" && /^[A-Za-z0-9_-]{1,100}$/.test(s);
const record = (s: unknown): s is Record<string, unknown> => s !== null && typeof s === "object" && !Array.isArray(s);
const statuses = ["active", "revoked", "ended", "expired", "removed", "abandoned", "replaced", "pending"];
class Stop { constructor(readonly value: ClerkTransportResult) {} }
function block(code: string, status?: number): never { throw new Stop(result("blocked", code, status)); }

// Snapshot caller inputs before the first await; callbacks see the same frozen identity.
export async function clerkDeletionTransport(input: ClerkTransportInput): Promise<ClerkTransportResult> {
  if (input.enabled !== true) return result("blocked", "disabled");
  const binding = Object.freeze({ ...input.binding });
  const { operation, sessionId, credential, fetch: transport, authorize, appleDispositionRevision } = input;
  if (typeof binding.issuer !== "string" || !/^https:\/\/[a-zA-Z0-9.-]+$/.test(binding.issuer) ||
      typeof binding.instance !== "string" || !/^ins_[A-Za-z0-9]+$/.test(binding.instance) ||
      typeof binding.subject !== "string" || !/^user_[A-Za-z0-9]{1,250}$/.test(binding.subject) ||
      binding.owner !== `${binding.issuer}|${binding.subject}` || !ref(binding.revision)) return result("blocked", "invalid_binding");
  if (!["verifyInstance", "getUser", "deleteUser", "getSession", "revokeSession"].includes(operation)) return result("blocked", "invalid_operation");
  const sessionOperation = operation === "getSession" || operation === "revokeSession";
  if (sessionOperation ? typeof sessionId !== "string" || !/^sess_[A-Za-z0-9]{1,250}$/.test(sessionId) : sessionId !== undefined)
    return result("blocked", "invalid_target");
  if (typeof transport !== "function" || typeof credential !== "string" || !credential || credential.length > 4096 || /[\s\u0000-\u001f\u007f]/.test(credential))
    return result("blocked", "missing_transport_or_credential");
  const destructive = operation === "deleteUser" || operation === "revokeSession";
  if (destructive && (!ref(appleDispositionRevision) || typeof authorize !== "function")) return result("blocked", "authorization_prerequisite_missing");
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const cancel = (response: Response) => { void response.body?.cancel().catch(() => {}); };
  const alive = () => { if (controller.signal.aborted) throw new Stop(result("unknown", "transport_timeout")); };
  async function json(response: Response): Promise<unknown> {
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
        size += value.length;
        if (size > CLERK_TRANSPORT_MAX_BYTES) { abort(); block("response_too_large", response.status); }
        chunks.push(value);
      }
      const bytes = new Uint8Array(size); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
      catch { return block("malformed_response", response.status); }
    } finally { controller.signal.removeEventListener("abort", abort); reader.releaseLock(); }
  }
  async function request(path: string, method: "GET" | "POST" | "DELETE", allowAbsence = false): Promise<Record<string, unknown>> {
    alive();
    if (method !== "GET") {
      // Last asynchronous prerequisite immediately before dispatch. The worker must
      // check its gate, binding/config, lease/fence AND durable Apple revision here.
      const context = Object.freeze({ binding, operation, ...(sessionId ? { sessionId } : {}), appleDispositionRevision: appleDispositionRevision! });
      let allowed: boolean;
      try { allowed = await authorize!(context); }
      catch { return block("authorization_check_failed"); }
      alive();
      if (allowed !== true) block("authorization_withdrawn");
    }
    const response = await transport(`https://api.clerk.com/v1/${path}`, {
      method, redirect: "error", signal: controller.signal,
      headers: { Authorization: `Bearer ${credential}`, "Clerk-API-Version": CLERK_API_VERSION, Accept: "application/json" },
    });
    if (controller.signal.aborted) { cancel(response); alive(); }
    const status = response.status;
    if (status !== 200 && !(status === 404 && allowAbsence)) {
      cancel(response);
      if (status === 408 || status === 429 || status >= 500) throw new Stop(result("unknown", "provider_temporary", status));
      block("provider_rejected", status);
    }
    const body = await json(response);
    if (!record(body)) block("malformed_response", status);
    if (status === 404) {
      if (Array.isArray(body.errors) && body.errors.length === 1 && record(body.errors[0]) && body.errors[0].code === "resource_not_found")
        throw new Stop(result("absence_observed", sessionOperation ? "session_absent_not_revoked" : "user_absent", status));
      block("malformed_response", status);
    }
    return body;
  }
  try {
    return await Promise.race([
      (async (): Promise<ClerkTransportResult> => {
        const instance = await request("instance", "GET");
        if (instance.object !== "instance" || instance.id !== binding.instance) block("instance_mismatch", 200);
        if (operation === "verifyInstance") return result("observed", "instance_bound", 200);
        const path = sessionOperation ? `sessions/${sessionId}` : `users/${binding.subject}`;
        const target = await request(path, "GET", true);
        if (sessionOperation) {
          if (target.object !== "session" || target.id !== sessionId || target.user_id !== binding.subject) block("session_identity_mismatch", 200);
          if (!statuses.includes(target.status as string)) block("malformed_response", 200);
        } else if (target.object !== "user" || target.id !== binding.subject) block("user_identity_mismatch", 200);
        if (!destructive) return result("observed", sessionOperation ? "session_bound" : "user_bound", 200);
        const response = await request(operation === "revokeSession" ? `${path}/revoke` : path, operation === "revokeSession" ? "POST" : "DELETE", true);
        if (operation === "revokeSession") {
          if (response.object !== "session" || response.id !== sessionId || response.user_id !== binding.subject) block("session_identity_mismatch", 200);
          if (response.status !== "revoked") block("session_not_revoked", 200);
          return result("session_revoked", "exact_session_revoked", 200);
        }
        // DeletedObject.object is a string, not an enum; id is optional in the schema.
        if (typeof response.object !== "string" || response.deleted !== true ||
            (response.id !== undefined && response.id !== binding.subject)) block("invalid_delete_acknowledgement", 200);
        return result("acknowledgement", "user_delete_acknowledged_observation_required", 200);
      })(),
      new Promise<ClerkTransportResult>(resolve => {
        timer = setTimeout(() => { controller.abort(); resolve(result("unknown", "transport_timeout")); }, CLERK_TRANSPORT_TIMEOUT_MS);
      }),
    ]);
  } catch (error) {
    if (error instanceof Stop) {
      // Blocked means stop automatic progress, NOT proof that no side effect occurred.
      return error.value;
    }
    return result("unknown", "transport_unknown");
  } finally { if (timer !== undefined) clearTimeout(timer); }
}
