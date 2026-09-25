import { aggregate, ceil, geometry, sha256, validateResult, type Manifest } from "./batchContract";
import { byteLength, MAX_HISTORY, MAX_MESSAGE, MAX_REPLY, MAX_TURNS } from "./limits";

export type ChatContext = { version: 1; durationMs: number; chunks: {
  index: number; attempt: number; startMs: number;
  segments: { segmentIndex: number; startMs: number | null; endMs: number | null; speaker: string | null; text: string }[];
}[] };
export type Exchange = { clientMessageId: string; contextDigest: string; message: string; reply: string };
export const CHAT_CONTEXT_BYTES = 384 * 1024;
export const history = (exchanges: Exchange[]) => exchanges.flatMap(e => [{ role: "user" as const, text: e.message }, { role: "assistant" as const, text: e.reply }]);
export function room(exchanges: Exchange[], message: string) {
  return exchanges.length < MAX_TURNS && byteLength(JSON.stringify(history(exchanges))) + byteLength(JSON.stringify(message)) + MAX_REPLY + 128 <= MAX_HISTORY;
}
export function validQuestion(message: unknown): message is string {
  return typeof message === "string" && message.length <= MAX_MESSAGE && !!message.trim() && byteLength(message) <= MAX_MESSAGE;
}
export function validReply(text: unknown): text is string {
  return typeof text === "string" && text.length <= MAX_REPLY && !!text.trim() && byteLength(JSON.stringify(text)) <= MAX_REPLY;
}
export type SelectedRaw = { index: number; attempt: number; state: string; rawText?: string };
export type ContextResult = { availability: "incomplete" | "context_too_large"; contextDigest: null; contextText: null } |
  { availability: "ready"; contextDigest: string; contextText: string };

export async function buildChatContext(m: Manifest, manifestDigest: string, selected: SelectedRaw[]): Promise<ContextResult> {
  const incomplete = { availability: "incomplete" as const, contextDigest: null, contextText: null };
  const tooLarge = { availability: "context_too_large" as const, contextDigest: null, contextText: null };
  const positions = geometry(m.source.duration), rows = [...selected].sort((a, b) => a.index - b.index);
  if (rows.length !== positions.length || rows.some((c, i) => c.index !== i || c.state !== "succeeded" || c.rawText === undefined || ![1, 2].includes(c.attempt))) return incomplete;
  const context: ChatContext = { version: 1, durationMs: Number(ceil(BigInt(m.source.duration.value) * 1000n, BigInt(m.source.duration.timescale))), chunks: [] };
  const hashes: [number, number, string][] = [];
  try {
    // Complete aggregate is a prerequisite, never the source of model context.
    const merged = aggregate(m, rows.map(c => c.rawText!));
    if (merged.status === "too_large") return tooLarge;
    if (merged.status !== "complete") return incomplete;
    for (const [index, c] of rows.entries()) {
      const raw = validateResult(c.rawText!, positions[index]);
      context.chunks.push({ index, attempt: c.attempt, startMs: positions[index].startMs,
        segments: raw.result.segments.map((s, segmentIndex) => ({ segmentIndex, startMs: s.startMs, endMs: s.endMs, speaker: s.speaker, text: s.text })) });
      if (byteLength(JSON.stringify(context)) > CHAT_CONTEXT_BYTES) return tooLarge;
      hashes.push([index, c.attempt, await sha256(new TextEncoder().encode(c.rawText!).buffer as ArrayBuffer)]);
    }
  } catch { return incomplete; }
  const canonical = JSON.stringify(["lessmeet.batch.chat.context.v1", manifestDigest, hashes]);
  return { availability: "ready", contextText: JSON.stringify(context), contextDigest: await sha256(new TextEncoder().encode(canonical).buffer as ArrayBuffer) };
}
