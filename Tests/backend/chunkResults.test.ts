import { expect, it } from "vitest";
import {
  CHUNK_RESULT_LIMITS as L, ChunkResultError, mergeChunkResults, validateChunkResult,
  type ChunkSegment, type ChunkMergeInput,
} from "../../convex/chunkResults";

const seg = (changes: Partial<ChunkSegment> = {}): ChunkSegment => ({
  startMs: 0, endMs: 1000, speaker: null, text: "Hello", ...changes,
});
const raw = (...segments: ChunkSegment[]) => JSON.stringify({ version: 1, segments });
function manifest(durationMs = 301_000): ChunkMergeInput {
  const count = 1 + Math.ceil(Math.max(0, durationMs - 300_000) / 295_000);
  return { durationMs, chunks: Array.from({ length: count }, (_, index) => ({
    index, startMs: index * 295_000, endMs: Math.min(index * 295_000 + 300_000, durationMs), rawText: raw(),
  })) };
}
function mergePair(a: ChunkSegment[], b: ChunkSegment[]) {
  const input = manifest();
  input.chunks[0].rawText = raw(...a);
  input.chunks[1].rawText = raw(...b);
  return mergeChunkResults(input);
}

it("retains exact raw JSON, text whitespace, local labels and segment order", () => {
  const s = seg({ text: " \tTiếng Việt\nالعربية\r\n👩‍💻 ", speaker: " A \t" });
  const source = JSON.stringify({ version: 1, segments: [s] }, null, 2);
  expect(validateChunkResult(source, 1000)).toEqual({ rawText: source, result: { version: 1, segments: [s] } });
});

it("accepts paired null timestamps, zero-segment silence and full duration endpoint", () => {
  expect(validateChunkResult(raw(seg({ startMs: null, endMs: null })), 1).result.segments[0].endMs).toBeNull();
  expect(validateChunkResult(raw(), 1).result.segments).toEqual([]);
  expect(validateChunkResult(raw(seg({ endMs: 300_000 })), 300_000).result.segments).toHaveLength(1);
});

it.each([null, [], {}, { version: 2, segments: [] }, { version: 1, segments: null },
  { version: 1, segments: [], provenance: [] }, { version: 1 },
  { version: 1, segments: [{ ...seg(), sources: [{ chunkIndex: 99 }] }] },
  { version: 1, segments: [{ startMs: 0, endMs: 1, text: "missing speaker" }] },
  { version: 1, segments: [null] }, { version: 1, segments: [[]] },
])("rejects nonexact result shape %j", value => {
  expect(() => validateChunkResult(JSON.stringify(value), 1000)).toThrow(ChunkResultError);
});

it.each(["", "not json", "```json\n{}\n```", '{"version":1,"segments":[',
  '{"version":1,"segments":[],"__proto__":{}}'])("rejects malformed or extra-key JSON %s", text => {
  expect(() => validateChunkResult(text, 1000)).toThrow(ChunkResultError);
});

it.each([null, undefined, {}, 1])("rejects non-string raw input %j", value => {
  expect(() => validateChunkResult(value as unknown as string, 1000)).toThrow("invalid_result");
});

it.each([
  { startMs: null, endMs: 1 }, { startMs: 0, endMs: null }, { startMs: -1 },
  { startMs: 1, endMs: 1 }, { startMs: 2, endMs: 1 }, { startMs: 0.5 },
  { endMs: 1001 }, { endMs: 1e20 }, { startMs: "0" }, { endMs: "1" },
])("rejects invalid timestamp pair %j", change => {
  expect(() => validateChunkResult(raw({ ...seg(), ...change } as ChunkSegment), 1000)).toThrow(ChunkResultError);
});

it.each([0, -1, 0.5, NaN, Infinity, 300_001, 600_000])("rejects duration %s", duration => {
  expect(() => validateChunkResult(raw(), duration)).toThrow(ChunkResultError);
});

it.each(["", " \t\r\n", "\u200b", "\u200d \t", "hi\0", "hi\u0007", "hi\u0085", "hi\u202e", "hi\u2067", "\ud800", "\udc00"])("rejects empty/control/surrogate text %j", text => {
  expect(() => validateChunkResult(raw(seg({ text })), 1000)).toThrow(ChunkResultError);
  expect(() => validateChunkResult(raw(seg({ speaker: text })), 1000)).toThrow(ChunkResultError);
});

