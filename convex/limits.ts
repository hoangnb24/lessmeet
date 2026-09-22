import { ConvexError } from "convex/values";

export const MAX_AUDIO = 18 * 1024 * 1024;
export const MAX_TRANSCRIPT = 384 * 1024;
export const MAX_MESSAGE = 8 * 1024;
export const MAX_REPLY = 32 * 1024;
export const MAX_HISTORY = 128 * 1024;
export const MAX_TURNS = 20;
export const JOB_TIMEOUT = 5 * 60_000;
export const CHAT_TIMEOUT = 2 * 60_000;
export const audioTypes = new Set([
  "audio/m4a", "audio/mp4", "audio/mpeg", "audio/mp3", "audio/wav",
  "audio/aac", "audio/flac", "audio/ogg", "audio/aiff",
]);
export const byteLength = (text: string) => new TextEncoder().encode(text).byteLength;
export function fail(status: number, message: string): never {
  throw new ConvexError({ status, message });
}
export function validateMessage(message: string) {
  if (!message.trim() || byteLength(message) > MAX_MESSAGE) {
    fail(400, "Send a nonempty message of at most 8 KiB.");
  }
}
