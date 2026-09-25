// Disconnected result contract. No admission, billing, provider or persistence effects.
export const CHUNK_RESULT_LIMITS = Object.freeze({
  segments: 2048, textBytes: 8 * 1024, speakerBytes: 128,
  rawBytes: 384 * 1024, aggregateBytes: 384 * 1024,
  chunks: 25, chunkMs: 300_000, strideMs: 295_000, durationMs: 7_200_000,
});

export class ChunkResultError extends Error {
  constructor(public readonly code: "invalid_result" | "invalid_manifest" | "raw_too_large") {
    super(code);
    this.name = "ChunkResultError";
  }
}
export type ChunkSegment = {
  startMs: number | null; endMs: number | null; speaker: string | null; text: string;
};
export type ValidatedChunkResult = {
  rawText: string; result: { version: 1; segments: ChunkSegment[] };
};
export type ChunkResultInput = {
  index: number; startMs: number; endMs: number; rawText: string | null;
};
export type ChunkMergeInput = { durationMs: number; chunks: ChunkResultInput[] };
export type SegmentSource = {
  chunkIndex: number; segmentIndex: number;
  // A local label, NEVER a cross-chunk identity. Raw spellings remain unchanged.
  speaker: { chunkIndex: number; localLabel: string } | null;
};
export type TimedSegment = {
  startMs: number; endMs: number; text: string;
  sources: SegmentSource[]; overlaps: boolean;
};
export type UntimedSection = {
  chunkIndex: number; segments: { text: string; source: SegmentSource }[];
};
export type ChunkAggregate = {
  version: 1; durationMs: number; missingChunks: number[];
  timed: TimedSegment[]; untimed: UntimedSection[];
};
export type ChunkMergeResult = {
  version: 1;
  // These are exact original provider JSON strings, sorted by canonical index.
  // Null means unavailable, not a successful empty transcript.
  originals: ChunkResultInput[];
  missingChunks: number[];
} & (
  { status: "complete" | "partial"; aggregate: ChunkAggregate; aggregateBytes: number } |
  { status: "too_large"; aggregate: null; aggregateBytes: null }
);

const utf8 = new TextEncoder();
const integer = (x: unknown): x is number => typeof x === "number" && Number.isSafeInteger(x);
function invalid(): never { throw new ChunkResultError("invalid_result"); }
function invalidManifest(): never { throw new ChunkResultError("invalid_manifest"); }

function exact(value: unknown, keys: readonly string[]): value is Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const actual = Object.keys(value);
  return actual.length === keys.length && keys.every(key => Object.hasOwn(value, key));
}

// Permit ordinary Unicode, tabs and line breaks; reject C0/C1 controls, bidi
// formatting controls and unpaired surrogates. Do not strip or rewrite content.
function validText(value: unknown, maxBytes: number): value is string {
  if (typeof value !== "string" || value.length > maxBytes || !value.replace(/\p{Cf}/gu, "").trim() ||
      /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/u.test(value)) return false;
  for (let i = 0; i < value.length; i++) {
    const c = value.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      const next = value.charCodeAt(++i);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return false;
    } else if (c >= 0xdc00 && c <= 0xdfff) return false;
  }
  return utf8.encode(value).byteLength <= maxBytes;
}

// JSON.parse has already established syntax and the fixed, shallow shape below.
// Its last-key-wins behavior must not hide duplicate (including escaped) keys.
// This is only a string/key scan, not another JSON parser or a recursive walker.
function rejectDuplicateKeys(raw: string) {
  const objects: Set<string>[] = [];
  for (let i = 0; i < raw.length; i++) {
    if (raw[i] === "{") {
      // Even values hidden by a later duplicate key cannot grow an object stack.
      if (objects.length >= 2) invalid();
      objects.push(new Set());
    }
    else if (raw[i] === "}") objects.pop();
    else if (raw[i] === '"') {
      const start = i++;
      while (i < raw.length && raw[i] !== '"') { if (raw[i] === "\\") i++; i++; }
      let after = i + 1;
      while (after < raw.length && /[\t\r\n ]/.test(raw[after])) after++;
      if (raw[after] === ":") {
        const key = JSON.parse(raw.slice(start, i + 1)) as string;
        const keys = objects[objects.length - 1];
        if (!keys || keys.has(key)) invalid();
        keys.add(key);
      }
    }
  }
}

