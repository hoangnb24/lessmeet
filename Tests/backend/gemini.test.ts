import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { transcribeAudio, replyToTranscript } from "../../convex/gemini";

const { generate, interactions, provider, fetchMock } = vi.hoisted(() => ({
  generate: vi.fn(), interactions: vi.fn(() => "mock-model"), provider: vi.fn(), fetchMock: vi.fn(),
}));
vi.mock("ai", () => ({ generateText: generate }));
vi.mock("@ai-sdk/google", () => ({ createGoogleGenerativeAI: provider }));
const base = "https://generativelanguage.googleapis.com";
const metadata = (state = "ACTIVE") => ({ name: "files/test", uri: `${base}/v1beta/files/test`, state });
function upload(state = "ACTIVE") {
  fetchMock.mockResolvedValueOnce(new Response(null, { headers: { "x-goog-upload-url": `${base}/upload/session` } }))
    .mockResolvedValueOnce(Response.json({ file: metadata(state) }));
}
beforeEach(() => {
  vi.resetAllMocks();
  vi.stubEnv("GEMINI_API_KEY", "test-placeholder-not-a-key");
  vi.stubEnv("GEMINI_MODEL", "");
  vi.stubGlobal("fetch", fetchMock);
  fetchMock.mockRejectedValue(new Error("Unexpected network request"));
  provider.mockReturnValue({ interactions });
  interactions.mockReturnValue("mock-model");
  generate.mockResolvedValue({ text: "# Complete transcript", finishReason: "stop" });
});
afterEach(() => { vi.unstubAllGlobals(); vi.unstubAllEnvs(); vi.useRealTimers(); });

it("uploads raw bytes with matching MIME, requests stateless Interactions, and deletes Google copy", async () => {
  upload();
  fetchMock.mockResolvedValueOnce(new Response(null, { status: 204 }));
  const blob = new Blob(["audio"], { type: "audio/m4a" });
  expect(await transcribeAudio(blob, "audio/m4a")).toEqual({ text: "# Complete transcript", warning: undefined });
  expect(provider).toHaveBeenCalledWith({ apiKey: "test-placeholder-not-a-key" });
  expect(interactions).toHaveBeenCalledWith("gemini-flash-latest");
  expect(fetchMock.mock.calls[0][1]).toMatchObject({ method: "POST", headers: {
    "X-Goog-Upload-Header-Content-Length": "5", "X-Goog-Upload-Header-Content-Type": "audio/m4a",
    "X-Goog-Upload-Protocol": "resumable",
  } });
  expect(fetchMock.mock.calls[1][1]).toMatchObject({ body: blob, headers: { "X-Goog-Upload-Command": "upload, finalize" } });
  expect(generate).toHaveBeenCalledWith(expect.objectContaining({ maxRetries: 0, providerOptions: { google: { store: false } } }));
  expect(generate.mock.calls[0][0].messages[0].content[1]).toEqual({ type: "file", data: new URL(metadata().uri), mediaType: "audio/m4a" });
  expect(fetchMock.mock.calls[2]).toEqual([metadata().uri, expect.objectContaining({ method: "DELETE" })]);
});

it("rejects incomplete output and still attempts cleanup, reporting cleanup failure safely", async () => {
  upload();
  generate.mockResolvedValue({ text: "partial", finishReason: "length" });
  fetchMock.mockResolvedValueOnce(new Response(null, { status: 503 }));
  await expect(transcribeAudio(new Blob(["audio"]), "audio/m4a")).rejects.toThrow(/incomplete.*could not be deleted/);
  expect(fetchMock).toHaveBeenCalledTimes(3);
});

it("bounds processing polls and cleans up without calling the model", async () => {
  vi.useFakeTimers();
  upload("PROCESSING");
  for (let i = 0; i < 15; i++) fetchMock.mockResolvedValueOnce(Response.json(metadata("PROCESSING")));
  fetchMock.mockResolvedValueOnce(new Response(null, { status: 204 }));
  const result = expect(transcribeAudio(new Blob(["audio"]), "audio/m4a")).rejects.toThrow("prepare the recording");
  await vi.runAllTimersAsync();
  await result;
  expect(fetchMock).toHaveBeenCalledTimes(18);
  expect(generate).not.toHaveBeenCalled();
});

it("returns cleanup warning on success, and fresh labeled context for chat with no API history", async () => {
  upload();
  fetchMock.mockResolvedValueOnce(new Response(null, { status: 503 }));
  expect((await transcribeAudio(new Blob(["audio"]), "audio/m4a")).warning).toContain("could not be deleted");
  vi.stubEnv("GEMINI_MODEL", "chosen-model");
  await replyToTranscript("Transcript", [{ role: "user", text: "Old question" }], "New question");
  expect(interactions).toHaveBeenLastCalledWith("chosen-model");
  const request = generate.mock.calls[1][0];
  expect(request.prompt).toContain("Transcript");
  expect(request.prompt).toContain("Old question");
  expect(request.prompt).toContain("New question");
  expect(request).toMatchObject({ maxRetries: 0, providerOptions: { google: { store: false } } });
  expect(request).not.toHaveProperty("previousInteractionId");
});