it.each([
  '{"version":2,"version":1,"segments":[]}',
  '{"version":1,"segments":[{"startMs":0,"endMs":1,"speaker":null,"text":"hidden","text":"visible"}]}',
  '{"version":1,"segments":[],"\\u0076ersion":1}',
  '{"version":1,"segments":[],"segments":[]}',
  '{"version":1,"segments":{"hidden":{"deep":1}},"segments":[]}',
])("rejects duplicate JSON keys rather than accepting last-key-wins: %s", text => {
  expect(() => validateChunkResult(text, 1)).toThrow("invalid_result");
});

it("key scan does not mistake JSON-like transcript text or escaped quotes for keys", () => {
  const text = '{"text":"one","text":"two"} \\ \" : [ ] } { 👋';
  expect(validateChunkResult(raw(seg({ text })), 1000).result.segments[0].text).toBe(text);
});

it.each([null, [], {}, { durationMs: 1, chunks: null }, { durationMs: 1, chunks: [null] }])("rejects malformed merge input %j", input => {
  expect(() => mergeChunkResults(input as unknown as ChunkMergeInput)).toThrow("invalid_manifest");
});

it("enforces UTF-8 caps rather than code-unit lengths", () => {
  expect(validateChunkResult(raw(seg({ text: "é".repeat(4096), speaker: "é".repeat(64) })), 1000)).toBeTruthy();
  expect(() => validateChunkResult(raw(seg({ text: "é".repeat(4097) })), 1000)).toThrow(ChunkResultError);
  expect(() => validateChunkResult(raw(seg({ speaker: "é".repeat(65) })), 1000)).toThrow(ChunkResultError);
  expect(() => validateChunkResult(raw(seg({ speaker: 1 as unknown as string })), 1000)).toThrow(ChunkResultError);
});

it("enforces segment count before walking entries", () => {
  expect(validateChunkResult(raw(...Array.from({ length: 2048 }, () => seg())), 1000).result.segments).toHaveLength(2048);
  expect(() => validateChunkResult(raw(...Array.from({ length: 2049 }, () => seg())), 1000)).toThrow(ChunkResultError);
});

it("bounds raw bytes including JSON formatting and escaping, with inclusive limit", () => {
  const short = raw();
  const exact = short + " ".repeat(L.rawBytes - short.length);
  expect(validateChunkResult(exact, 1).rawText).toBe(exact);
  expect(() => validateChunkResult(exact + " ", 1)).toThrow("raw_too_large");
  expect(() => validateChunkResult("é".repeat(L.rawBytes / 2 + 1), 1)).toThrow("raw_too_large");
  const escaped = raw(...Array.from({ length: 70 }, () => seg({ text: "\t".repeat(4095) + "x" })));
  expect(() => validateChunkResult(escaped, 1000)).toThrow("raw_too_large");
});

it.each([1, 300_000, 300_001, 301_000, 595_000, 595_001, 7_200_000])("accepts full canonical geometry at %i", duration => {
  const result = mergeChunkResults(manifest(duration));
  expect(result.status).toBe("complete");
  expect(result.originals).toHaveLength(1 + Math.ceil(Math.max(0, duration - 300_000) / 295_000));
});

it("retains all 25 canonical slots and the 120-second tail at 120 minutes", () => {
  const result = mergeChunkResults(manifest(7_200_000));
  expect(result.originals).toHaveLength(25);
  expect(result.originals[24]).toMatchObject({ startMs: 7_080_000, endMs: 7_200_000 });
  expect(result.originals.slice(0, 24).every(c => c.endMs - c.startMs === 300_000)).toBe(true);
  expect(result.originals.reduce((total, c) => total + c.endMs - c.startMs, 0)).toBe(7_320_000);
});

it("freezes migrated geometry and unchanged per-result caps without changing version 1", () => {
  expect(L).toEqual({ segments: 2048, textBytes: 8192, speakerBytes: 128,
    rawBytes: 393216, aggregateBytes: 393216,
    chunks: 25, chunkMs: 300_000, strideMs: 295_000, durationMs: 7_200_000 });
  expect(Object.isFrozen(L)).toBe(true);
  expect(mergeChunkResults(manifest()).version).toBe(1);
});