/** Validate exact provider JSON bytes, retaining the original string unchanged.
 * Caller separately establishes provider completion and trustworthy media bounds.
 * Zero segments is allowed (e.g. silence); empty segment text is not.
 */
export function validateChunkResult(rawText: string, admittedDurationMs: number): ValidatedChunkResult {
  if (!integer(admittedDurationMs) || admittedDurationMs <= 0 || admittedDurationMs > CHUNK_RESULT_LIMITS.chunkMs) invalid();
  if (typeof rawText !== "string") invalid();
  // Check code units first to avoid allocating an unbounded encoded buffer.
  if (rawText.length > CHUNK_RESULT_LIMITS.rawBytes || utf8.encode(rawText).byteLength > CHUNK_RESULT_LIMITS.rawBytes) {
    throw new ChunkResultError("raw_too_large");
  }
  let parsed: unknown;
  try { parsed = JSON.parse(rawText); } catch { invalid(); }
  if (!exact(parsed, ["version", "segments"]) || parsed.version !== 1 ||
      !Array.isArray(parsed.segments) || parsed.segments.length > CHUNK_RESULT_LIMITS.segments) invalid();
  const segments: ChunkSegment[] = [];
  for (const s of parsed.segments) {
    if (!exact(s, ["startMs", "endMs", "speaker", "text"]) ||
        !validText(s.text, CHUNK_RESULT_LIMITS.textBytes) ||
        !(s.speaker === null || validText(s.speaker, CHUNK_RESULT_LIMITS.speakerBytes))) invalid();
    const { startMs, endMs } = s;
    if (!(startMs === null && endMs === null) &&
        !(integer(startMs) && integer(endMs) && startMs >= 0 && startMs < endMs && endMs <= admittedDurationMs)) invalid();
    segments.push({ startMs: startMs as number | null, endMs: endMs as number | null,
      speaker: s.speaker, text: s.text });
  }
  rejectDuplicateKeys(rawText);
  return { rawText, result: { version: 1, segments } };
}

// NFC and whitespace only: never case folding, punctuation removal, or fuzzy match.
const comparison = (s: string) => s.normalize("NFC").replace(/\s+/gu, " ").trim();
const keyFor = (start: number, end: number, text: string) => JSON.stringify([start, end, comparison(text)]);

/** Full canonical manifest required; missing results are explicit null slots.
 * Source references are generated here, never accepted from provider JSON.
 * Dedup is one-to-one between adjacent chunks, wholly inside their overlap.
 * The aggregate is a derived view; originals preserve every character/label.
 */
