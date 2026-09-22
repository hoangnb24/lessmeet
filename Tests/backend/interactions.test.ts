import { afterEach, expect, it, vi } from "vitest";
import { transcribeAudio } from "../../convex/gemini";

afterEach(() => { vi.unstubAllGlobals(); vi.unstubAllEnvs(); });

// Exercise the pinned, real AI SDK and Google provider against HTTP fixtures.
it.each(["completed", "incomplete"])("parses actual Interactions steps (%s), without fetching a public audio URL", async status => {
  vi.stubEnv("GEMINI_BILLABLE_ENABLED", "true");
  vi.stubEnv("GEMINI_API_KEY", "test-placeholder-not-a-key");
  vi.stubEnv("GEMINI_MODEL", "gemini-flash-latest");
  const origin = "https://generativelanguage.googleapis.com";
  const uri = `${origin}/v1beta/files/test`;
  const fetchMock = vi.fn().mockRejectedValue(new Error("Unexpected network request"))
    .mockResolvedValueOnce(new Response(null, { headers: { "x-goog-upload-url": `${origin}/upload/session` } }))
    .mockResolvedValueOnce(Response.json({ file: { name: "files/test", uri, state: "ACTIVE" } }))
    .mockResolvedValueOnce(Response.json({ status, steps: [{ type: "model_output", content: [{ type: "text", text: "# Transcript" }] }] }))
    .mockResolvedValueOnce(new Response(null, { status: 204 }));
  vi.stubGlobal("fetch", fetchMock);
  const result = transcribeAudio(new Blob(["fake audio"]), "audio/m4a");
  if (status === "completed") expect((await result).text).toBe("# Transcript");
  else await expect(result).rejects.toThrow("incomplete");
  expect(fetchMock).toHaveBeenCalledTimes(4);
  expect(String(fetchMock.mock.calls[2][0])).toBe(`${origin}/v1beta/interactions`);
  const wire = JSON.parse(fetchMock.mock.calls[2][1].body);
  expect(wire).toMatchObject({ model: "gemini-flash-latest", store: false });
  expect(JSON.stringify(wire.input)).toContain(uri);
  expect(JSON.stringify(wire.input)).toContain("audio/m4a");
  expect(wire).not.toHaveProperty("previous_interaction_id");
  expect(fetchMock.mock.calls[3][1].method).toBe("DELETE");
});
