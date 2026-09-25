import { describe, expect, it } from "vitest";
import { buildChatContext, history, room, validReply } from "../../convex/batchChatContext";
import { digest, sha256, type Manifest } from "../../convex/batchContract";

const manifest: Manifest = { version: 1, source: { sha256: "a".repeat(64), bytes: 1, duration: { value: 301, timescale: 1 } },
  chunks: [{ sha256: "b".repeat(64), bytes: 1 }, { sha256: "c".repeat(64), bytes: 1 }] };
const raw = (startMs: number | null, endMs: number | null, text: string) => JSON.stringify({ version: 1, segments: [{ startMs, endMs, speaker: "A", text }] });
describe("complete batch chat context", () => {
  it("keeps duplicate overlap and untimed alternatives, and digests exact original bytes/attempts", async () => {
    const first = JSON.stringify({ version: 1, segments: [{ startMs: 295000, endMs: 300000, speaker: "A", text: "same" }, { startMs: null, endMs: null, speaker: null, text: "alternative" }] });
    const second = raw(0, 5000, "same"), manifestDigest = await digest(manifest);
    const result = await buildChatContext(manifest, manifestDigest, [{ index: 1, attempt: 2, state: "succeeded", rawText: second }, { index: 0, attempt: 1, state: "succeeded", rawText: first }]);
    expect(result.availability).toBe("ready");
    const context = JSON.parse(result.contextText!); expect(context.chunks[0].segments).toHaveLength(2); expect(context.chunks[1].segments).toHaveLength(1);
    expect(context.chunks[0].segments[0].text).toBe(context.chunks[1].segments[0].text); expect(context.chunks[1].startMs).toBe(295000);
    const hashes = await Promise.all([first, second].map(text => sha256(new TextEncoder().encode(text).buffer)));
    expect(result.contextDigest).toBe(await sha256(new TextEncoder().encode(JSON.stringify(["lessmeet.batch.chat.context.v1", manifestDigest, [[0, 1, hashes[0]], [1, 2, hashes[1]]]])).buffer));
    expect((await buildChatContext(manifest, manifestDigest, [{ index: 0, attempt: 1, state: "succeeded", rawText: first + " " }, { index: 1, attempt: 2, state: "succeeded", rawText: second }])).contextDigest).not.toBe(result.contextDigest);
  });
  it("refuses all-raw context overflow even when deduplicated aggregate fits", async () => {
    const result = await buildChatContext(manifest, "a".repeat(64), [0, 1].map(index => ({ index, attempt: 1, state: "succeeded", rawText: JSON.stringify({ version: 1,
      segments: Array.from({ length: 30 }, () => ({ startMs: index ? 0 : 295000, endMs: index ? 5000 : 300000, speaker: null, text: "x".repeat(8000) })) }) })));
    expect(result.availability).toBe("context_too_large"); expect(result.contextText).toBeNull();
  });
  it("refuses missing results and preserves a bounded complete history", async () => {
    expect((await buildChatContext(manifest, "a".repeat(64), [{ index: 0, attempt: 1, state: "succeeded", rawText: raw(null, null, "x") }])).availability).toBe("incomplete");
    const exchanges = [{ clientMessageId: "id", contextDigest: "digest", message: "question", reply: "answer" }];
    expect(history(exchanges)).toEqual([{ role: "user", text: "question" }, { role: "assistant", text: "answer" }]);
    expect(room(Array(20).fill(exchanges[0]), "another")).toBe(false); expect(validReply("x".repeat(32766))).toBe(true); expect(validReply("x".repeat(32767))).toBe(false);
  });
  it("accepts an exact 384 KiB projection and refuses one byte over", async () => {
    const selections = (extra: string) => [0, 1].map(index => ({ index, attempt: 1, state: "succeeded", rawText: JSON.stringify({ version: 1,
      segments: [...Array.from({ length: 24 }, (_, i) => ({ startMs: index ? 0 : 295000, endMs: index ? 5000 : 300000, speaker: null, text: `segment${i}:` + "x".repeat(7980) })),
        ...(index === 0 ? [{ startMs: null, endMs: null, speaker: null, text: extra }] : [])] }) }));
    const initial = await buildChatContext(manifest, "a".repeat(64), selections("x")); expect(initial.availability).toBe("ready");
    const remaining = 384 * 1024 - new TextEncoder().encode(initial.contextText!).length;
    expect(remaining).toBeGreaterThan(0); expect(remaining).toBeLessThan(8192);
    const boundary = await buildChatContext(manifest, "a".repeat(64), selections("x".repeat(remaining + 1)));
    expect(boundary.availability).toBe("ready"); expect(new TextEncoder().encode(boundary.contextText!).length).toBe(384 * 1024);
    expect((await buildChatContext(manifest, "a".repeat(64), selections("x".repeat(remaining + 2)))).availability).toBe("context_too_large");
  });
});
