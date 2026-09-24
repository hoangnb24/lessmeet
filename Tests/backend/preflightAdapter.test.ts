import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { aliasCursor, aliasPath, preflightConfig, readPreflightPage } from "../../convex/preflightAdapter";
import { PAGE_SIZE, type Target } from "../../convex/preflightContract";
import { ACTION_TIMEOUT_MS } from "../../convex/deletionAdapter";
import { CLERK_API_VERSION } from "../../convex/notificationAdapter";

const issuer = "https://synthetic.clerk.accounts.dev", subject = "user_alice", instance = "ins_synthetic", project = "projSynthetic";
const owner = `${issuer}|${subject}`;
const target = (provider: Target["provider"] = "clerk", changes: Partial<Target> = {}): Target => ({
  provider, owner, subject, config: preflightConfig(provider)!, phase: provider === "clerk" ? "user" : "customer", cursor: "", ...changes,
});
const user = (changes = {}) => ({ object: "user", id: subject, external_accounts: [], ...changes });
const customer = (changes = {}) => ({ object: "customer", id: subject, project_id: project, ...changes });
const aliases = (ids: string[], next: string | null = null) => ({ object: "list", url: aliasPath(project, subject),
  items: ids.map(id => ({ object: "customer.alias", id, created_at: 0 })), next_page: next });
