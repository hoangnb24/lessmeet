import type { HttpRouter } from "convex/server";
import { ConvexError } from "convex/values";
import { httpAction } from "./_generated/server";
import { internal } from "./_generated/api";
import { manifest, digest, controlJSON, exact, uuid, malformed, failBatch, sha256, geometry, requireEnabled, allowOwner } from "./batchContract";
import { batchMedia } from "./batchMedia";
import { refreshBilling } from "./revenuecat";

const base = "/v1/transcription-batches";
function json(value: unknown, status = 200) { return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } }); }
async function body(request: Request, max: number) {
  const declared = request.headers.get("content-length");
  if (declared && (!/^\d+$/.test(declared) || Number(declared) > max)) failBatch(413, "size", "Request exceeds the batch size limit.");
  if (!request.body) return malformed();
  const reader = request.body.getReader(), parts: Uint8Array[] = []; let size = 0;
  try { while (true) { const next = await reader.read(); if (next.done) break; size += next.value.byteLength; if (size > max) { await reader.cancel(); failBatch(413, "size", "Request exceeds the batch size limit."); } parts.push(next.value); } }
  finally { reader.releaseLock(); }
  if (!size) return malformed();
  const result = new Uint8Array(size); let offset = 0;
  for (const p of parts) { result.set(p, offset); offset += p.byteLength; }
  return result.buffer;
}
function query(url: URL, keys: string[]) {
  const entries = [...url.searchParams.entries()];
  if (entries.length !== keys.length || keys.some(k => url.searchParams.getAll(k).length !== 1) || entries.some(([k, val]) => !keys.includes(k) || !val)) malformed();
  return Object.fromEntries(entries);
}
function index(raw: string) { if (!/^(0|[1-9]\d?)$/.test(raw) || Number(raw) > 24) malformed(); return Number(raw); }
export { body as batchBody, query as batchQuery, json as batchJSON };
export function batchRoutes(http: HttpRouter) {
  for (const [suffix, method] of [["", "POST"], ["", "GET"], ["/chunk", "PUT"], ["/seal", "POST"], ["/retry", "POST"], ["/result", "GET"], ["/aggregate", "GET"]] as const) {
    http.route({ path: base + suffix, method, handler: httpAction(async (ctx, request) => {
      let who;
      try { who = await ctx.auth.getUserIdentity(); } catch { who = null; }
      if (!who) return json({ version: 1, error: { code: "auth", message: "Sign in to LessMeet first." } }, 401);
      try {
        if (method !== "GET") { requireEnabled(); allowOwner(who.tokenIdentifier); }
        await ctx.runQuery(internal.deletion.check, { owner: who.tokenIdentifier });
        const url = new URL(request.url);
        if (method === "GET") {
          if (!suffix) {
            const keys = url.searchParams.has("batchId") ? ["batchId"] : ["clientBatchId"], q = query(url, keys);
            if (q.clientBatchId && !uuid(q.clientBatchId)) malformed();
            return json(await ctx.runQuery(internal.batches.get, q));
          }
          const q = query(url, suffix === "/result" ? ["batchId", "index", "attempt"] : ["batchId"]);
          if (suffix === "/aggregate") return json(await ctx.runQuery(internal.batches.merged, { batchId: q.batchId }));
          if (!["1", "2"].includes(q.attempt)) malformed();
          return json(await ctx.runQuery(internal.batches.result, { batchId: q.batchId, index: index(q.index), attempt: Number(q.attempt) }));
        }
        if (method === "PUT") {
          const q = query(url, ["batchId", "index"]), i = index(q.index);
          const admitted = await ctx.runQuery(internal.batches.admission, { batchId: q.batchId, index: i });
          if (request.headers.get("content-type")?.split(";")[0].trim().toLowerCase() !== "audio/m4a") failBatch(415, "media", "Send raw audio/m4a bytes.");
          const bytes = await body(request, 18874368), expected = admitted.manifest.chunks[i];
          if (!expected || bytes.byteLength !== expected.bytes || await sha256(bytes) !== expected.sha256) failBatch(409, "digest", "Chunk bytes do not match the immutable manifest.");
          const metadata = batchMedia(bytes, geometry(admitted.manifest.source.duration)[i]);
          const begin = await ctx.runMutation(internal.batches.beginUpload, { batchId: q.batchId, index: i });
          let unresolved = begin.unresolved;
          if (begin.work) {
            try {
              const audio = await ctx.storage.store(new Blob([bytes], { type: "audio/m4a" }));
              const attached = await ctx.runMutation(internal.batches.finishUpload, { batchId: q.batchId, index: i, fence: begin.fence, work: begin.work, audio, metadata: JSON.stringify(metadata) });
              if (!attached) failBatch(403, "deleting", "Account deletion prevents publishing this upload.");
            } catch { unresolved = true; }
          }
          return json(await ctx.runQuery(internal.batches.get, { batchId: q.batchId }), unresolved ? 202 : 200);
        }
        if (url.search) malformed();
        if (request.headers.get("content-type")?.split(";")[0].trim().toLowerCase() !== "application/json") failBatch(400, "malformed", "Send application/json.");
        let input: unknown;
        try { input = controlJSON(new TextDecoder("utf-8", { fatal: true }).decode(await body(request, 16384))); }
        catch (e) { if (e instanceof ConvexError) throw e; return malformed(); }
        if (!suffix) {
          if (!exact(input, ["clientBatchId", "manifest"]) || !uuid(input.clientBatchId)) malformed();
          const m = manifest(input.manifest), result = await ctx.runMutation(internal.batches.create, { clientBatchId: input.clientBatchId, manifest: m, manifestDigest: await digest(m) });
          return json(await ctx.runQuery(internal.batches.get, { batchId: result.id }), result.created ? 201 : 200);
        }
        if (suffix === "/seal") {
          if (!exact(input, ["batchId", "manifestDigest"]) || typeof input.batchId !== "string" || typeof input.manifestDigest !== "string") malformed();
          const needed = await ctx.runQuery(internal.batches.controlAdmission, { batchId: input.batchId, manifestDigest: input.manifestDigest });
          if (needed) {
            const fence = await ctx.runMutation(internal.batches.beginControlBilling, {});
            try { const revision = await refreshBilling(ctx, who); await ctx.runMutation(internal.batches.seal, { batchId: input.batchId, manifestDigest: input.manifestDigest, revision }); }
            finally { await ctx.runMutation(internal.batches.endDispatch, { fence }); }
          }
          return json(await ctx.runQuery(internal.batches.get, { batchId: input.batchId }), 202);
        }
        if (!exact(input, ["batchId", "index", "expectedAttempt", "expectedFence", "requestId", "confirm"]) || typeof input.batchId !== "string" ||
            !Number.isSafeInteger(input.index) || Number(input.index) < 0 || Number(input.index) > 24 || input.expectedAttempt !== 1 ||
            !Number.isSafeInteger(input.expectedFence) || Number(input.expectedFence) < 0 || !uuid(input.requestId) || input.confirm !== "retry-failed-chunk") malformed();
        const needed = await ctx.runQuery(internal.batches.controlAdmission, { batchId: input.batchId, index: Number(input.index), expectedFence: Number(input.expectedFence), requestId: input.requestId });
        if (needed) {
          const fence = await ctx.runMutation(internal.batches.beginControlBilling, {});
          try { const revision = await refreshBilling(ctx, who); await ctx.runMutation(internal.batches.retry, { batchId: input.batchId, index: Number(input.index), expectedAttempt: 1, expectedFence: Number(input.expectedFence), requestId: input.requestId, revision }); }
          finally { await ctx.runMutation(internal.batches.endDispatch, { fence }); }
        }
        return json(await ctx.runQuery(internal.batches.get, { batchId: input.batchId }), 202);
      } catch (e) {
        if (e instanceof ConvexError && e.data && typeof e.data === "object" && "status" in e.data && "message" in e.data) {
          return json({ version: 1, error: { code: "code" in e.data ? e.data.code : "unavailable", message: e.data.message } }, Number(e.data.status));
        }
        return json({ version: 1, error: { code: "upstream", message: "Batch operation could not complete. Refresh its status before continuing." } }, 502);
      }
    }) });
  }
}
