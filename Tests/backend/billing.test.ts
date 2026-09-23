import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "../../convex/schema";
import { internal } from "../../convex/_generated/api";
import type { Id } from "../../convex/_generated/dataModel";
import { replyToTranscript, transcribeAudio } from "../../convex/gemini";
import { monthlyWindow, parseEntitlement } from "../../convex/billingPolicy";
import { CHAT_TIMEOUT, JOB_TIMEOUT, MAX_REPLY, MAX_TRANSCRIPT } from "../../convex/limits";
import { audioSeconds } from "../../convex/media";
import { m4aFixture } from "./mediaFixture";
import { nativeM4aFixture } from "./nativeMediaFixture";

vi.mock("../../convex/gemini", () => ({
  replyToTranscript: vi.fn(), transcribeAudio: vi.fn(), safeFailure: () => "AI unavailable.", GeminiFailure: class extends Error {},
}));
const modules = import.meta.glob(["../../convex/**/*.{ts,js}", "!../../convex/**/*.d.ts", "!../../convex/auth.config.ts"]);
const product = "com.lessmeet.app.pro.yearly";
const start = Date.parse("2026-01-31T12:34:56.000Z");
const now = Date.parse("2026-02-15T12:00:00.000Z");
function customer(pro = false, subject = "alice") {
  return { request_date_ms: Date.now(), subscriber: { original_app_user_id: subject,
    entitlements: pro ? { lessmeet_pro: { product_identifier: product, purchase_date: new Date(start).toISOString(), expires_date: "2027-01-31T12:34:56.000Z" } } : {},
    subscriptions: pro ? { [product]: { original_purchase_date: new Date(start).toISOString(), purchase_date: new Date(start).toISOString(),
      expires_date: "2027-01-31T12:34:56.000Z", refunded_at: null, is_sandbox: false, store: "app_store", ownership_type: "PURCHASED",
      unsubscribe_detected_at: "2026-02-01T00:00:00Z" } } : {},
  } };
}
function setup() {
  const t = convexTest({ schema, modules, transactionLimits: true });
  return { t, alice: t.withIdentity({ tokenIdentifier: "issuer|alice", subject: "alice" }), bob: t.withIdentity({ tokenIdentifier: "issuer|bob", subject: "bob" }) };
}
type T = ReturnType<typeof setup>["t"];
const requestChat = (id: string, extra = {}) => ({ method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ recordingId: id, message: "Summarize this recording", ...extra }) });
const upload = () => ({ method: "POST", headers: { "Content-Type": "audio/mp4", "X-Audio-Duration": "0.001" }, body: m4aFixture() });
async function ready(t: T, owner = "issuer|alice") {
  return t.run(async ctx => {
    const audio = await ctx.storage.store(new Blob([m4aFixture()]));
    return ctx.db.insert("recordings", { owner, audio, mimeType: "audio/m4a", status: "ready", transcript: "Meeting", messages: [] });
  });
}
async function verify(alice: ReturnType<typeof setup>["alice"]) {
  const response = await alice.fetch("/billing");
  expect(response.status).toBe(200);
  return response.json();
}
async function revision(t: T) { return t.run(async ctx => (await ctx.db.query("billingAccounts").first())!.revision); }
async function buckets(t: T) { return t.run(ctx => ctx.db.query("quotaBuckets").collect()); }
beforeEach(() => {
  vi.useFakeTimers(); vi.setSystemTime(now); vi.resetAllMocks();
  vi.stubEnv("GEMINI_BILLABLE_ENABLED", "true"); vi.stubEnv("BILLING_ENFORCEMENT_ENABLED", "true");
  vi.stubEnv("REVENUECAT_ORIGINAL_USER_POLICY_CONFIRMED", "true"); vi.stubEnv("REVENUECAT_SECRET_API_KEY", "sk_fixture_not_real");
  vi.stubEnv("REVENUECAT_ALLOW_SANDBOX", undefined);
  vi.stubGlobal("fetch", vi.fn(async () => Response.json(customer())));
  vi.mocked(replyToTranscript).mockResolvedValue("Summary"); vi.mocked(transcribeAudio).mockResolvedValue({ text: "Transcript" });
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); });