it.each([301_000, 600_000, 7_200_000])("rejects old undeployed 600/590/10 manifest at %i", durationMs => {
  const count = 1 + Math.ceil(Math.max(0, durationMs - 600_000) / 590_000);
  const chunks = Array.from({ length: count }, (_, index) => ({
    index, startMs: index * 590_000, endMs: Math.min(index * 590_000 + 600_000, durationMs), rawText: raw(),
  }));
  expect(() => mergeChunkResults({ durationMs, chunks })).toThrow("invalid_manifest");
});

it("rejects a 26th slot and missing last slot rather than silently truncating or renumbering", () => {
  const input = manifest(7_200_000);
  input.chunks.push({ index: 25, startMs: 7_375_000, endMs: 7_675_000, rawText: raw() });
  expect(() => mergeChunkResults(input)).toThrow("invalid_manifest");
  input.chunks.splice(24, 2);
  expect(() => mergeChunkResults(input)).toThrow("invalid_manifest");
});

it.each([0, -1, NaN, Infinity, 300_000.1, 7_200_001, 7_200_499.3])("rejects bad parent duration %s", durationMs => {
  expect(() => mergeChunkResults({ ...manifest(), durationMs })).toThrow("invalid_manifest");
});

it.each([
  (i: ChunkMergeInput) => { i.chunks[1].index = 0; },
  (i: ChunkMergeInput) => { i.chunks[1].index = 1.1; },
  (i: ChunkMergeInput) => { i.chunks[1].index = -1; },
  (i: ChunkMergeInput) => { i.chunks[1].index = 2; },
  (i: ChunkMergeInput) => { i.chunks[1].startMs = 294_000; },
  (i: ChunkMergeInput) => { i.chunks[1].endMs++; },
  (i: ChunkMergeInput) => { i.chunks[0].endMs--; },
  (i: ChunkMergeInput) => { i.chunks.pop(); },
  (i: ChunkMergeInput) => { i.chunks.push(i.chunks[0]); },
  (i: ChunkMergeInput) => { Object.assign(i.chunks[0], { provenance: [99] }); },
  (i: ChunkMergeInput) => { Object.assign(i, { sources: [] }); },
  (i: ChunkMergeInput) => { i.chunks[0].rawText = undefined as unknown as null; },
])("rejects noncanonical, incomplete and spoofed manifest %#", mutate => {
  const input = manifest(); mutate(input);
  expect(() => mergeChunkResults(input)).toThrow("invalid_manifest");
});

it("rejects malformed and too-long chunk results during merge, not only at separate validation", () => {
  const input = manifest();
  input.chunks[1].rawText = raw(seg({ endMs: 6_001 }));
  expect(() => mergeChunkResults(input)).toThrow("invalid_result");
  input.chunks[1].rawText = " ".repeat(L.rawBytes + 1);
  expect(() => mergeChunkResults(input)).toThrow("raw_too_large");
});

it("exact adjacent overlap dedup retains original spellings and both namespaced speakers", () => {
  const a = seg({ startMs: 296_000, endMs: 297_000, text: " e\u0301\n Hello ", speaker: "Speaker 1" });
  const b = seg({ startMs: 1000, endMs: 2000, text: "é Hello", speaker: "Speaker 2" });
  const result = mergePair([a], [b]);
  expect(result.aggregate?.timed).toEqual([{ startMs: 296_000, endMs: 297_000, text: a.text,
    overlaps: false, sources: [
      { chunkIndex: 0, segmentIndex: 0, speaker: { chunkIndex: 0, localLabel: "Speaker 1" } },
      { chunkIndex: 1, segmentIndex: 0, speaker: { chunkIndex: 1, localLabel: "Speaker 2" } },
    ] }]);
  expect(result.originals.map(c => c.rawText)).toEqual([raw(a), raw(b)]);
});

it("includes the exact five-second overlap endpoints but retains a crossing alternative", () => {
  const a = seg({ startMs: 295_000, endMs: 300_000 });
  const b = seg({ startMs: 0, endMs: 5_000 });
  const result = mergePair([a], [b, seg({ startMs: 4_999, endMs: 5_001 })]);
  expect(result.aggregate?.timed).toHaveLength(2);
  expect(result.aggregate?.timed.map(s => s.sources.length)).toEqual([2, 1]);
  expect(result.aggregate?.timed.every(s => s.overlaps)).toBe(true);
  expect(result.aggregate?.timed[1].endMs).toBe(300_001);
});

