import type { HttpRouter } from "convex/server";
import { ConvexError } from "convex/values";
import { httpAction } from "./_generated/server";
import { internal } from "./_generated/api";
import { batchBody, batchQuery, batchJSON as json } from "./batchHttp";
import { controlJSON, exact, malformed, uuid } from "./batchContract";
import { refreshBilling } from "./revenuecat";
import type { ChatRequest } from "./batchChat";

const base = "/v1/transcription-batches/chat";
const operationStatus = (op: { state: string }) => ["succeeded", "failed"].includes(op.state) ? 200 : 202;
export function batchChatRoutes(http: HttpRouter) {
  for (const [suffix, method] of [["", "GET"], ["/message", "GET"], ["/message", "POST"]] as const) {
    http.route({ path: base + suffix, method, handler: httpAction(async (ctx, request) => {
      let who;
      try { who = await ctx.auth.getUserIdentity(); } catch { who = null; }
      if (!who) return json({ version: 1, error: { code: "auth", message: "Sign in to LessMeet first." } }, 401);
      try {
        const url = new URL(request.url);
        if (method === "GET") {
          const q = batchQuery(url, suffix ? ["batchId", "clientMessageId"] : ["batchId"]);
          if (!suffix) return json(await ctx.runQuery(internal.batchChat.get, { batchId: q.batchId }));
          if (!uuid(q.clientMessageId)) malformed();
          return json(await ctx.runQuery(internal.batchChat.receipt, { batchId: q.batchId, clientMessageId: q.clientMessageId }));
        }
        if (url.search || request.headers.get("content-type")?.split(";")[0].trim().toLowerCase() !== "application/json") malformed();
        let input: unknown;
        try { input = controlJSON(new TextDecoder("utf-8", { fatal: true }).decode(await batchBody(request, 50176))); }
        catch (e) { if (e instanceof ConvexError) throw e; return malformed(); }
        if (!exact(input, ["batchId", "clientMessageId", "expectedContextDigest", "expectedHistoryRevision", "message"]) || typeof input.batchId !== "string" ||
            typeof input.clientMessageId !== "string" || typeof input.expectedContextDigest !== "string" || typeof input.expectedHistoryRevision !== "number" || typeof input.message !== "string") malformed();
        const args = input as ChatRequest;
        const prepared = await ctx.runQuery(internal.batchChat.prepare, args);
        if (prepared.replay) return json(prepared.replay, operationStatus(prepared.replay));
        try {
          const billingRevision = await refreshBilling(ctx, who);
          const op = await ctx.runMutation(internal.batchChat.admit, { ...args, billingRevision });
          return json(op, operationStatus(op));
        } catch (e) {
          // Concurrent identical requests may have committed while verification
          // was in flight. Recovery is read-only; do not refresh/reserve twice.
          try { const recovered = await ctx.runQuery(internal.batchChat.prepare, args); if (recovered.replay) return json(recovered.replay, operationStatus(recovered.replay)); } catch { /* retain original failure */ }
          throw e;
        }
      } catch (e) {
        if (e instanceof ConvexError && e.data && typeof e.data === "object" && "status" in e.data && "message" in e.data) {
          return json({ version: 1, error: { code: "code" in e.data ? e.data.code : "unavailable", message: e.data.message } }, Number(e.data.status));
        }
        return json({ version: 1, error: { code: "upstream", message: "Chat operation could not complete. Recover its exact identity before sending again." } }, 502);
      }
    }) });
  }
}