describe("RevenueCat and billing identity", () => {
  it("requires auth, accepts bodyless sync, ignores no client identity or Pro claims", async () => {
    const { t, alice } = setup();
    expect((await t.fetch("/billing")).status).toBe(401);
    expect((await t.fetch("/billing/sync", { method: "POST" })).status).toBe(401);
    expect(fetch).not.toHaveBeenCalled();
    expect((await alice.fetch("/billing/sync", { method: "POST", body: JSON.stringify({ userId: "bob", pro: true }) })).status).toBe(400);
    expect((await alice.fetch("/billing?userId=bob")).status).toBe(400);
    const response = await alice.fetch("/billing/sync", { method: "POST" });
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ userId: "alice", enforcement: true, plan: "free", periodEndsAt: null, questions: { limit: 20, used: 0, reserved: 0 } });
    expect(fetch).toHaveBeenCalledWith("https://api.revenuecat.com/v1/subscribers/alice", expect.objectContaining({ redirect: "error", headers: { Authorization: "Bearer sk_fixture_not_real", Accept: "application/json" } }));
    expect(await t.run(ctx => ctx.db.query("billingAccounts").first())).toMatchObject({ owner: "issuer|alice", subject: "alice" });
  });
  it.each([undefined, "false"])("preserves development without lookups or accounting (%s)", async flag => {
    vi.stubEnv("BILLING_ENFORCEMENT_ENABLED", flag); vi.stubEnv("REVENUECAT_SECRET_API_KEY", undefined);
    const { t, alice } = setup();
    expect(await verify(alice)).toMatchObject({ enforcement: false, plan: "development", questions: { limit: 0, used: 0, reserved: 0 } });
    expect((await alice.fetch("/chat", requestChat(await ready(t)))).status).toBe(200);
    expect(fetch).not.toHaveBeenCalled(); expect(await buckets(t)).toEqual([]);
  });
  it.each([undefined, "false"])("requires confirmed restore policy (%s) before all work", async flag => {
    vi.stubEnv("REVENUECAT_ORIGINAL_USER_POLICY_CONFIRMED", flag);
    const { t, alice } = setup(), id = await ready(t);
    for (const [path, init] of [["/billing", undefined], ["/billing/sync", { method: "POST" }], ["/chat", requestChat(id)], ["/recordings", upload()]] as const) {
      expect((await alice.fetch(path, init)).status).toBe(503);
    }
    expect(fetch).not.toHaveBeenCalled(); expect(replyToTranscript).not.toHaveBeenCalled(); expect(transcribeAudio).not.toHaveBeenCalled();
  });
  it.each([404, 429, 500, 401])("does not interpret RC HTTP %s as verified Free", async status => {
    vi.mocked(fetch).mockResolvedValue(new Response("private diagnostic", { status }));
    const { alice } = setup(); const response = await alice.fetch("/billing");
    expect(response.status).toBe(503); expect(await response.text()).not.toContain("private diagnostic");
  });
  it("accepts a newly created verified free customer (201)", async () => {
    vi.mocked(fetch).mockResolvedValue(Response.json(customer(), { status: 201 }));
    expect((await verify(setup().alice)).plan).toBe("free");
  });
  it.each([undefined, "appl_public_key"])("requires a private server key (%s)", async key => {
    vi.stubEnv("REVENUECAT_SECRET_API_KEY", key);
    const { t, alice } = setup();
    expect((await alice.fetch("/billing")).status).toBe(503);
    expect((await alice.fetch("/chat", requestChat(await ready(t)))).status).toBe(503);
    expect(fetch).not.toHaveBeenCalled(); expect(replyToTranscript).not.toHaveBeenCalled();
  });
  it("accepts the monthly product and never grants Pro for wrong products, stores or family sharing", () => {
    const annual = customer(true);
    const monthly = { ...annual, subscriber: { ...annual.subscriber,
      entitlements: { lessmeet_pro: { ...annual.subscriber.entitlements.lessmeet_pro!, product_identifier: "com.lessmeet.app.pro.monthly" } },
      subscriptions: { "com.lessmeet.app.pro.monthly": annual.subscriber.subscriptions[product] },
    } };
    expect(parseEntitlement(monthly, "alice", now).plan).toBe("pro");
    for (const [field, value] of [["store", "test_store"], ["ownership_type", "FAMILY_SHARED"]]) {
      const bad = customer(true); (bad.subscriber.subscriptions[product] as Record<string, unknown>)[field] = value;
      expect(() => parseEntitlement(bad, "alice", now)).toThrow();
    }
    const bad = customer(true); bad.subscriber.entitlements.lessmeet_pro!.product_identifier = "lifetime";
    expect(() => parseEntitlement(bad, "alice", now)).toThrow();
  });
  it("rejects unavailable, malformed, stale and transferred evidence before Gemini", async () => {
    const { t, alice, bob } = setup(), id = await ready(t);
    expect((await bob.fetch("/chat", requestChat(id))).status).toBe(404); expect(fetch).not.toHaveBeenCalled();
    for (const payload of [{}, { ...customer(), request_date_ms: now - 31_000 }, customer(true, "bob")]) {
      vi.mocked(fetch).mockResolvedValue(Response.json(payload));
      expect((await alice.fetch("/chat", requestChat(id))).status).not.toBe(200);
    }
    vi.mocked(fetch).mockRejectedValue(new Error("network timeout with private data"));
    expect((await alice.fetch("/chat", requestChat(id))).status).toBe(503);
    expect(replyToTranscript).not.toHaveBeenCalled(); expect(await buckets(t)).toEqual([]);
  });
  it("rejects sandbox unless explicitly opted in and rejects missing evidence/lifetime grants", async () => {
    const value = customer(true); value.subscriber.subscriptions[product]!.is_sandbox = true;
    expect(() => parseEntitlement(value, "alice", now)).toThrow();
    vi.stubEnv("REVENUECAT_ALLOW_SANDBOX", "true"); expect(parseEntitlement(value, "alice", now).plan).toBe("pro");
    for (const field of ["original_purchase_date", "refunded_at", "ownership_type", "is_sandbox"]) {
      const broken = customer(true); delete (broken.subscriber.subscriptions[product] as Record<string, unknown>)[field];
      expect(() => parseEntitlement(broken, "alice", now)).toThrow();
    }
    const lifetime = customer(true); (lifetime.subscriber.entitlements.lessmeet_pro as Record<string, unknown>).expires_date = null;
    expect(() => parseEntitlement(lifetime, "alice", now)).toThrow();
  });
  it("allows cancelled-but-active, downgrades expired and refunded; annual windows reset monthly", () => {
    const value = customer(true); expect(parseEntitlement(value, "alice", now).plan).toBe("pro");
    value.subscriber.subscriptions[product]!.refunded_at = "2026-02-10T00:00:00Z" as never;
    expect(parseEntitlement(value, "alice", now).plan).toBe("free");
    const expired = customer(true); expired.subscriber.entitlements.lessmeet_pro!.expires_date = "2026-02-01T00:00:00Z";
    expect(parseEntitlement(expired, "alice", now).plan).toBe("free");
    expect(monthlyWindow(start, now)).toEqual({ start, end: Date.parse("2026-02-28T12:34:56Z") });
    expect(monthlyWindow(start, Date.parse("2026-03-01T00:00:00Z"))).toEqual({ start: Date.parse("2026-02-28T12:34:56Z"), end: Date.parse("2026-03-31T12:34:56Z") });
    expect(monthlyWindow(Date.parse("2024-01-31T00:00:00Z"), Date.parse("2024-02-29T00:00:00Z"))).toEqual({ start: Date.parse("2024-02-29T00:00:00Z"), end: Date.parse("2024-03-31T00:00:00Z") });
  });
  it("rejects out-of-order verification and invalidates old evidence while refreshing", async () => {
    const { t, alice } = setup(); await verify(alice);
    const first = await revision(t);
    const next = await t.mutation(internal.billing.beginVerification, { owner: "issuer|alice", subject: "alice" });
    await expect(alice.mutation(internal.billing.status, { revision: first })).rejects.toThrow();
    await expect(t.mutation(internal.billing.applyVerification, { owner: "issuer|alice", subject: "alice", revision: first, ...parseEntitlement(customer(), "alice", now) })).rejects.toThrow();
    await t.mutation(internal.billing.applyVerification, { owner: "issuer|alice", subject: "alice", revision: next, ...parseEntitlement(customer(), "alice", now) });
    expect((await alice.mutation(internal.billing.status, { revision: next })).plan).toBe("free");
    const newer = await t.mutation(internal.billing.beginVerification, { owner: "issuer|alice", subject: "alice" });
    await expect(t.mutation(internal.billing.applyVerification, { owner: "issuer|alice", subject: "alice", revision: newer,
      ...parseEntitlement(customer(), "alice", now), observedAt: now - 1 })).rejects.toThrow();
  });
  it("requires new verification after TTL/expiry rather than reusing cached Pro", async () => {
    const { t, alice } = setup(), id = await ready(t);
    vi.mocked(fetch).mockImplementation(async () => Response.json(customer(true)));
    await verify(alice); const rev = await revision(t);
    vi.setSystemTime(now + 30_001);
    await expect(alice.mutation(internal.recordings.reserveChat, { id, message: "Q", lease: "stale", revision: rev })).rejects.toThrow();
    vi.setSystemTime(Date.parse("2027-01-31T12:34:56Z"));
    expect((await verify(alice)).plan).toBe("free");
    expect(replyToTranscript).not.toHaveBeenCalled();
  });
});

