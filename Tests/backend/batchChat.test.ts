import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "../../convex/schema";
import { internal } from "../../convex/_generated/api";
import { nativeM4aFixture } from "./nativeMediaFixture";
import { sha256 } from "../../convex/batchContract";

const modules = import.meta.glob(["../../convex/**/*.{ts,js}", "!../../convex/**/*.d.ts", "!../../convex/auth.config.ts"]);
const base = "/v1/transcription-batches", chat = base + "/chat", provider = "https://generativelanguage.googleapis.com";
const uuid = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const post = (body: unknown) => ({ method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
const raw = '{"version":1,"segments":[{"startMs":0,"endMs":1250,"speaker":"A","text":"Synthetic meeting"},{"startMs":null,"endMs":null,"speaker":null,"text":"Uncertain alternative"}]}';
let answer: string, outcome: string | undefined, unknown: boolean, plan: "free" | "pro", chatCalls: number;
const fetchMock = vi.fn(async (url: string | URL | Request, init?: RequestInit): Promise<Response> => {
  const path = String(url);
  if (path.startsWith("https://api.revenuecat.com/")) {
    const product = "com.lessmeet.app.pro.monthly", purchase = "2026-09-01T00:00:00Z", expires = "2026-10-01T00:00:00Z";
    return Response.json({ request_date_ms: Date.now(), subscriber: { original_app_user_id: "alice",
      entitlements: plan === "pro" ? { lessmeet_pro: { product_identifier: product, purchase_date: purchase, expires_date: expires } } : {},
      subscriptions: plan === "pro" ? { [product]: { original_purchase_date: purchase, purchase_date: purchase, expires_date: expires, refunded_at: null, is_sandbox: false, store: "app_store", ownership_type: "PURCHASED" } } : {} } });
  }
  if (path === `${provider}/upload/v1beta/files`) return new Response(null, { headers: { "x-goog-upload-url": `${provider}/upload/session` } });
  if (path === `${provider}/upload/session`) return Response.json({ file: { name: "files/test", uri: `${provider}/v1beta/files/test`, state: "ACTIVE" } });
  if (path === `${provider}/v1beta/files/test` && init?.method === "DELETE") return new Response(null, { status: 204 });
  if (path === `${provider}/v1beta/interactions`) {
    const isChat = String(init?.body).includes("Complete batch context");
    if (isChat) { chatCalls++; if (unknown) throw new Error("Lost synthetic response"); }
    return Response.json({ status: isChat ? outcome : "completed", steps: [{ type: "model_output", content: [{ type: "text", text: isChat ? answer : raw }] }] });
  }
  throw new Error("Unexpected mocked URL");
});
function setup() {
  const t = convexTest({ schema, modules, transactionLimits: true });
  return { t, alice: t.withIdentity({ tokenIdentifier: "issuer|alice", issuer: "issuer", subject: "alice" }), bob: t.withIdentity({ tokenIdentifier: "other|alice", issuer: "other", subject: "alice" }) };
}
type Test = ReturnType<typeof setup>;
async function complete(test: Test) {
  const audio = nativeM4aFixture(), hash = await sha256(audio);
  const manifest = { version: 1, source: { sha256: hash, bytes: audio.byteLength, duration: { value: 5, timescale: 4 } }, chunks: [{ sha256: hash, bytes: audio.byteLength }] };
  const created = await test.alice.fetch(base, post({ clientBatchId: uuid(1), manifest })); expect(created.status).toBe(201);
  const b = await created.json();
  expect((await test.alice.fetch(`${base}/chunk?batchId=${b.batchId}&index=0`, { method: "PUT", headers: { "Content-Type": "audio/m4a" }, body: audio })).status).toBe(200);
  expect((await test.alice.fetch(`${base}/seal`, post({ batchId: b.batchId, manifestDigest: b.manifestDigest }))).status).toBe(202);
  await test.t.finishAllScheduledFunctions(vi.runAllTimers);
  const status = await (await test.alice.fetch(`${chat}?batchId=${b.batchId}`)).json(); expect(status.availability).toBe("ready");
  return { b, status, request: { batchId: b.batchId, clientMessageId: uuid(2), expectedContextDigest: status.contextDigest, expectedHistoryRevision: status.revision, message: "What was discussed?" } };
}
const getStatus = async (alice: Test["alice"], id: string) => (await alice.fetch(`${chat}?batchId=${id}`)).json();
const quota = (t: Test["t"]) => t.run(ctx => ctx.db.query("quotaBuckets").collect());
beforeEach(() => {
  vi.useFakeTimers(); vi.setSystemTime(Date.parse("2026-09-25T00:00:00Z"));
  for (const name of ["BATCH_TRANSCRIPTION_ENABLED", "BATCH_CHAT_ENABLED", "GEMINI_BILLABLE_ENABLED", "BILLING_ENFORCEMENT_ENABLED", "REVENUECAT_ORIGINAL_USER_POLICY_CONFIRMED", "ACCOUNT_DELETION_ENABLED"]) vi.stubEnv(name, "true");
  vi.stubEnv("BATCH_TRANSCRIPTION_OWNER", "issuer|alice"); vi.stubEnv("GEMINI_API_KEY", "synthetic-placeholder"); vi.stubEnv("REVENUECAT_SECRET_API_KEY", "sk_synthetic_placeholder");
  vi.stubEnv("GEMINI_MODEL", "gemini-flash-latest");
  answer = "A synthetic answer"; outcome = "completed"; unknown = false; plan = "free"; chatCalls = 0; fetchMock.mockClear(); vi.stubGlobal("fetch", fetchMock);
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); });

describe("durable batch chat HTTP / actual SDK / mocked provider", () => {
  it.each(["in_progress", "requires_action", "future_unknown_status", undefined])("holds unproven provider status %s until late exact completion", async providerStatus => {
    const test = setup(), { b, request } = await complete(test); outcome = providerStatus;
    await test.alice.fetch(chat + "/message", post(request)); await test.t.finishAllScheduledFunctions(vi.runAllTimers);
    const status = await getStatus(test.alice, b.batchId);
    expect(status).toMatchObject({ revision: 0, availability: "attention", pending: { state: "unknown", quota: "reserved", text: null } });
    expect((await quota(test.t))[0]).toMatchObject({ questionsReserved: 1, questionsUsed: 0 });
    expect((await test.alice.fetch(chat + "/message", post({ ...request, clientMessageId: uuid(3) }))).status).toBe(409);
    const op = (await test.t.run(ctx => ctx.db.query("batchChatOperations").first()))!;
    expect(op.phase).toBe("intent"); expect(op.work).toBeDefined();
    expect(await test.t.run(ctx => ctx.db.get(op.work!))).toMatchObject({ generationStarted: true, generationFinished: false });
    vi.advanceTimersByTime(180000); await test.t.mutation(internal.batchChat.recover, {});
    expect((await quota(test.t))[0].questionsReserved).toBe(1);
    const completion = { id: op._id, fence: op.fence, outcome: "completed" as const, text: "Late proven reply" };
    await test.t.mutation(internal.batchChat.finish, completion); await test.t.mutation(internal.batchChat.finish, completion);
    const settled = await getStatus(test.alice, b.batchId);
    expect(settled.revision).toBe(1); expect(settled.pending).toBeNull(); expect(settled.exchanges).toHaveLength(1);
    expect(settled.exchanges[0].reply).toBe(completion.text);
    expect((await quota(test.t))[0]).toMatchObject({ questionsReserved: 0, questionsUsed: 1 }); expect(chatCalls).toBe(1);
  });
  it.each(["failed", "cancelled", "incomplete", "completed"])("settles proven terminal %s with unusable reply once", async providerStatus => {
    const test = setup(), { b, request } = await complete(test); outcome = providerStatus;
    if (providerStatus === "completed") answer = "";
    await test.alice.fetch(chat + "/message", post(request)); await test.t.finishAllScheduledFunctions(vi.runAllTimers);
    const receipt = await (await test.alice.fetch(`${chat}/message?batchId=${b.batchId}&clientMessageId=${request.clientMessageId}`)).json();
    expect(receipt).toMatchObject({ state: "failed", quota: "released", text: null });
    expect((await quota(test.t))[0]).toMatchObject({ questionsReserved: 0, questionsUsed: 0 });
    const op = (await test.t.run(ctx => ctx.db.query("batchChatOperations").first()))!;
    await test.t.mutation(internal.batchChat.finish, { id: op._id, fence: op.fence, outcome: "completed", text: "Not a new result" });
    expect((await getStatus(test.alice, b.batchId)).exchanges).toHaveLength(0);
    expect((await test.alice.fetch(chat + "/message", post({ ...request, clientMessageId: uuid(3) }))).status).toBe(202);
    expect(chatCalls).toBe(1);
  });
  it("uses complete raw context, appends durable history and consumes exactly one question", async () => {
    const test = setup(), { b, request } = await complete(test);
    const response = await test.alice.fetch(chat + "/message", post(request)); expect(response.status).toBe(202);
    const queued = await response.json(); expect(queued).toMatchObject({ state: "queued", quota: "reserved", text: null, error: null });
    await test.t.finishAllScheduledFunctions(vi.runAllTimers);
    const status = await getStatus(test.alice, b.batchId);
    expect(status).toMatchObject({ availability: "ready", pending: null, exchanges: [{ clientMessageId: request.clientMessageId, contextDigest: request.expectedContextDigest, message: request.message, reply: answer }] });
    const receipt = await (await test.alice.fetch(`${chat}/message?batchId=${b.batchId}&clientMessageId=${request.clientMessageId}`)).json();
    expect(receipt).toMatchObject({ state: "succeeded", quota: "consumed", text: answer, revision: 3 }); expect(status.revision).toBe(1);
    expect((await quota(test.t))[0]).toMatchObject({ questionsUsed: 1, questionsReserved: 0 }); expect(chatCalls).toBe(1);
    const call = fetchMock.mock.calls.find(c => String(c[1]?.body).includes("Complete batch context"))!;
    const wire = JSON.parse(String(call[1]!.body)); expect(wire).toMatchObject({ store: false, model: "gemini-flash-latest" });
    expect(JSON.stringify(wire)).toContain("Uncertain alternative"); expect(JSON.stringify(wire)).toContain("Synthetic meeting");
    expect(await test.t.run(ctx => ctx.db.query("deletionWork").collect())).toHaveLength(0);
    expect(await test.t.run(ctx => ctx.db.query("batchChatContexts").collect())).toHaveLength(1);
  });
  it("recovers a lost response by exact identity and replays without new billing, quota or generation", async () => {
    const test = setup(), { b, request } = await complete(test);
    expect((await test.alice.fetch(chat + "/message", post(request))).status).toBe(202);
    const calls = fetchMock.mock.calls.length;
    expect((await test.alice.fetch(chat + "/message", post(request))).status).toBe(202); expect(fetchMock.mock.calls).toHaveLength(calls);
    expect((await test.alice.fetch(`${chat}/message?batchId=${b.batchId}&clientMessageId=${request.clientMessageId}`)).status).toBe(200);
    expect((await test.alice.fetch(chat + "/message", post({ ...request, message: "Changed" }))).status).toBe(409);
    expect((await test.alice.fetch(chat + "/message", post({ ...request, expectedHistoryRevision: 999 }))).status).toBe(409);
    await test.t.finishAllScheduledFunctions(vi.runAllTimers);
    vi.stubEnv("BATCH_CHAT_ENABLED", "false"); vi.stubEnv("BATCH_TRANSCRIPTION_ENABLED", "false"); vi.stubEnv("BATCH_TRANSCRIPTION_OWNER", undefined);
    const before = fetchMock.mock.calls.length;
    const replay = await test.alice.fetch(chat + "/message", post(request)); expect(replay.status).toBe(200); expect((await replay.json()).text).toBe(answer);
    expect((await getStatus(test.alice, b.batchId)).exchanges).toHaveLength(1); expect(fetchMock.mock.calls).toHaveLength(before); expect(chatCalls).toBe(1);
  });
  it("excludes concurrent/new questions and another issuer before billing", async () => {
    const test = setup(), { b, request } = await complete(test);
    const before = fetchMock.mock.calls.length;
    expect((await test.bob.fetch(chat + "/message", post(request))).status).toBe(404);
    expect((await test.bob.fetch(`${chat}?batchId=${b.batchId}`)).status).toBe(404); expect(fetchMock.mock.calls).toHaveLength(before);
    await test.alice.fetch(chat + "/message", post(request));
    const after = fetchMock.mock.calls.length;
    expect((await test.alice.fetch(chat + "/message", post({ ...request, clientMessageId: uuid(3) }))).status).toBe(409); expect(fetchMock.mock.calls).toHaveLength(after);
    const op = (await test.t.run(ctx => ctx.db.query("batchChatOperations").first()))!;
    expect(await test.t.mutation(internal.batchChat.claim, { id: op._id })).not.toBeNull();
    expect(await test.t.mutation(internal.batchChat.claim, { id: op._id })).toBeNull();
  });
  it("holds unknown generation and permits a late same-fence reply to settle exactly once", async () => {
    const test = setup(), { b, request } = await complete(test); unknown = true;
    await test.alice.fetch(chat + "/message", post(request)); await test.t.finishAllScheduledFunctions(vi.runAllTimers);
    const status = await getStatus(test.alice, b.batchId); expect(status).toMatchObject({ availability: "attention", pending: { state: "unknown", quota: "reserved" } });
    expect((await quota(test.t))[0]).toMatchObject({ questionsUsed: 0, questionsReserved: 1 }); expect(chatCalls).toBe(1);
    vi.advanceTimersByTime(200000); await test.t.mutation(internal.batchChat.recover, {}); await test.t.finishAllScheduledFunctions(vi.runAllTimers);
    expect((await quota(test.t))[0].questionsReserved).toBe(1);
    const op = (await test.t.run(ctx => ctx.db.query("batchChatOperations").first()))!;
    vi.stubEnv("BATCH_CHAT_ENABLED", "false");
    await test.t.mutation(internal.batchChat.finish, { id: op._id, fence: op.fence + 1, outcome: "completed", text: "wrong fence" });
    const completion = { id: op._id, fence: op.fence, outcome: "completed" as const, text: "Late exact reply" };
    await test.t.mutation(internal.batchChat.finish, completion); await test.t.mutation(internal.batchChat.finish, completion);
    expect((await getStatus(test.alice, b.batchId)).exchanges).toHaveLength(1); expect((await quota(test.t))[0]).toMatchObject({ questionsUsed: 1, questionsReserved: 0 }); expect(chatCalls).toBe(1);
  });
  it.each(["incomplete", "oversize", "plan_change", "disabled"])("releases known %s failure without generating again", async failure => {
    const test = setup(), { b, request } = await complete(test);
    await test.alice.fetch(chat + "/message", post(request));
    if (failure === "incomplete") outcome = "incomplete";
    if (failure === "oversize") answer = "x".repeat(32767);
    if (failure === "plan_change") plan = "pro";
    if (failure === "disabled") vi.stubEnv("BATCH_CHAT_ENABLED", "false");
    await test.t.finishAllScheduledFunctions(vi.runAllTimers);
    const op = await (await test.alice.fetch(`${chat}/message?batchId=${b.batchId}&clientMessageId=${request.clientMessageId}`)).json();
    expect(op).toMatchObject({ state: "failed", quota: "released", text: null }); expect((await quota(test.t))[0]).toMatchObject({ questionsUsed: 0, questionsReserved: 0 });
    expect(chatCalls).toBe(["incomplete", "oversize"].includes(failure) ? 1 : 0); expect((await getStatus(test.alice, b.batchId)).exchanges).toHaveLength(0);
  });
  it("removes content before quota buckets and prevents late reply resurrection during deletion", async () => {
    const test = setup(), { request } = await complete(test); unknown = true;
    await test.alice.fetch(chat + "/message", post(request)); await test.t.finishAllScheduledFunctions(vi.runAllTimers);
    const op = (await test.t.run(ctx => ctx.db.query("batchChatOperations").first()))!;
    expect((await test.alice.fetch("/account/deletion", post({ confirm: "delete-account" }))).status).toBe(202); await test.t.finishAllScheduledFunctions(vi.runAllTimers);
    const tombstone = await test.t.run(ctx => ctx.db.get(op._id)); expect(tombstone).toMatchObject({ deleted: true, quota: "released" });
    for (const key of ["message", "historyText", "context", "contextDigest", "text", "expectedRevision", "reservation"]) expect(tombstone).not.toHaveProperty(key);
    expect(await test.t.run(ctx => ctx.db.query("batchChats").collect())).toHaveLength(0); expect(await test.t.run(ctx => ctx.db.query("batchChatContexts").collect())).toHaveLength(0); expect(await quota(test.t)).toHaveLength(0);
    await test.t.mutation(internal.batchChat.finish, { id: op._id, fence: op.fence, outcome: "completed", text: "Late sensitive reply" }); await test.t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(await test.t.run(ctx => ctx.db.query("batchChatOperations").collect())).toHaveLength(0); expect(await test.t.run(ctx => ctx.db.query("batchChats").collect())).toHaveLength(0); expect(await test.t.run(ctx => ctx.db.query("deletionWork").collect())).toHaveLength(0);
  });
  it("binds concurrent admission to a single identity and pending question", async () => {
    const test = setup(), { request } = await complete(test);
    const responses = await Promise.all([test.alice.fetch(chat + "/message", post(request)), test.alice.fetch(chat + "/message", post(request))]);
    expect(responses.some(r => r.status === 202)).toBe(true);
    expect(responses.every(r => [202, 409].includes(r.status))).toBe(true);
    const recovered = await test.alice.fetch(chat + "/message", post(request)); expect(recovered.status).toBe(202);
    expect(await test.t.run(ctx => ctx.db.query("batchChatOperations").collect())).toHaveLength(1); expect((await quota(test.t))[0].questionsReserved).toBe(1);
    await test.t.finishAllScheduledFunctions(vi.runAllTimers); expect(chatCalls).toBe(1);
  });
  it("keeps completed-history revisions independent from operation transitions", async () => {
    const test = setup(), { b, request } = await complete(test);
    const response = await test.alice.fetch(chat + "/message", post(request));
    expect((await response.json()).revision).toBe(1);
    expect((await getStatus(test.alice, b.batchId)).revision).toBe(0);
    unknown = true; await test.t.finishAllScheduledFunctions(vi.runAllTimers);
    const status = await getStatus(test.alice, b.batchId);
    expect(status.revision).toBe(0); expect(status.pending.revision).toBe(3);
    const op = (await test.t.run(ctx => ctx.db.query("batchChatOperations").first()))!;
    await test.t.mutation(internal.batchChat.finish, { id: op._id, fence: op.fence, outcome: "completed", text: answer });
    expect((await getStatus(test.alice, b.batchId)).revision).toBe(1);
    const next = { ...request, clientMessageId: uuid(3), expectedHistoryRevision: 1 };
    expect((await (await test.alice.fetch(chat + "/message", post(next))).json()).revision).toBe(1);
    vi.stubEnv("BATCH_CHAT_ENABLED", "false"); await test.t.finishAllScheduledFunctions(vi.runAllTimers);
    const final = await getStatus(test.alice, b.batchId); expect(final.revision).toBe(1); expect(final.exchanges).toHaveLength(1);
    const failed = await (await test.alice.fetch(`${chat}/message?batchId=${b.batchId}&clientMessageId=${next.clientMessageId}`)).json();
    expect(failed).toMatchObject({ revision: 2, state: "failed" });
  });
  it("checks context overflow and history space before any billing refresh or reservation", async () => {
    const test = setup(), { b, request } = await complete(test);
    await test.t.run(async ctx => {
      const chunk = (await ctx.db.query("transcriptionChunks").first())!;
      await ctx.db.patch(chunk._id, { rawText: JSON.stringify({ version: 1, segments: Array.from({ length: 2048 }, () => ({ startMs: 0, endMs: 1, speaker: "a", text: "x".repeat(80) })) }) });
    });
    expect((await getStatus(test.alice, b.batchId)).availability).toBe("context_too_large");
    let before = fetchMock.mock.calls.length;
    const response = await test.alice.fetch(chat + "/message", post(request)); expect(response.status).toBe(409);
    expect((await response.json()).error.code).toBe("context_too_large"); expect(fetchMock.mock.calls).toHaveLength(before); expect((await quota(test.t))[0].questionsReserved).toBe(0);
    await test.t.run(async ctx => {
      const chunk = (await ctx.db.query("transcriptionChunks").first())!; await ctx.db.patch(chunk._id, { rawText: raw });
      await ctx.db.insert("batchChats", { owner: chunk.owner, parent: chunk.parent, revision: 20,
        exchanges: Array.from({ length: 20 }, (_, i) => ({ clientMessageId: uuid(100 + i), contextDigest: request.expectedContextDigest, message: "Question", reply: "Reply" })) });
    });
    expect((await getStatus(test.alice, b.batchId)).availability).toBe("history_full"); before = fetchMock.mock.calls.length;
    const full = await test.alice.fetch(chat + "/message", post({ ...request, expectedHistoryRevision: 20 }));
    expect(full.status).toBe(409); expect((await full.json()).error.code).toBe("history_full"); expect(fetchMock.mock.calls).toHaveLength(before);
  });
  it("accepts escaped 8 KiB messages but refuses decoded/message-body overflow and duplicate keys", async () => {
    const test = setup(), { request } = await complete(test), before = fetchMock.mock.calls.length;
    expect((await test.alice.fetch(chat + "/message", post({ ...request, message: "x".repeat(8193) }))).status).toBe(400);
    expect((await test.alice.fetch(chat + "/message", { ...post(request), body: '{"batchId":"x","batchId":"y"}' })).status).toBe(400);
    expect((await test.alice.fetch(chat + "/message", { ...post(request), body: "x".repeat(50177) })).status).toBe(413); expect(fetchMock.mock.calls).toHaveLength(before);
    const escaped = { ...request, message: "\u0001".repeat(8192) };
    expect(JSON.stringify(escaped).length).toBeLessThanOrEqual(50176);
    expect((await test.alice.fetch(chat + "/message", post(escaped))).status).toBe(202); await test.t.finishAllScheduledFunctions(vi.runAllTimers);
    const status = await getStatus(test.alice, request.batchId); expect(status.exchanges[0].message).toBe(escaped.message);
    expect(new TextEncoder().encode(JSON.stringify(status)).length).toBeLessThanOrEqual(256 * 1024);
  });
  it("uses every saved exchange in the next prompt and rejects stale context/history fields", async () => {
    const test = setup(), { b, request } = await complete(test);
    await test.alice.fetch(chat + "/message", post(request)); await test.t.finishAllScheduledFunctions(vi.runAllTimers);
    const status = await getStatus(test.alice, b.batchId), next = { ...request, clientMessageId: uuid(3), message: "Follow up", expectedHistoryRevision: status.revision };
    const before = fetchMock.mock.calls.length;
    expect((await test.alice.fetch(chat + "/message", post({ ...next, expectedContextDigest: "a".repeat(64) }))).status).toBe(409);
    expect((await test.alice.fetch(chat + "/message", post({ ...next, expectedHistoryRevision: 0 }))).status).toBe(409); expect(fetchMock.mock.calls).toHaveLength(before);
    await test.alice.fetch(chat + "/message", post(next)); await test.t.finishAllScheduledFunctions(vi.runAllTimers);
    const calls = fetchMock.mock.calls.filter(c => String(c[1]?.body).includes("Complete batch context"));
    expect(String(calls[1][1]?.body)).toContain(answer); expect(String(calls[1][1]?.body)).toContain(request.message);
    expect((await getStatus(test.alice, b.batchId)).exchanges).toHaveLength(2); expect((await quota(test.t))[0]).toMatchObject({ questionsUsed: 2, questionsReserved: 0 });
  });
  it("times out an intent to unknown without refund, then reconciles off with exact evidence", async () => {
    const test = setup(), { b, request } = await complete(test); await test.alice.fetch(chat + "/message", post(request));
    const op = (await test.t.run(ctx => ctx.db.query("batchChatOperations").first()))!;
    const job = (await test.t.mutation(internal.batchChat.claim, { id: op._id }))!;
    const billing = (await test.t.run(ctx => ctx.db.query("billingAccounts").first()))!;
    expect(await test.t.mutation(internal.batchChat.intent, { id: op._id, fence: job.fence, billingRevision: billing.revision })).toBe(true);
    vi.advanceTimersByTime(91000); await test.t.mutation(internal.batchChat.recover, {});
    expect((await getStatus(test.alice, b.batchId)).pending.state).toBe("unknown"); expect((await quota(test.t))[0].questionsReserved).toBe(1);
    vi.stubEnv("BATCH_CHAT_ENABLED", "false"); const args = { id: op._id, owner: op.owner, fence: job.fence, remoteStopped: true as const, evidence: "synthetic-proof" };
    await expect(test.t.mutation(internal.batchChat.reconcile, { ...args, owner: "wrong" })).rejects.toThrow();
    await test.t.mutation(internal.batchChat.reconcile, args); await test.t.mutation(internal.batchChat.reconcile, args);
    expect((await getStatus(test.alice, b.batchId)).pending).toBeNull(); expect((await quota(test.t))[0]).toMatchObject({ questionsUsed: 0, questionsReserved: 0 });
    await test.t.mutation(internal.batchChat.finish, { id: op._id, fence: job.fence, outcome: "completed", text: "Too late after reconciliation" });
    expect((await getStatus(test.alice, b.batchId)).exchanges).toHaveLength(0); expect(chatCalls).toBe(0);
  });
  it("deletes multiple pages of receipts without letting an unresolved early row hide later content", async () => {
    const test = setup(), { request } = await complete(test); unknown = true;
    await test.alice.fetch(chat + "/message", post(request)); await test.t.finishAllScheduledFunctions(vi.runAllTimers);
    const op = (await test.t.run(ctx => ctx.db.query("batchChatOperations").first()))!;
    await test.t.run(async ctx => {
      for (let i = 0; i < 25; i++) await ctx.db.insert("batchChatOperations", { owner: op.owner, parent: op.parent, subject: op.subject, clientMessageId: uuid(100 + i),
        message: "Private question", contextDigest: op.contextDigest, expectedRevision: 0, revision: 0, fence: 0, phase: "terminal", state: "failed", quota: "released", due: 0, deleted: false });
    });
    await test.alice.fetch("/account/deletion", post({ confirm: "delete-account" })); await test.t.finishAllScheduledFunctions(vi.runAllTimers);
    const receipts = await test.t.run(ctx => ctx.db.query("batchChatOperations").collect()); expect(receipts).toHaveLength(1); expect(receipts[0].deleted).toBe(true); expect(receipts[0].message).toBeUndefined();
    const deletion = (await test.t.run(ctx => ctx.db.query("deletions").first()))!;
    await test.t.mutation(internal.deletion.reconcileWork, { id: deletion._id, owner: deletion.owner, workId: op.work!, evidence: "synthetic-deletion-proof" }); await test.t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(await test.t.run(ctx => ctx.db.query("batchChatOperations").collect())).toHaveLength(0); expect(await quota(test.t)).toHaveLength(0);
  });
  it("refuses exhausted question quota without creating a receipt or context snapshot", async () => {
    const test = setup(), { request } = await complete(test);
    await test.t.run(async ctx => { const bucket = (await ctx.db.query("quotaBuckets").first())!; await ctx.db.patch(bucket._id, { questionsUsed: 20 }); });
    expect((await test.alice.fetch(chat + "/message", post(request))).status).toBe(429);
    expect(await test.t.run(ctx => ctx.db.query("batchChatOperations").collect())).toHaveLength(0);
    expect(await test.t.run(ctx => ctx.db.query("batchChatContexts").collect())).toHaveLength(0);
    expect((await quota(test.t))[0]).toMatchObject({ questionsUsed: 20, questionsReserved: 0 }); expect(chatCalls).toBe(0);
  });
  it("expires an unsubmitted claim once and permits only a fresh explicit question", async () => {
    const test = setup(), { b, request } = await complete(test);
    await test.alice.fetch(chat + "/message", post(request));
    const op = (await test.t.run(ctx => ctx.db.query("batchChatOperations").first()))!;
    await test.t.mutation(internal.batchChat.claim, { id: op._id });
    vi.advanceTimersByTime(121000); await test.t.mutation(internal.batchChat.recover, {}); await test.t.mutation(internal.batchChat.recover, {});
    expect((await quota(test.t))[0].questionsReserved).toBe(0);
    expect((await getStatus(test.alice, b.batchId)).revision).toBe(0);
    const replay = await test.alice.fetch(chat + "/message", post(request)); expect(replay.status).toBe(200); expect((await replay.json()).state).toBe("failed");
    expect(chatCalls).toBe(0);
    expect((await test.alice.fetch(chat + "/message", post({ ...request, clientMessageId: uuid(3) }))).status).toBe(202);
    await test.t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(chatCalls).toBe(1); expect((await quota(test.t))[0]).toMatchObject({ questionsReserved: 0, questionsUsed: 1 });
  });
});