it("retains the known identical-text/time speaker ambiguity as a multi-source derived equivalence", () => {
  // This may be simultaneous different speakers, not one proven unique utterance.
  const a = seg({ startMs: 296_000, endMs: 297_000, text: "yes", speaker: "Alice" });
  const b = seg({ startMs: 1_000, endMs: 2_000, text: "yes", speaker: "Bob" });
  const result = mergePair([a], [b]);
  expect(result.aggregate?.timed).toHaveLength(1);
  expect(result.aggregate?.timed[0].overlaps).toBe(false); // Not acoustic certainty.
  expect(result.aggregate?.timed[0].sources.map(s => s.speaker)).toEqual([
    { chunkIndex: 0, localLabel: "Alice" }, { chunkIndex: 1, localLabel: "Bob" },
  ]);
  expect(result.originals.map(c => c.rawText)).toEqual([raw(a), raw(b)]);
});

it.each([
  { text: "hello" }, { text: "Hello!" }, { startMs: 1001 }, { endMs: 2001 },
])("keeps ambiguous near matches with overlap flags: %j", change => {
  const result = mergePair([seg({ startMs: 296_000, endMs: 297_000 })], [seg({ startMs: 1000, endMs: 2000, ...change })]);
  expect(result.aggregate?.timed).toHaveLength(2);
  expect(result.aggregate?.timed.every(s => s.overlaps)).toBe(true);
});

it("keeps repeated real speech at different times and same-chunk duplicates; dedup is one-to-one", () => {
  const a = seg({ startMs: 296_000, endMs: 297_000 });
  const b = seg({ startMs: 1000, endMs: 2000 });
  const result = mergePair([a, a, seg({ startMs: 298_000, endMs: 299_000 })], [b, b, b]);
  expect(result.aggregate?.timed).toHaveLength(4);
  expect(result.aggregate?.timed.map(s => s.sources.length)).toEqual([2, 2, 1, 1]);
  expect(result.aggregate?.timed[3].overlaps).toBe(false);
});

it("never deduplicates repeated content outside overlap, across missing slots or untimed sections", () => {
  const input = manifest(596_000);
  input.chunks[0].rawText = raw(seg({ text: "repeat" }), seg({ text: "repeat", startMs: null, endMs: null }));
  input.chunks[1].rawText = null;
  input.chunks[2].rawText = raw(seg({ text: "repeat" }), seg({ text: "repeat", startMs: null, endMs: null }));
  const result = mergeChunkResults(input);
  expect(result.status).toBe("partial");
  expect(result.missingChunks).toEqual([1]);
  expect(result.aggregate?.timed).toHaveLength(2);
  expect(result.aggregate?.untimed.map(s => s.chunkIndex)).toEqual([0, 2]);
});

it("sorts by time, then canonical chunk and raw ordinal without mutating caller input", () => {
  const input = manifest();
  input.chunks[0].rawText = raw(seg({ startMs: 296_000, endMs: 297_000, text: "second" }), seg({ text: "first" }));
  input.chunks[1].rawText = raw(seg({ startMs: 1000, endMs: 2000, text: "third" }));
  input.chunks.reverse();
  const before = JSON.stringify(input);
  const first = mergeChunkResults(input), second = mergeChunkResults({ ...input, chunks: [...input.chunks].reverse() });
  expect(first).toEqual(second);
  expect(first.aggregate?.timed.map(s => s.text)).toEqual(["first", "second", "third"]);
  expect(JSON.stringify(input)).toBe(before);
});

it("marks nested overlaps on both sides, but not touching intervals", () => {
  const input = manifest(1000);
  input.chunks[0].rawText = raw(seg({ endMs: 100 }), seg({ startMs: 10, endMs: 20 }),
    seg({ startMs: 30, endMs: 40 }), seg({ startMs: 100, endMs: 110 }));
  expect(mergeChunkResults(input).aggregate?.timed.map(s => s.overlaps)).toEqual([true, true, true, false]);
});

