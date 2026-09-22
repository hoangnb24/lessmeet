import { httpRouter } from "convex/server";
import { httpAction, type ActionCtx } from "./_generated/server";
import { internal } from "./_generated/api";
import { ConvexError } from "convex/values";
import { audioTypes, fail, MAX_AUDIO, MAX_MESSAGE } from "./limits";
import { replyToTranscript, safeFailure } from "./gemini";
import { billableEnabled, billablePausedMessage } from "./billable";

function json(value: unknown, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: {
    "Content-Type": "application/json", "Cache-Control": "no-store",
  } });
}

async function identity(ctx: ActionCtx) {
  try { return await ctx.auth.getUserIdentity(); }
  catch { return null; } // Invalid JWTs can throw instead of returning null.
}

function failure(error: unknown) {
  if (error instanceof ConvexError && typeof error.data === "object" && error.data !== null &&
      "status" in error.data && "message" in error.data && typeof error.data.status === "number" && typeof error.data.message === "string") {
    return json({ error: error.data.message }, error.data.status);
  }
  return json({ error: safeFailure(error) }, 502);
}

async function body(request: Request, limit: number, type = "application/json"): Promise<Blob> {
  const declared = request.headers.get("content-length");
  if (declared && Number(declared) > limit) fail(413, "Request is too large. Audio must be at most 18 MiB; chat messages at most 8 KiB.");
  if (!request.body) fail(400, "Request body is required.");
  const reader = request.body.getReader();
  const chunks: BlobPart[] = [];
  let size = 0;
  try {
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) break;
      size += chunk.value.byteLength;
      if (size > limit) {
        await reader.cancel();
        fail(413, "Request is too large. Split the recording or shorten the message.");
      }
      chunks.push(chunk.value);
    }
  } finally { reader.releaseLock(); }
  if (!size) fail(400, "Request body is empty.");
  return new Blob(chunks, { type });
}

const http = httpRouter();

// Read-only connection check. No upload, storage, or billable AI invocation.
http.route({
  path: "/account",
  method: "GET",
  handler: httpAction(async (ctx) => {
    const account = await identity(ctx);
    const headers = { "Content-Type": "application/json", "Cache-Control": "no-store" };
    if (!account) {
      return new Response(JSON.stringify({ error: "Sign in to LessMeet first." }), { status: 401, headers });
    }
    return new Response(JSON.stringify({ userId: account.subject }), { status: 200, headers });
  }),
});

http.route({ path: "/recordings", method: "POST", handler: httpAction(async (ctx, request) => {
  if (!billableEnabled()) return json({ error: billablePausedMessage }, 503);
  if (!await identity(ctx)) return json({ error: "Sign in to LessMeet first." }, 401);
  try {
    let mimeType = request.headers.get("content-type")?.split(";")[0].trim().toLowerCase() ?? "";
    if (!audioTypes.has(mimeType)) fail(415, "Send raw supported audio with its audio Content-Type, not multipart data.");
    if (mimeType === "audio/mp4") mimeType = "audio/m4a";
    const audio = await ctx.storage.store(await body(request, MAX_AUDIO, mimeType));
    try {
      const recordingId = await ctx.runMutation(internal.recordings.create, { audio, mimeType });
      return json({ recordingId }, 202);
    } catch (error) {
      try { await ctx.storage.delete(audio); } catch {
        return json({ error: "Recording could not be scheduled and upload cleanup failed. Contact the app owner before uploading again." }, 500);
      }
      throw error;
    }
  } catch (error) { return failure(error); }
}) });

http.route({ path: "/recordings", method: "GET", handler: httpAction(async (ctx, request) => {
  if (!await identity(ctx)) return json({ error: "Sign in to LessMeet first." }, 401);
  try {
    return json(await ctx.runQuery(internal.recordings.get, { id: new URL(request.url).searchParams.get("id") ?? "" }));
  } catch (error) { return failure(error); }
}) });

http.route({ path: "/chat", method: "POST", handler: httpAction(async (ctx, request) => {
  if (!billableEnabled()) return json({ error: billablePausedMessage }, 503);
  if (!await identity(ctx)) return json({ error: "Sign in to LessMeet first." }, 401);
  try {
    if (request.headers.get("content-type")?.split(";")[0].trim().toLowerCase() !== "application/json") fail(415, "Send chat as application/json.");
    let input: unknown;
    try { input = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(await (await body(request, MAX_MESSAGE * 6 + 1024)).arrayBuffer())); }
    catch (error) { if (error instanceof ConvexError) throw error; fail(400, "Chat body must be valid UTF-8 JSON."); }
    if (!input || typeof input !== "object" || !("recordingId" in input) || typeof input.recordingId !== "string" ||
        !("message" in input) || typeof input.message !== "string") fail(400, "Provide recordingId and message strings.");
    const { recordingId, message } = input;
    const lease = crypto.randomUUID();
    const context = await ctx.runMutation(internal.recordings.reserveChat, { id: recordingId, message, lease });
    try {
      const text = await replyToTranscript(context.transcript, context.messages, message);
      await ctx.runMutation(internal.recordings.finishChat, { id: recordingId, message, lease, text });
      return json({ text });
    } finally {
      // A matching lease prevents an old request from unlocking a newer reply.
      await ctx.runMutation(internal.recordings.releaseChat, { id: context.id, lease });
    }
  } catch (error) { return failure(error); }
}) });

export default http;
