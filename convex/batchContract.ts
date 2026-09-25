import { ConvexError } from "convex/values";
import { mergeChunkResults, validateChunkResult, type ChunkMergeResult } from "./chunkResults";

export type Rational = { value: number; timescale: number };
export type Manifest = { version: 1; source: { sha256: string; bytes: number; duration: Rational }; chunks: { sha256: string; bytes: number }[] };
export const failBatch = (status: number, code: string, message: string): never => { throw new ConvexError({ status, code, message }); };
export function malformed(): never { return failBatch(400, "malformed", "Invalid batch request."); }
export function exact(x: unknown, keys: string[]): x is Record<string, unknown> {
  return !!x && typeof x === "object" && !Array.isArray(x) && Object.keys(x).length === keys.length && keys.every(k => Object.hasOwn(x, k));
}
export const uuid = (x: unknown): x is string => typeof x === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(x);
const positive = (x: unknown): x is number => typeof x === "number" && Number.isSafeInteger(x) && x > 0;
const hash = (x: unknown): x is string => typeof x === "string" && /^[0-9a-f]{64}$/.test(x);
export const ceil = (n: bigint, d: bigint) => (n + d - 1n) / d;
export function geometry(r: Rational) {
  const n = BigInt(r.value), d = BigInt(r.timescale);
  const count = 1 + Number(ceil(n > 300n * d ? n - 300n * d : 0n, 295n * d));
  return Array.from({ length: count }, (_, index) => {
    const start = BigInt(295 * index) * d;
    const duration = n - start < 300n * d ? n - start : 300n * d;
    const canonicalEnd = index + 1 < count ? start + 295n * d : n;
    return { index, value: Number(duration), timescale: r.timescale,
      startMs: index * 295000, endMs: Number(ceil((start + duration) * 1000n, d)),
      floorMs: Number(duration * 1000n / d), envelopeMs: Number(ceil(duration * 1000n, d)),
      quota: Number(ceil(canonicalEnd, d) - ceil(start, d)) };
  });
}
export function manifest(value: unknown): Manifest {
  if (!exact(value, ["version", "source", "chunks"]) || value.version !== 1 || !exact(value.source, ["sha256", "bytes", "duration"])) malformed();
  const s = value.source;
  if (!hash(s.sha256) || !positive(s.bytes) || !exact(s.duration, ["value", "timescale"])) malformed();
  const r = s.duration;
  if (!positive(r.value) || !positive(r.timescale) || r.timescale > 2147483647 || BigInt(r.value) > 7200n * BigInt(r.timescale)) malformed();
  let a = BigInt(r.value), b = BigInt(r.timescale);
  while (b) [a, b] = [b, a % b];
  if (a !== 1n) malformed();
  if (!Array.isArray(value.chunks) || value.chunks.length !== geometry(r as Rational).length || value.chunks.length > 25) malformed();
  for (const c of value.chunks) if (!exact(c, ["sha256", "bytes"]) || !hash(c.sha256) || !positive(c.bytes) || c.bytes > 18874368) malformed();
  return value as Manifest;
}
export async function sha256(bytes: ArrayBuffer) {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)), b => b.toString(16).padStart(2, "0")).join("");
}
export function digestInput(m: Manifest) {
  return JSON.stringify(["lessmeet.batch.geometry.v1", m.source.sha256, m.source.bytes, m.source.duration.value,
    m.source.duration.timescale, m.chunks.map((c, i) => [i, c.sha256, c.bytes])]);
}
export const digest = (m: Manifest) => sha256(new TextEncoder().encode(digestInput(m)).buffer as ArrayBuffer);

// Control bodies are bounded before this duplicate-key scan; JSON.parse validates syntax.
export function controlJSON(raw: string): unknown {
  let result: unknown;
  try { result = JSON.parse(raw); } catch { return malformed(); }
  const stack: Set<string>[] = [];
  for (let i = 0; i < raw.length; i++) {
    if (raw[i] === "{") { if (stack.length >= 8) malformed(); stack.push(new Set()); }
    else if (raw[i] === "}") stack.pop();
    else if (raw[i] === '"') {
      const start = i++;
      while (i < raw.length && raw[i] !== '"') { if (raw[i] === "\\") i++; i++; }
      let j = i + 1;
      while (/\s/.test(raw[j] ?? "x")) j++;
      if (raw[j] === ":") {
        const key = JSON.parse(raw.slice(start, i + 1)) as string, keys = stack[stack.length - 1];
        if (!keys || keys.has(key)) malformed();
        keys.add(key);
      }
    }
  }
  return result;
}
export function validateResult(raw: string, r: Rational) {
  const floor = Number(BigInt(r.value) * 1000n / BigInt(r.timescale));
  const envelope = Number(ceil(BigInt(r.value) * 1000n, BigInt(r.timescale)));
  const result = validateChunkResult(raw, envelope);
  if (result.result.segments.some(s => s.endMs !== null && s.endMs > floor)) throw new Error("Timestamp outside actual presentation");
  return result;
}
export function aggregate(m: Manifest, results: (string | null)[]): ChunkMergeResult {
  return mergeChunkResults({ durationMs: Number(ceil(BigInt(m.source.duration.value) * 1000n, BigInt(m.source.duration.timescale))),
    chunks: geometry(m.source.duration).map((c, i) => ({ index: i, startMs: c.startMs, endMs: c.endMs, rawText: results[i] })) });
}
export function enabled() { return process.env.BATCH_TRANSCRIPTION_ENABLED === "true"; }
export function requireEnabled() { if (!enabled()) failBatch(503, "disabled", "Batch transcription is disabled."); }
export function allowOwner(owner: string) {
  if (!process.env.BATCH_TRANSCRIPTION_OWNER || owner !== process.env.BATCH_TRANSCRIPTION_OWNER) failBatch(403, "not_allowed", "Batch transcription is not available for this account.");
}
