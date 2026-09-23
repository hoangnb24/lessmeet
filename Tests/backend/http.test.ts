import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "../../convex/schema";
import { internal } from "../../convex/_generated/api";
import type { Id } from "../../convex/_generated/dataModel";
import { CHAT_TIMEOUT, JOB_TIMEOUT, MAX_AUDIO, MAX_MESSAGE } from "../../convex/limits";
import { replyToTranscript, transcribeAudio } from "../../convex/gemini";

vi.mock("../../convex/gemini", () => ({
  replyToTranscript: vi.fn(), transcribeAudio: vi.fn(),
  safeFailure: () => "Gemini unavailable; no automatic retry was made.",
  GeminiFailure: class extends Error {},
}));
const modules = import.meta.glob(["../../convex/**/*.{ts,js}", "!../../convex/**/*.d.ts", "!../../convex/auth.config.ts"]);
const chat = (recordingId: string, message = "What happened?"): RequestInit => ({
  method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ recordingId, message }),
});
function setup() {
  const t = convexTest({ schema, modules, transactionLimits: true });
  return { t, alice: t.withIdentity({ tokenIdentifier: "issuer|alice", subject: "alice" }),
    bob: t.withIdentity({ tokenIdentifier: "issuer|bob", subject: "bob" }) };
}
async function fixture(t: ReturnType<typeof setup>["t"], status: "ready" | "queued" = "ready") {
  return t.run(async ctx => {
    const audio = await ctx.storage.store(new Blob(["test audio"], { type: "audio/m4a" }));
    return ctx.db.insert("recordings", { owner: "issuer|alice", audio, mimeType: "audio/m4a", status,
      transcript: status === "ready" ? "# Meeting\nWe agreed." : undefined, messages: [] });
  });
}
beforeEach(() => {
  vi.stubEnv("GEMINI_BILLABLE_ENABLED", "true");
  vi.useFakeTimers();
  vi.resetAllMocks();
  vi.stubGlobal("fetch", vi.fn(() => { throw new Error("External network forbidden in tests"); }));
  vi.mocked(transcribeAudio).mockResolvedValue({ text: "# Transcript" });
  vi.mocked(replyToTranscript).mockResolvedValue("Agreed.");
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); });