it("does not invent timestamps or global speaker identity for untimed text", () => {
  const result = mergePair([seg({ startMs: null, endMs: null, speaker: "A" })], [seg({ startMs: null, endMs: null, speaker: "A" })]);
  expect(result.aggregate?.timed).toEqual([]);
  expect(result.aggregate?.untimed).toEqual([0, 1].map(chunkIndex => ({ chunkIndex, segments: [{ text: "Hello",
    source: { chunkIndex, segmentIndex: 0, speaker: { chunkIndex, localLabel: "A" } } }] })));
});

it("all missing is partial, never a successful empty transcript", () => {
  const input = manifest(); input.chunks.forEach(c => { c.rawText = null; });
  expect(mergeChunkResults(input)).toMatchObject({ status: "partial", missingChunks: [0, 1], aggregate: { timed: [], untimed: [] } });
});

it("reports exact serialized aggregate bytes including escaped Unicode and provenance", () => {
  const result = mergePair([seg({ text: 'é " hi\\\n' }), seg({ startMs: null, endMs: null })], [seg()]);
  expect(result.aggregateBytes).toBe(new TextEncoder().encode(JSON.stringify(result.aggregate)).byteLength);
});

it("uses an inclusive exact 384 KiB aggregate boundary", () => {
  const input = manifest(300_000);
  const segments = Array.from({ length: 48 }, (_, i) => seg({ startMs: i, endMs: i + 1, text: "x" }));
  input.chunks[0].rawText = raw(...segments);
  const baseline = mergeChunkResults(input);
  expect(baseline.aggregateBytes).not.toBeNull();
  let remaining = L.aggregateBytes - baseline.aggregateBytes!;
  for (const s of segments) {
    const added = Math.min(remaining, L.textBytes - 1);
    s.text += "x".repeat(added); remaining -= added;
  }
  expect(remaining).toBe(0);
  input.chunks[0].rawText = raw(...segments);
  const exact = mergeChunkResults(input);
  expect(exact.status).toBe("complete");
  expect(exact.aggregateBytes).toBe(L.aggregateBytes);
  expect(new TextEncoder().encode(JSON.stringify(exact.aggregate)).byteLength).toBe(L.aggregateBytes);
  segments[47].text += "x";
  input.chunks[0].rawText = raw(...segments);
  expect(mergeChunkResults(input).status).toBe("too_large");
});

it.each([false, true])("merge overflow returns no truncated aggregate and preserves every original (untimed=%s)", untimed => {
  const input = manifest(7_200_000);
  input.chunks.forEach(c => { c.rawText = raw(...Array.from({ length: 12 }, (_, index) =>
    seg({ text: `${index}:` + "é".repeat(3999), startMs: untimed ? null : index * 1000, endMs: untimed ? null : index * 1000 + 1 }))); });
  const before = input.chunks.map(c => c.rawText);
  const result = mergeChunkResults(input);
  expect(result.status).toBe("too_large");
  expect(result.aggregate).toBeNull();
  expect(result.aggregateBytes).toBeNull();
  expect(result.originals.map(c => c.rawText)).toEqual(before);
  expect(result.missingChunks).toEqual([]);
});

it("bounds maximum segment workload and preserves missing information on overflow", () => {
  const input = manifest(7_200_000);
  input.chunks.forEach(c => { c.rawText = raw(...Array.from({ length: 2048 }, (_, i) => seg({ startMs: i, endMs: i + 1 }))); });
  const full = mergeChunkResults(input);
  expect(full.status).toBe("too_large");
  expect(full.missingChunks).toEqual([]);
  input.chunks[24].rawText = null;
  const result = mergeChunkResults(input);
  expect(result.status).toBe("too_large");
  expect(result.originals).toHaveLength(25);
  expect(result.missingChunks).toEqual([24]);
});

it("accepts the full 25 * 384 KiB raw envelope without treating originals as one aggregate", () => {
  const input = manifest(7_200_000);
  input.chunks.forEach(c => {
    const text = raw(seg());
    c.rawText = text + " ".repeat(393216 - text.length);
  });
  const result = mergeChunkResults(input);
  expect(result.status).toBe("complete");
  expect(result.originals.reduce((total, c) => total + new TextEncoder().encode(c.rawText!).byteLength, 0)).toBe(9_830_400);
  expect(result.originals.map(c => c.rawText)).toEqual(input.chunks.map(c => c.rawText));
  expect(result.aggregateBytes).toBeLessThanOrEqual(393216);
});