describe("atomic allowances and leases", () => {
  it("isolates both allowance buckets and original RevenueCat identity across accounts", async () => {
    const { t, alice, bob } = setup();
    await alice.fetch("/chat", requestChat(await ready(t)));
    expect((await bob.fetch("/billing")).status).toBe(403); // RC says original Alice, not Bob.
    vi.mocked(fetch).mockImplementation(async () => Response.json(customer(false, "bob")));
    expect((await verify(bob)).questions.used).toBe(0);
    await bob.fetch("/chat", requestChat(await ready(t, "issuer|bob")));
    expect((await buckets(t)).map(b => [b.owner, b.questionsUsed]).sort()).toEqual([["issuer|alice", 1], ["issuer|bob", 1]]);
  });
  it("blocks exhausted questions before Gemini, counts summary/action-item chat once", async () => {
    const { t, alice } = setup(), id = await ready(t);
    expect((await alice.fetch("/chat", requestChat(id, { userId: "bob", plan: "pro" }))).status).toBe(200);
    let status = await verify(alice); expect(status.questions).toEqual({ limit: 20, used: 1, reserved: 0 });
    const [bucket] = await buckets(t); await t.run(ctx => ctx.db.patch(bucket._id, { questionsUsed: 20 }));
    expect((await alice.fetch("/chat", requestChat(id))).status).toBe(429);
    expect(replyToTranscript).toHaveBeenCalledOnce(); status = await verify(alice); expect(status.questions.used).toBe(20);
  });
  it("rolls back failures and releases exactly once; timeout prevents late persistence and charge", async () => {
    const { t, alice } = setup(), id = await ready(t);
    vi.mocked(replyToTranscript).mockRejectedValueOnce(new Error("provider failed"));
    expect((await alice.fetch("/chat", requestChat(id))).status).toBe(502);
    expect((await verify(alice)).questions).toEqual({ limit: 20, used: 0, reserved: 0 });
    const rev = await revision(t);
    await alice.mutation(internal.recordings.reserveChat, { id, message: "Action items?", lease: "old", revision: rev });
    expect((await buckets(t))[0].questionsReserved).toBe(1);
    vi.setSystemTime(now + CHAT_TIMEOUT);
    await expect(alice.mutation(internal.recordings.finishChat, { id, lease: "old", message: "Action items?", text: "Late" })).rejects.toThrow();
    await t.mutation(internal.recordings.releaseChat, { id, lease: "old" });
    await t.mutation(internal.recordings.releaseChat, { id, lease: "old" });
    expect((await buckets(t))[0]).toMatchObject({ questionsUsed: 0, questionsReserved: 0 });
    expect((await t.run(ctx => ctx.db.get(id)))!.messages).toEqual([]);
  });
  it("allows only one concurrent reservation for the last question across recordings", async () => {
    const { t, alice } = setup(), a = await ready(t), b = await ready(t);
    await verify(alice); const rev = await revision(t);
    await t.run(ctx => ctx.db.insert("quotaBuckets", { owner: "issuer|alice", window: "free", secondsUsed: 0, secondsReserved: 0, questionsUsed: 19, questionsReserved: 0 }));
    const outcomes = await Promise.allSettled([a, b].map((id, i) => alice.mutation(internal.recordings.reserveChat, { id, message: "Q", lease: `lease${i}`, revision: rev })));
    expect(outcomes.filter(r => r.status === "fulfilled")).toHaveLength(1);
    expect((await buckets(t))[0]).toMatchObject({ questionsUsed: 19, questionsReserved: 1 }); expect(replyToTranscript).not.toHaveBeenCalled();
  });
  it("atomically rolls back quota when result validation fails", async () => {
    const { t, alice } = setup(), id = await ready(t);
    vi.mocked(replyToTranscript).mockResolvedValueOnce("x".repeat(MAX_REPLY + 1));
    expect((await alice.fetch("/chat", requestChat(id))).status).toBe(502);
    expect((await buckets(t))[0]).toMatchObject({ questionsUsed: 0, questionsReserved: 0 });
    expect((await t.run(ctx => ctx.db.get(id)))!.messages).toEqual([]);
    const { recordingId } = await (await alice.fetch("/recordings", upload())).json();
    vi.mocked(transcribeAudio).mockResolvedValueOnce({ text: "x".repeat(MAX_TRANSCRIPT + 1) });
    await t.action(internal.jobs.transcribe, { id: recordingId });
    expect((await buckets(t))[0]).toMatchObject({ secondsUsed: 0, secondsReserved: 0 });
    expect(await t.run(ctx => ctx.db.get(recordingId as Id<"recordings">))).toMatchObject({ status: "failed" });
  });
  it("serializes concurrent transcription exhaustion with recording creation and scheduling", async () => {
    const { t, alice } = setup(); await verify(alice); const rev = await revision(t);
    const audio = await t.run(ctx => ctx.storage.store(new Blob([m4aFixture()])));
    await t.run(ctx => ctx.db.insert("quotaBuckets", { owner: "issuer|alice", window: "free", secondsUsed: 7199, secondsReserved: 0, questionsUsed: 0, questionsReserved: 0 }));
    const outcomes = await Promise.allSettled([1, 2].map(() => alice.mutation(internal.recordings.create, { audio, mimeType: "audio/m4a", seconds: 1, revision: rev })));
    expect(outcomes.filter(r => r.status === "fulfilled")).toHaveLength(1);
    expect(await t.run(ctx => ctx.db.query("recordings").collect())).toHaveLength(1);
    expect(await t.run(ctx => ctx.db.system.query("_scheduled_functions").collect())).toHaveLength(2);
    expect((await buckets(t))[0]).toMatchObject({ secondsUsed: 7199, secondsReserved: 1 });
  });
  it("scheduled lease expiry releases reservations once and cannot clear a newer lease", async () => {
    const { t, alice } = setup(), id = await ready(t); await verify(alice);
    await alice.mutation(internal.recordings.reserveChat, { id, message: "Q", lease: "old", revision: await revision(t) });
    vi.advanceTimersByTime(CHAT_TIMEOUT); await t.finishInProgressScheduledFunctions();
    expect((await buckets(t))[0].questionsReserved).toBe(0);
    await verify(alice);
    await alice.mutation(internal.recordings.reserveChat, { id, message: "Q", lease: "new", revision: await revision(t) });
    await t.mutation(internal.recordings.releaseChat, { id, lease: "old" });
    expect((await buckets(t))[0].questionsReserved).toBe(1);
    await expect(alice.mutation(internal.recordings.finishChat, { id, lease: "old", message: "Q", text: "Late" })).rejects.toThrow();
    expect((await t.run(ctx => ctx.db.get(id)))!.chatLease).toBe("new");
  });
  it("preserves free usage and pins Pro usage across sync, refund/downgrade and repurchase", async () => {
    const { t, alice } = setup(), id = await ready(t);
    await alice.fetch("/chat", requestChat(id));
    vi.mocked(fetch).mockImplementation(async () => Response.json(customer(true)));
    await alice.fetch("/chat", requestChat(id));
    expect((await verify(alice)).questions).toEqual({ limit: 200, used: 1, reserved: 0 });
    expect((await verify(alice)).questions.used).toBe(1);
    vi.mocked(fetch).mockImplementation(async () => Response.json(customer()));
    expect((await verify(alice)).questions).toEqual({ limit: 20, used: 1, reserved: 0 });
    vi.mocked(fetch).mockImplementation(async () => {
      const value = customer(true); value.subscriber.subscriptions[product]!.original_purchase_date = "2026-02-01T00:00:00Z";
      value.subscriber.subscriptions[product]!.purchase_date = "2026-02-01T00:00:00Z"; return Response.json(value);
    });
    expect((await verify(alice)).questions.used).toBe(1);
  });
  it("settles old-window in-flight work in its old bucket, new month gets only its own grant", async () => {
    const { t, alice } = setup(), id = await ready(t);
    vi.mocked(fetch).mockImplementation(async () => Response.json(customer(true)));
    const boundary = Date.parse("2026-02-28T12:34:56Z"); vi.setSystemTime(boundary - 1000);
    await verify(alice);
    await alice.mutation(internal.recordings.reserveChat, { id, message: "Q", lease: "old", revision: await revision(t) });
    vi.setSystemTime(boundary + 1000);
    expect((await verify(alice)).questions).toEqual({ limit: 200, used: 0, reserved: 0 });
    await alice.mutation(internal.recordings.finishChat, { id, message: "Q", lease: "old", text: "Done" });
    expect((await buckets(t))[0]).toMatchObject({ questionsUsed: 1, questionsReserved: 0 });
    expect((await verify(alice)).questions.used).toBe(0);
  });
  it("reserves server-derived transcription duration, refuses exhaustion and commits only saved success", async () => {
    const { t, alice } = setup();
    const response = await alice.fetch("/recordings", upload()); expect(response.status).toBe(202);
    const { recordingId } = await response.json();
    expect((await buckets(t))[0]).toMatchObject({ secondsUsed: 0, secondsReserved: 1 });
    await t.action(internal.jobs.transcribe, { id: recordingId });
    expect((await buckets(t))[0]).toMatchObject({ secondsUsed: 1, secondsReserved: 0 });
    const [bucket] = await buckets(t); await t.run(ctx => ctx.db.patch(bucket._id, { secondsUsed: 7200 }));
    expect((await alice.fetch("/recordings", upload())).status).toBe(429);
    expect(transcribeAudio).toHaveBeenCalledOnce();
    expect(await t.run(ctx => ctx.db.system.query("_storage").collect())).toHaveLength(1);
  });
  it("rechecks entitlement before queued paid work, releases failures and ignores late results", async () => {
    const { t, alice } = setup();
    const { recordingId } = await (await alice.fetch("/recordings", upload())).json();
    vi.mocked(fetch).mockResolvedValue(new Response("unavailable", { status: 500 }));
    await t.action(internal.jobs.transcribe, { id: recordingId });
    expect(transcribeAudio).not.toHaveBeenCalled(); expect((await buckets(t))[0].secondsReserved).toBe(0);
    vi.mocked(fetch).mockImplementation(async () => Response.json(customer()));
    const { recordingId: late } = await (await alice.fetch("/recordings", upload())).json();
    await t.mutation(internal.recordings.claimJob, { id: late }); vi.setSystemTime(now + JOB_TIMEOUT);
    await t.mutation(internal.recordings.finishJob, { id: late, transcript: "Too late" });
    await t.mutation(internal.recordings.expireJob, { id: late });
    expect((await buckets(t))[0]).toMatchObject({ secondsUsed: 0, secondsReserved: 0 });
    expect((await t.run(ctx => ctx.db.get(late as Id<"recordings">)))!.status).toBe("failed");
  });
  it("blocks legacy unreserved jobs when enforcement turns on and retains the kill switch", async () => {
    const { t, alice } = setup();
    vi.stubEnv("BILLING_ENFORCEMENT_ENABLED", "false");
    const { recordingId } = await (await alice.fetch("/recordings", upload())).json();
    vi.stubEnv("BILLING_ENFORCEMENT_ENABLED", "true");
    await t.action(internal.jobs.transcribe, { id: recordingId });
    expect(transcribeAudio).not.toHaveBeenCalled(); expect(await buckets(t)).toEqual([]);
    vi.stubEnv("GEMINI_BILLABLE_ENABLED", "false");
    expect((await alice.fetch("/chat", requestChat(await ready(t)))).status).toBe(503);
    expect((await alice.fetch("/recordings", upload())).status).toBe(503);
    expect((await alice.fetch("/billing")).status).toBe(200);
  });
});