export function mergeChunkResults(input: ChunkMergeInput): ChunkMergeResult {
  if (!exact(input, ["durationMs", "chunks"]) || !integer(input.durationMs) ||
      input.durationMs <= 0 || input.durationMs > CHUNK_RESULT_LIMITS.durationMs ||
      !Array.isArray(input.chunks)) invalidManifest();
  const count = 1 + Math.ceil(Math.max(0, input.durationMs - CHUNK_RESULT_LIMITS.chunkMs) / CHUNK_RESULT_LIMITS.strideMs);
  if (input.chunks.length !== count || input.chunks.length > CHUNK_RESULT_LIMITS.chunks) invalidManifest();
  const slots = new Map<number, ChunkResultInput>();
  for (const c of input.chunks) {
    if (!exact(c, ["index", "startMs", "endMs", "rawText"]) || !integer(c.index) ||
        c.index < 0 || c.index >= count || slots.has(c.index) ||
        c.startMs !== c.index * CHUNK_RESULT_LIMITS.strideMs ||
        c.endMs !== Math.min(c.startMs + CHUNK_RESULT_LIMITS.chunkMs, input.durationMs) ||
        !(c.rawText === null || typeof c.rawText === "string")) invalidManifest();
    slots.set(c.index, { index: c.index, startMs: c.startMs, endMs: c.endMs, rawText: c.rawText });
  }
  const originals = [...slots.values()].sort((a, b) => a.index - b.index);
  const missingChunks: number[] = [];
  const timed: TimedSegment[] = [];
  const untimed: UntimedSection[] = [];
  // At most one previous chunk's tail is indexed. Bucket cursors avoid shift/O(n²).
  let previous = new Map<string, { items: TimedSegment[]; cursor: number }>();
  for (const c of originals) {
    const next = new Map<string, { items: TimedSegment[]; cursor: number }>();
    if (c.rawText === null) { missingChunks.push(c.index); previous = next; continue; }
    const validated = validateChunkResult(c.rawText, c.endMs - c.startMs);
    const section: UntimedSection = { chunkIndex: c.index, segments: [] };
    for (const [segmentIndex, s] of validated.result.segments.entries()) {
      const source: SegmentSource = { chunkIndex: c.index, segmentIndex,
        speaker: s.speaker === null ? null : { chunkIndex: c.index, localLabel: s.speaker } };
      if (s.startMs === null || s.endMs === null) {
        section.segments.push({ text: s.text, source });
        continue;
      }
      const startMs = c.startMs + s.startMs, endMs = c.startMs + s.endMs;
      const key = keyFor(startMs, endMs, s.text);
      const candidates = endMs <= c.startMs + 5_000 ? previous.get(key) : undefined;
      let item = candidates && candidates.cursor < candidates.items.length ? candidates.items[candidates.cursor++] : undefined;
      if (item) item.sources.push(source);
      else {
        item = { startMs, endMs, text: s.text, sources: [source], overlaps: false };
        timed.push(item);
      }
      if (c.index + 1 < count && startMs >= (c.index + 1) * CHUNK_RESULT_LIMITS.strideMs) {
        const bucket = next.get(key) ?? { items: [], cursor: 0 };
        bucket.items.push(item);
        next.set(key, bucket);
      }
    }
    if (section.segments.length) untimed.push(section);
    previous = next;
  }
  timed.sort((a, b) => a.startMs - b.startMs || a.sources[0].chunkIndex - b.sources[0].chunkIndex ||
    a.sources[0].segmentIndex - b.sources[0].segmentIndex);
  // Positive intersection only, including within-chunk overlaps. Touching is not overlap.
  let maxEnd = -1;
  for (let i = 0; i < timed.length; i++) {
    const item = timed[i];
    item.overlaps = maxEnd > item.startMs || (i + 1 < timed.length && timed[i + 1].startMs < item.endMs);
    maxEnd = Math.max(maxEnd, item.endMs);
  }
  const aggregate: ChunkAggregate = { version: 1, durationMs: input.durationMs, missingChunks: [...missingChunks], timed, untimed };
  // Inputs bound the entire working set to 25 * 384 KiB raw and 51,200 segments.
  // Avoid building a multi-megabyte serialized aggregate solely to find overflow.
  let aggregateBytes = utf8.encode(JSON.stringify({ ...aggregate, timed: [], untimed: [] })).byteLength;
  const add = (value: unknown) => { aggregateBytes += utf8.encode(JSON.stringify(value)).byteLength; };
  for (const [i, item] of timed.entries()) {
    if (i) aggregateBytes++;
    add(item);
    if (aggregateBytes > CHUNK_RESULT_LIMITS.aggregateBytes) break;
  }
  if (aggregateBytes <= CHUNK_RESULT_LIMITS.aggregateBytes) {
    for (const [i, section] of untimed.entries()) {
      if (i) aggregateBytes++;
      add(section);
      if (aggregateBytes > CHUNK_RESULT_LIMITS.aggregateBytes) break;
    }
  }
  if (aggregateBytes > CHUNK_RESULT_LIMITS.aggregateBytes) {
    return { version: 1, status: "too_large", originals, missingChunks, aggregate: null, aggregateBytes: null };
  }
  return { version: 1, status: missingChunks.length ? "partial" : "complete", originals, missingChunks, aggregate, aggregateBytes };
}