function clerk(body: unknown, status = 200) {
  vi.mocked(fetch).mockResolvedValueOnce(Response.json({ object: "instance", id: instance })).mockResolvedValueOnce(Response.json(body, { status }));
}
beforeEach(() => {
  vi.useFakeTimers(); vi.setSystemTime(new Date("2026-09-24T00:00:00Z"));
  for (const key of ["DELETION_AUTOMATION_ENABLED", "DELETION_PREFLIGHT_ENABLED", "DELETION_PREFLIGHT_RETENTION_APPROVED", "REVENUECAT_PREFLIGHT_PROJECT_VERIFIED"]) vi.stubEnv(key, "true");
  vi.stubEnv("CLERK_JWT_ISSUER_DOMAIN", issuer); vi.stubEnv("CLERK_CONTACT_ISSUER", issuer); vi.stubEnv("CLERK_CONTACT_INSTANCE_ID", instance);
  vi.stubEnv("CLERK_PREFLIGHT_CONFIG_REF", "clerk-v1"); vi.stubEnv("CLERK_CONTACT_SECRET_KEY", "synthetic-clerk");
  vi.stubEnv("REVENUECAT_PREFLIGHT_CONFIG_REF", "rc-v1"); vi.stubEnv("REVENUECAT_PREFLIGHT_PROJECT_ID", project); vi.stubEnv("REVENUECAT_PREFLIGHT_SECRET_KEY", "synthetic-v2-read");
  vi.stubGlobal("fetch", vi.fn(() => { throw new Error("No network"); }));
});
afterEach(() => {
  for (const [url, init] of vi.mocked(fetch).mock.calls) {
    const u = new URL(String(url));
    expect(init?.method).toBe("GET"); expect(init?.redirect).toBe("error");
    expect(u.origin === "https://api.clerk.com" ? /^\/v1\/(instance|users\/user_[A-Za-z0-9]+|sessions)$/.test(u.pathname) :
      u.origin === "https://api.revenuecat.com" && /^\/v2\/projects\/proj[A-Za-z0-9]+\/customers\/user_[A-Za-z0-9]+(\/aliases)?$/.test(u.pathname)).toBe(true);
    if (u.origin === "https://api.clerk.com") expect(new Headers(init?.headers).get("Clerk-API-Version")).toBe(CLERK_API_VERSION);
  }
  vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllEnvs(); vi.unstubAllGlobals();
});
describe("read-only provider preflight wire contracts", () => {
  it.each(["DELETION_AUTOMATION_ENABLED", "DELETION_PREFLIGHT_ENABLED", "DELETION_PREFLIGHT_RETENTION_APPROVED"])("requires %s", async key => {
    vi.stubEnv(key, undefined); expect(await readPreflightPage(target())).toMatchObject({ state: "blocked", code: "disabled" }); expect(fetch).not.toHaveBeenCalled();
  });
  it.each(["CLERK_CONTACT_ISSUER", "CLERK_CONTACT_INSTANCE_ID", "CLERK_PREFLIGHT_CONFIG_REF"])("blocks missing binding %s", async key => {
    const t = target(); vi.stubEnv(key, undefined); expect(await readPreflightPage(t)).toMatchObject({ code: "config_changed" }); expect(fetch).not.toHaveBeenCalled();
  });
  it.each([{ owner: "other|user_alice" }, { subject: "user_bob" }, { subject: "user_a/../oauth_access_tokens" }, { config: "different" }])("blocks exact identity/config mismatch %j", async change => {
    expect(await readPreflightPage(target("clerk", change))).toMatchObject({ state: "blocked" }); expect(fetch).not.toHaveBeenCalled();
  });
  it.each(["REVENUECAT_PREFLIGHT_CONFIG_REF", "REVENUECAT_PREFLIGHT_PROJECT_ID", "REVENUECAT_PREFLIGHT_PROJECT_VERIFIED"])("requires separate RC attestation %s", async key => {
    const t = target("revenuecat"); vi.stubEnv(key, undefined); expect(await readPreflightPage(t)).toMatchObject({ code: "config_changed" }); expect(fetch).not.toHaveBeenCalled();
  });
  it.each(["clerk", "revenuecat"] as const)("does not fall back to other credentials for %s", async provider => {
    vi.stubEnv(provider === "clerk" ? "CLERK_CONTACT_SECRET_KEY" : "REVENUECAT_PREFLIGHT_SECRET_KEY", undefined);
    vi.stubEnv("REVENUECAT_SECRET_API_KEY", "forbidden-v1-key"); expect(await readPreflightPage(target(provider))).toMatchObject({ code: "missing_secret" }); expect(fetch).not.toHaveBeenCalled();
  });
  it("checks the instance before exact user and strips every non-inventory field", async () => {
    clerk(user({ external_accounts: [{ object: "external_account", id: "eac_apple", provider: "oauth_apple", provider_user_id: "apple.123", email_address: "secret@example.com", access_token: "NEVER" }], private_metadata: { secret: "NEVER" } }));
    expect(await readPreflightPage(target())).toEqual({ state: "page", code: "inventory_observed", externalAccounts: [{ id: "eac_apple", provider: "oauth_apple", providerUserId: "apple.123" }] });
    expect(vi.mocked(fetch).mock.calls.map(c => c[0])).toEqual(["https://api.clerk.com/v1/instance", `https://api.clerk.com/v1/users/${subject}`]);
  });
  it("rejects wrong instance without a user read", async () => {
    vi.mocked(fetch).mockResolvedValue(Response.json({ object: "instance", id: "ins_other" }));
    expect(await readPreflightPage(target())).toMatchObject({ code: "instance_mismatch" }); expect(fetch).toHaveBeenCalledTimes(1);
  });
  it.each([user({ id: "user_other" }), { data: user() }, user({ external_accounts: null }), user({ external_accounts: [{ object: "external_account", id: "eac_a", provider: "oauth_apple" }] })])("rejects incomplete/wrapped user inventory %#", async body => {
    clerk(body); expect(await readPreflightPage(target())).toMatchObject({ state: "blocked" });
  });
  it("uses the pinned REST session array with no active-only filter", async () => {
    clerk(Array.from({ length: PAGE_SIZE }, (_, i) => ({ object: "session", id: `sess_${i}`, user_id: subject, status: "revoked", latest_activity: { ip_address: "NEVER" } })));
    const result = await readPreflightPage(target("clerk", { phase: "sessions", cursor: "0" }));
    expect(result).toMatchObject({ state: "page", next: String(PAGE_SIZE) }); expect(JSON.stringify(result)).not.toContain("NEVER");
    expect(vi.mocked(fetch).mock.calls[1][0]).toBe(`https://api.clerk.com/v1/sessions?user_id=${subject}&limit=${PAGE_SIZE}&offset=0`);
  });
  it("ends session inventory only on a short page", async () => {
    clerk([]); expect(await readPreflightPage(target("clerk", { phase: "sessions", cursor: "32" }))).toEqual({ state: "page", code: "inventory_observed", sessions: [] });
  });
  it.each([{ data: [], totalCount: 0 }, [{ object: "session", id: "sess_a", user_id: "user_other", status: "active" }], [{ object: "session", id: "sess_a", user_id: subject, status: "unknown" }]])("rejects SDK wrappers/session mismatches %#", async body => {
    clerk(body); expect(await readPreflightPage(target("clerk", { phase: "sessions", cursor: "0" }))).toMatchObject({ state: "blocked" });
  });
  it.each(["-1", "1", "Infinity", "../x", "288"])("rejects invalid session cursor %s", async cursor => {
    vi.mocked(fetch).mockResolvedValue(Response.json({ object: "instance", id: instance }));
    expect(await readPreflightPage(target("clerk", { phase: "sessions", cursor }))).toMatchObject({ code: "invalid_continuation" }); expect(fetch).toHaveBeenCalledTimes(1);
  });
  it("performs only a noncreating exact RC v2 customer read", async () => {
    vi.mocked(fetch).mockResolvedValue(Response.json(customer())); expect(await readPreflightPage(target("revenuecat"))).toEqual({ state: "page", code: "inventory_observed" });
    expect(vi.mocked(fetch).mock.calls[0][0]).toBe(`https://api.revenuecat.com/v2/projects/${project}/customers/${subject}`);
    expect(new Headers(vi.mocked(fetch).mock.calls[0][1]?.headers).get("Authorization")).toBe("Bearer synthetic-v2-read");
  });
  it.each([customer({ project_id: "projOther" }), customer({ id: "user_other" }), { subscriber: { original_app_user_id: subject } }])("rejects wrong RC project/customer/v1 shapes %#", async body => {
    vi.mocked(fetch).mockResolvedValue(Response.json(body)); expect(await readPreflightPage(target("revenuecat"))).toMatchObject({ state: "blocked" });
  });
  it("extracts exact aliases and rebuilds the next route", async () => {
    const path = aliasPath(project, subject);
    vi.mocked(fetch).mockResolvedValue(Response.json(aliases(["$RCAnonymousID:abc"], `${path}?starting_after=%24RCAnonymousID%3Aabc&limit=32`)));
    expect(await readPreflightPage(target("revenuecat", { phase: "aliases", cursor: "user_prior" }))).toEqual({ state: "page", code: "inventory_observed", aliases: ["$RCAnonymousID:abc"], next: "$RCAnonymousID:abc" });
    expect(vi.mocked(fetch).mock.calls[0][0]).toBe(`https://api.revenuecat.com${path}?limit=32&starting_after=user_prior`);
  });
  it.each([
    "https://evil.example/x?starting_after=x", "https://api.revenuecat.com/v2/projects/projSynthetic/customers/user_alice/aliases?starting_after=x",
    "//evil.example/x", "/v2/projects/projOther/customers/user_alice/aliases?starting_after=x", "/v2/projects/projSynthetic/customers/user_bob/aliases?starting_after=x",
    "/v2/projects/projSynthetic/customers/user_alice/aliases/../attributes?starting_after=x", "/v2/projects/projSynthetic/customers/user_alice/aliases?starting_after=x&starting_after=y",
    "/v2/projects/projSynthetic/customers/user_alice/aliases?starting_after=x&secret=NEVER", "/v2/projects/projSynthetic/customers/user_alice/aliases?starting_after=x#fragment",
    "/v2/projects/projSynthetic/customers/user_alice/aliases?starting_after=x&limit=100", "/v2/projects/projSynthetic/customers/user_alice/aliases?starting_after=",
  ])("rejects unsafe continuation %s", async next => {
    expect(aliasCursor(next, project, subject)).toBeNull(); vi.mocked(fetch).mockResolvedValue(Response.json(aliases(["x"], next)));
    expect(await readPreflightPage(target("revenuecat", { phase: "aliases" }))).toMatchObject({ code: "invalid_continuation" }); expect(fetch).toHaveBeenCalledTimes(1);
  });
  it.each([{}, { next_page: undefined }, { items: [{ object: "customer.alias", id: "" }] }, { url: "/wrong" }, { next_page: `${aliasPath(project, subject)}?starting_after=not-last` }])("rejects malformed alias pages %#", async change => {
    const body = Object.keys(change).length ? { ...aliases([subject]), ...change } : {};
    vi.mocked(fetch).mockResolvedValue(Response.json(body)); expect(await readPreflightPage(target("revenuecat", { phase: "aliases" }))).toMatchObject({ state: "blocked" });
  });
  it.each(["clerk", "revenuecat"] as const)("records structured %s 404 as unavailable inventory, never completion", async provider => {
    const body = provider === "clerk" ? { errors: [{ code: "resource_not_found", message: "NEVER" }] } : { type: "resource_missing", message: "NEVER" };
    if (provider === "clerk") clerk(body, 404); else vi.mocked(fetch).mockResolvedValue(Response.json(body, { status: 404 }));
    expect(await readPreflightPage(target(provider))).toEqual({ state: "blocked", code: "resource_absent_inventory_unavailable" });
  });
  it.each([401, 403, 400, 422, 302])("blocks rejected status %s with no leaked body", async status => {
    vi.mocked(fetch).mockResolvedValue(Response.json({ message: "NEVER" }, { status })); expect(await readPreflightPage(target("revenuecat"))).toEqual({ state: "blocked", code: "provider_rejected" });
  });
  it("rejects generic 404", async () => {
    vi.mocked(fetch).mockResolvedValue(Response.json({ message: "Not found" }, { status: 404 })); expect(await readPreflightPage(target("revenuecat"))).toMatchObject({ code: "malformed_response" });
  });
  it.each([408, 423, 429, 500, 503])("honors longer provider backoff on %s", async status => {
    vi.mocked(fetch).mockResolvedValue(Response.json({ backoff_ms: 100_000, message: "NEVER" }, { status, headers: { "Retry-After": "80" } }));
    expect(await readPreflightPage(target("revenuecat"))).toEqual({ state: "retry", code: "provider_temporary", retryAfterMs: 100_000 });
  });
  it("honors HTTP-date Retry-After and ignores unsafe backoff", async () => {
    vi.mocked(fetch).mockResolvedValue(Response.json({ backoff_ms: 1e100 }, { status: 429, headers: { "Retry-After": new Date(Date.now() + 300_000).toUTCString() } }));
    expect(await readPreflightPage(target("revenuecat"))).toMatchObject({ retryAfterMs: 300_000 });
  });
  it.each(["not-json", "x".repeat(65 * 1024)])("bounds malformed/body bytes %#", async body => {
    vi.mocked(fetch).mockResolvedValue(new Response(body)); expect(await readPreflightPage(target("revenuecat"))).toMatchObject({ code: "malformed_response" });
  });
  it.each(["fetch", "body"])("bounds hung %s and aborts", async kind => {
    vi.mocked(fetch).mockImplementation(async () => kind === "fetch" ? new Promise<Response>(() => {}) : new Response(new ReadableStream({ start() {} })));
    const p = readPreflightPage(target("revenuecat")); await vi.advanceTimersByTimeAsync(ACTION_TIMEOUT_MS);
    expect(await p).toEqual({ state: "retry", code: "transport_unknown" }); expect(vi.mocked(fetch).mock.calls[0][1]?.signal?.aborted).toBe(true);
  });
  it("stops before the next read if config changes during instance lookup", async () => {
    vi.mocked(fetch).mockImplementation(async () => { vi.stubEnv("CLERK_PREFLIGHT_CONFIG_REF", "changed"); return Response.json({ object: "instance", id: instance }); });
    expect(await readPreflightPage(target())).toMatchObject({ code: "config_changed" }); expect(fetch).toHaveBeenCalledTimes(1);
  });
});
