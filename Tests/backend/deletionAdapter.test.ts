import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { executeDeletion, retryDelay } from "../../convex/deletionAdapter";

beforeEach(() => {
  vi.stubEnv("DELETION_AUTOMATION_ENABLED", "true");
  vi.stubEnv("GEMINI_DELETION_PROJECT_REF", "synthetic-project-v1");
  vi.stubEnv("GEMINI_API_KEY", "synthetic-only");
  vi.stubGlobal("fetch", vi.fn(() => { throw new Error("Network forbidden"); }));
});
afterEach(() => { vi.unstubAllGlobals(); vi.unstubAllEnvs(); vi.useRealTimers(); });
const target = { kind: "geminiFile" as const, target: "files/synthetic", config: "synthetic-project-v1" };

it("fails closed without the separate automation switch or key and blocks unimplemented providers", async () => {
  vi.stubEnv("DELETION_AUTOMATION_ENABLED", undefined);
  expect(await executeDeletion(target)).toMatchObject({ state: "blocked", code: "automation_disabled" });
  vi.stubEnv("DELETION_AUTOMATION_ENABLED", "true");
  vi.stubEnv("GEMINI_API_KEY", undefined);
  expect(await executeDeletion(target)).toMatchObject({ state: "blocked", code: "missing_secret" });
  expect(await executeDeletion({ kind: "clerk", target: "alice", config: "unimplemented" })).toMatchObject({ state: "blocked", code: "adapter_unimplemented" });
  expect(fetch).not.toHaveBeenCalled();
});

it("uses exact known resource and acknowledges only documented success or structured absence", async () => {
  vi.mocked(fetch).mockResolvedValueOnce(Response.json({}));
  expect(await executeDeletion(target)).toEqual({ state: "succeeded", code: "deleted", httpStatus: 200 });
  expect(fetch).toHaveBeenCalledWith("https://generativelanguage.googleapis.com/v1beta/files/synthetic", expect.objectContaining({
    method: "DELETE", redirect: "error", headers: { "x-goog-api-key": "synthetic-only" }, signal: expect.any(AbortSignal),
  }));
  vi.mocked(fetch).mockResolvedValueOnce(Response.json({ error: { code: 404, status: "NOT_FOUND" } }, { status: 404 }));
  expect(await executeDeletion(target)).toEqual({ state: "succeeded", code: "absent", httpStatus: 404 });
});

it("backoff is bounded and honors a longer provider delay", () => {
  expect(retryDelay(1, 0)).toBe(30_000);
  expect(retryDelay(2, 1)).toBe(90_000);
  expect(retryDelay(20, 1)).toBe(6 * 3600_000);
  expect(retryDelay(2, 0, 24 * 3600_000)).toBe(24 * 3600_000);
  expect(Number.isInteger(retryDelay(1, 0.123456789))).toBe(true);
});

it.each(["clerk", "apple", "revenuecat", "gemini", "residuals"] as const)("%s never simulates success", async kind => {
  expect(await executeDeletion({ kind, target: "alice", config: "unimplemented" })).toEqual({ state: "blocked", code: "adapter_unimplemented" });
  expect(fetch).not.toHaveBeenCalled();
});

it("rejects wrong project and non-exact paths before transport", async () => {
  for (const file of ["files/../bob", "files/alice?key=secret", "https://evil.test/files/a", "files/a/b", "files/"]) {
    expect(await executeDeletion({ ...target, target: file })).toMatchObject({ state: "blocked", code: "invalid_target" });
  }
  expect(await executeDeletion({ ...target, config: "other-project" })).toMatchObject({ state: "blocked", code: "config_mismatch" });
  vi.stubEnv("GEMINI_DELETION_PROJECT_REF", undefined);
  expect(await executeDeletion(target)).toMatchObject({ state: "blocked", code: "config_mismatch" });
  expect(fetch).not.toHaveBeenCalled();
});

it.each([400, 401, 403, 409, 422, 501, 302, 204])("HTTP %s is an exception, not disappearance", async status => {
  vi.mocked(fetch).mockResolvedValue(new Response(null, { status }));
  expect(await executeDeletion(target)).toEqual({ state: "blocked", code: "provider_rejected", httpStatus: status });
});

it.each([
  [200, "null"], [200, "[]"], [200, '{"error":"private upstream text"}'],
  [200, "not JSON"], [404, "<h1>Not found</h1>"], [404, '{"error":{"code":404,"status":"PERMISSION_DENIED"}}'],
  [404, "{}"], [200, "x".repeat(16385)],
])("rejects malformed response (%s), without retaining its text", async (status, body) => {
  vi.mocked(fetch).mockResolvedValue(new Response(String(body), { status: Number(status) }));
  expect(await executeDeletion(target)).toEqual({ state: "blocked", code: "malformed_response", httpStatus: Number(status) });
});

it("honors numeric and HTTP-date Retry-After and ignores malformed delays", async () => {
  vi.useFakeTimers(); vi.setSystemTime(new Date("2026-09-23T00:00:00Z"));
  for (const status of [408, 429, 500, 502, 503, 504]) {
    vi.mocked(fetch).mockResolvedValueOnce(new Response(null, { status, headers: { "Retry-After": "90000" } }));
    expect(await executeDeletion(target)).toEqual({ state: "retry", code: "provider_temporary", httpStatus: status, retryAfterMs: 90_000_000 });
  }
  vi.mocked(fetch).mockResolvedValueOnce(new Response(null, { status: 429, headers: { "Retry-After": "Thu, 24 Sep 2026 00:00:00 GMT" } }));
  expect(await executeDeletion(target)).toMatchObject({ retryAfterMs: 86400_000 });
  vi.mocked(fetch).mockResolvedValueOnce(new Response(null, { status: 429, headers: { "Retry-After": "not-a-delay" } }));
  expect(await executeDeletion(target)).not.toHaveProperty("retryAfterMs");
});

it("bounds a hanging fetch and hanging response body to 20 seconds", async () => {
  vi.useFakeTimers();
  vi.mocked(fetch).mockImplementationOnce(() => new Promise(() => {}));
  const pending = executeDeletion(target);
  await vi.advanceTimersByTimeAsync(20_000);
  expect(await pending).toEqual({ state: "retry", code: "transport_unknown" });
  expect((vi.mocked(fetch).mock.calls[0][1]?.signal as AbortSignal).aborted).toBe(true);
  vi.mocked(fetch).mockResolvedValueOnce(new Response(new ReadableStream({ start() {} })));
  const body = executeDeletion(target);
  await vi.advanceTimersByTimeAsync(20_000);
  expect(await body).toEqual({ state: "retry", code: "transport_unknown" });
});

it("transport exceptions are ambiguous and sanitized", async () => {
  vi.mocked(fetch).mockRejectedValue(new Error("secret-token private-data"));
  expect(await executeDeletion(target)).toEqual({ state: "retry", code: "transport_unknown" });
});
