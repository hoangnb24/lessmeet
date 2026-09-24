// No SDK retries: the durable worker owns the attempt budget and scheduling.
export const MAX_ATTEMPTS = 8;
export const LEASE_MS = 90_000;
export const ACTION_TIMEOUT_MS = 20_000;
export type DeletionKind = "geminiFile" | "clerk" | "apple" | "revenuecat" | "gemini" | "residuals";
export type DeletionResult = {
  state: "succeeded" | "retry" | "blocked";
  code: string;
  httpStatus?: number;
  retryAfterMs?: number;
};
export const automationEnabled = () => process.env.DELETION_AUTOMATION_ENABLED === "true";
export function geminiProjectRef(): string | undefined {
  const ref = process.env.GEMINI_DELETION_PROJECT_REF;
  return ref && /^[A-Za-z0-9_-]{1,100}$/.test(ref) ? ref : undefined;
}
export function retryDelay(attempt: number, jitter: number, retryAfterMs = 0): number {
  const base = Math.min(6 * 3600_000, 30_000 * 2 ** Math.min(30, Math.max(0, attempt - 1)));
  return Math.ceil(Math.max(Math.min(6 * 3600_000, base * (1 + Math.min(1, Math.max(0, jitter)) / 2)), retryAfterMs));
}
function retryAfter(value: string | null): number | undefined {
  if (!value) return undefined;
  const delay = /^\d+(\.\d+)?$/.test(value) ? Number(value) * 1000 : Date.parse(value) - Date.now();
  return Number.isFinite(delay) && delay >= 0 && delay <= Number.MAX_SAFE_INTEGER - Date.now() ? delay : undefined;
}
async function boundedJSON(response: Response): Promise<unknown> {
  const reader = response.body?.getReader();
  if (!reader) throw new Error("Missing body");
  let size = 0; const chunks: Uint8Array[] = [];
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > 16 * 1024) { await reader.cancel(); throw new Error("Oversized body"); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
}

export async function executeDeletion(input: { kind: DeletionKind; target: string; config: string }): Promise<DeletionResult> {
  if (!automationEnabled()) return { state: "blocked", code: "automation_disabled" };
  // These providers intentionally have no executable adapters, including no success fixtures.
  if (input.kind !== "geminiFile") return { state: "blocked", code: "adapter_unimplemented" };
  if (!/^files\/[A-Za-z0-9_-]+$/.test(input.target)) return { state: "blocked", code: "invalid_target" };
  if (!geminiProjectRef() || input.config !== geminiProjectRef()) return { state: "blocked", code: "config_mismatch" };
  const key = process.env.GEMINI_API_KEY;
  if (!key) return { state: "blocked", code: "missing_secret" };
  // A timeout covers fetching AND reading the body. Abort is not provider cancellation.
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      (async (): Promise<DeletionResult> => {
        const response = await fetch(`https://generativelanguage.googleapis.com/v1beta/${input.target}`, {
          method: "DELETE", headers: { "x-goog-api-key": key }, redirect: "error", signal: controller.signal,
        });
        const httpStatus = response.status;
        if (httpStatus === 429 || httpStatus === 408 || (httpStatus >= 500 && httpStatus !== 501)) {
          const retryAfterMs = retryAfter(response.headers.get("retry-after"));
          await response.body?.cancel();
          return { state: "retry", code: "provider_temporary", httpStatus, ...(retryAfterMs === undefined ? {} : { retryAfterMs }) };
        }
        if (httpStatus !== 200 && httpStatus !== 404) {
          await response.body?.cancel();
          return { state: "blocked", code: "provider_rejected", httpStatus };
        }
        let body: unknown;
        try { body = await boundedJSON(response); }
        catch { return { state: "blocked", code: "malformed_response", httpStatus }; }
        if (httpStatus === 200 && body !== null && typeof body === "object" && !Array.isArray(body) && Object.keys(body).length === 0) {
          return { state: "succeeded", code: "deleted", httpStatus };
        }
        const error = (body as { error?: { code?: unknown; status?: unknown } } | null)?.error;
        if (httpStatus === 404 && error?.code === 404 && error.status === "NOT_FOUND") {
          return { state: "succeeded", code: "absent", httpStatus };
        }
        return { state: "blocked", code: "malformed_response", httpStatus };
      })(),
      new Promise<DeletionResult>(resolve => {
        timer = setTimeout(() => { controller.abort(); resolve({ state: "retry", code: "transport_unknown" }); }, ACTION_TIMEOUT_MS);
      }),
    ]);
  } catch { return { state: "retry", code: "transport_unknown" }; }
  finally { if (timer !== undefined) clearTimeout(timer); }
}