describe("media validation", () => {
  it("accepts the actual native combined M4A through validation, HTTP and saved-job billing", async () => {
    const { t, alice } = setup();
    expect(audioSeconds(nativeM4aFixture(), "audio/m4a")).toBe(2);
    const response = await alice.fetch("/recordings", { ...upload(), body: nativeM4aFixture() });
    expect(response.status).toBe(202);
    expect((await buckets(t))[0]).toMatchObject({ secondsReserved: 2, secondsUsed: 0 });
    const { recordingId } = await response.json();
    await t.action(internal.jobs.transcribe, { id: recordingId });
    expect((await buckets(t))[0]).toMatchObject({ secondsReserved: 0, secondsUsed: 2 });
    expect(transcribeAudio).toHaveBeenCalledOnce();
  });
  it("derives rounded seconds from real AAC M4A bytes", () => { expect(audioSeconds(m4aFixture(), "audio/mp4")).toBe(1); });
  it("rejects unsupported, truncated, arbitrary and forged duration media", () => {
    expect(() => audioSeconds(m4aFixture(), "audio/wav")).toThrow();
    expect(() => audioSeconds(new TextEncoder().encode("not audio").buffer, "audio/mp4")).toThrow();
    expect(() => audioSeconds(m4aFixture().slice(0, -10), "audio/mp4")).toThrow();
    const bytes = new Uint8Array(m4aFixture()); const marker = new TextEncoder().encode("mdhd");
    const index = bytes.findIndex((_, i) => marker.every((b, j) => bytes[i + j] === b));
    new DataView(bytes.buffer).setUint32(index + 20, 1); // Forge the media header duration; actual sample timing disagrees.
    expect(() => audioSeconds(bytes.buffer, "audio/mp4")).toThrow();
  });
  it("rejects invalid media before storage, entitlement lookup or AI", async () => {
    const { t, alice } = setup();
    expect((await alice.fetch("/recordings", { ...upload(), body: "not media" })).status).toBe(415);
    expect((await alice.fetch("/recordings", { ...upload(), headers: { "Content-Type": "audio/wav" } })).status).toBe(415);
    expect(await t.run(ctx => ctx.db.system.query("_storage").collect())).toEqual([]);
    expect(fetch).not.toHaveBeenCalled(); expect(transcribeAudio).not.toHaveBeenCalled();
  });
});