describe("authenticated HTTP and database ownership", () => {
  it.each([undefined, "false"])("blocks billable work even for an owner when the switch is %s", async enabled => {
    vi.stubEnv("GEMINI_BILLABLE_ENABLED", enabled);
    const { t, alice } = setup();
    const id = await fixture(t);
    expect((await alice.fetch("/recordings", { method: "POST", body: "not consumed" })).status).toBe(503);
    expect((await alice.fetch("/chat", chat(id))).status).toBe(503);
    expect((await alice.fetch(`/recordings?id=${id}`)).status).toBe(200);
    expect((await alice.fetch("/account")).status).toBe(200);
    expect(await t.run(ctx => ctx.db.query("recordings").collect())).toHaveLength(1);
    expect(await t.run(ctx => ctx.db.system.query("_storage").collect())).toHaveLength(1);
    const queued = await fixture(t, "queued");
    await t.action(internal.jobs.transcribe, { id: queued });
    expect((await t.run(ctx => ctx.db.get(queued)))!.status).toBe("failed");
    expect(transcribeAudio).not.toHaveBeenCalled();
    expect(replyToTranscript).not.toHaveBeenCalled();
    expect(fetch).not.toHaveBeenCalled();
  });

  it("rejects anonymous requests before storage/provider work, retaining /account", async () => {
    const { t, alice } = setup();
    for (const [path, init] of [["/account", undefined], ["/recordings?id=bad", undefined],
      ["/recordings", { method: "POST", body: "not audio" }], ["/chat", chat("bad")]] as const) {
      expect((await t.fetch(path, init)).status).toBe(401);
    }
    expect(await (await alice.fetch("/account")).json()).toEqual({ userId: "alice" });
    expect(await t.run(ctx => ctx.db.system.query("_storage").collect())).toEqual([]);
    expect(await t.run(ctx => ctx.db.query("recordings").collect())).toEqual([]);
    expect(replyToTranscript).not.toHaveBeenCalled();
    expect(transcribeAudio).not.toHaveBeenCalled();
  });

  it("makes another owner's recording indistinguishable from missing; never calls Gemini", async () => {
    const { t, alice, bob } = setup();
    const id = await fixture(t);
    // No stored audio exists: unauthorized paths must not try to use it.
    await t.run(async ctx => { const r = await ctx.db.get(id); await ctx.storage.delete(r!.audio); });
    for (const accessor of [bob]) {
      const hidden = await accessor.fetch(`/recordings?id=${id}`);
      const missing = await accessor.fetch("/recordings?id=missing");
      expect(hidden.status).toBe(404);
      expect(await hidden.json()).toEqual(await missing.json());
      const hiddenChat = await accessor.fetch("/chat", chat(id));
      const missingChat = await accessor.fetch("/chat", chat("missing"));
      expect(hiddenChat.status).toBe(404);
      expect(await hiddenChat.json()).toEqual(await missingChat.json());
    }
    expect((await alice.fetch(`/recordings?id=${id}`)).status).toBe(200);
    expect(replyToTranscript).not.toHaveBeenCalled();
    expect(transcribeAudio).not.toHaveBeenCalled();
    expect((await t.run(ctx => ctx.db.get(id)))!.chatLease).toBeUndefined();
  });

  it("stores raw audio under server-derived owner, schedules and completes the job", async () => {
    const { t, alice, bob } = setup();
    const response = await alice.fetch("/recordings", { method: "POST", headers: { "Content-Type": "audio/mp4" }, body: "fake audio" });
    expect(response.status).toBe(202);
    const { recordingId } = await response.json() as { recordingId: Id<"recordings"> };
    const record = await t.run(ctx => ctx.db.get(recordingId));
    expect(record).toMatchObject({ owner: "issuer|alice", mimeType: "audio/m4a", status: "queued" });
    expect(await t.run(async ctx => (await ctx.storage.get(record!.audio))!.text())).toBe("fake audio");
    expect(await t.run(ctx => ctx.db.system.query("_scheduled_functions").collect())).toHaveLength(2);
    vi.advanceTimersByTime(0);
    await t.finishInProgressScheduledFunctions();
    const publicRecord = await (await alice.fetch(`/recordings?id=${recordingId}`)).json();
    expect(publicRecord).toEqual({ recordingId, status: "ready", transcript: "# Transcript", messages: [] });
    expect((await bob.fetch(`/recordings?id=${recordingId}`)).status).toBe(404);
    expect(transcribeAudio).toHaveBeenCalledOnce();
  });

  it("rejects unsupported, empty and oversize uploads before storing", async () => {
    const { t, alice } = setup();
    for (const [type, bytes, status] of [["application/json", "{}", 415], ["audio/m4a", "", 400],
      ["audio/m4a", new Uint8Array(MAX_AUDIO + 1), 413]] as const) {
      expect((await alice.fetch("/recordings", { method: "POST", headers: { "Content-Type": type }, body: bytes })).status).toBe(status);
    }
    expect(await t.run(ctx => ctx.db.system.query("_storage").collect())).toEqual([]);
  });

  it("uses server transcript/history and persists complete exchanges", async () => {
    const { t, alice } = setup();
    const id = await fixture(t);
    expect(await (await alice.fetch("/chat", chat(id, "First?"))).json()).toEqual({ text: "Agreed." });
    expect((await alice.fetch("/chat", chat(id, "Second?"))).status).toBe(200);
    expect(replyToTranscript).toHaveBeenLastCalledWith("# Meeting\nWe agreed.", [
      { role: "user", text: "First?" }, { role: "assistant", text: "Agreed." },
    ], "Second?");
    const record = await t.run(ctx => ctx.db.get(id));
    expect(record!.messages).toHaveLength(4);
    expect(record!.chatLease).toBeUndefined();
  });

  it("reserves before paid work, releases after failure and expires abandoned leases safely", async () => {
    const { t, alice } = setup();
    const id = await fixture(t);
    await alice.mutation(internal.recordings.reserveChat, { id, message: "Question", lease: "first" });
    expect((await alice.fetch("/chat", chat(id))).status).toBe(409);
    expect(replyToTranscript).not.toHaveBeenCalled();
    vi.advanceTimersByTime(CHAT_TIMEOUT);
    await t.finishInProgressScheduledFunctions();
    vi.mocked(replyToTranscript).mockRejectedValueOnce(new Error("private provider diagnostic"));
    const failed = await alice.fetch("/chat", chat(id));
    expect(failed.status).toBe(502);
    expect(await failed.text()).not.toContain("private provider diagnostic");
    expect((await t.run(ctx => ctx.db.get(id)))!.chatLease).toBeUndefined();
    await alice.mutation(internal.recordings.reserveChat, { id, message: "Question", lease: "new" });
    await t.mutation(internal.recordings.releaseChat, { id, lease: "first" });
    expect((await t.run(ctx => ctx.db.get(id)))!.chatLease).toBe("new");
  });

  it("bounds chat input/history and records failed or expired jobs without retry", async () => {
    const { t, alice } = setup();
    const id = await fixture(t);
    expect((await alice.fetch("/chat", chat(id, "x".repeat(MAX_MESSAGE + 1)))).status).toBe(400);
    await t.run(ctx => ctx.db.patch(id, { messages: Array.from({ length: 40 }, () => ({ role: "user" as const, text: "q" })) }));
    expect((await alice.fetch("/chat", chat(id))).status).toBe(409);
    expect(replyToTranscript).not.toHaveBeenCalled();
    const queued = await fixture(t, "queued");
    vi.mocked(transcribeAudio).mockRejectedValueOnce(new Error("provider secret"));
    await t.action(internal.jobs.transcribe, { id: queued });
    expect(await t.run(ctx => ctx.db.get(queued))).toMatchObject({ status: "failed", error: "Gemini unavailable; no automatic retry was made." });
    await t.action(internal.jobs.transcribe, { id: queued });
    expect(transcribeAudio).toHaveBeenCalledOnce();
    const expired = await fixture(t, "queued");
    await t.mutation(internal.recordings.expireJob, { id: expired });
    expect((await t.run(ctx => ctx.db.get(expired)))!.status).toBe("failed");
    expect(JOB_TIMEOUT).toBeLessThanOrEqual(300_000);
  });
});
