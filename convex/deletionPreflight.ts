import { v } from "convex/values";
import { internalAction, internalMutation, internalQuery, type QueryCtx, type MutationCtx } from "./_generated/server";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { exactRequest } from "./deletionAutomationState";
import { LEASE_MS, MAX_ATTEMPTS, retryDelay } from "./deletionAdapter";
import { preflightEnabled, preflightConfig, bindingMatches, readPreflightPage, identifier, validSession } from "./preflightAdapter";
import { codes, pageResult, MAX_CLAIMS, MAX_ITEMS, MAX_PAGES, PAGE_SIZE, type PageResult } from "./preflightContract";

const requestArgs = { id: v.id("deletions"), owner: v.string() };
const fenceArgs = { id: v.id("deletionPreflights"), owner: v.string(), subject: v.string(), config: v.string(), fence: v.number(), cursor: v.string() };
export const PREFLIGHT_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;
const PURGE_BATCH = 16;
type Row = Doc<"deletionPreflights">;
type Fence = { id: Id<"deletionPreflights">; owner: string; subject: string; config: string; fence: number; cursor: string };
function matches(s: Row | null, a: Fence): s is Row {
  return !!s && s.state === "running" && s.owner === a.owner && s.subject === a.subject && s.config === a.config &&
    s.fence === a.fence && s.cursor === a.cursor && s.leaseUntil !== undefined && s.leaseUntil > Date.now();
}
async function targetMatches(ctx: QueryCtx | MutationCtx, s: Row) {
  const d = await ctx.db.get(s.request);
  return !!d && d.owner === s.owner && d.subject === s.subject && d.requestedAt === s.requestedAt && bindingMatches(s);
}
const purgeAt = () => Date.now() + PREFLIGHT_RETENTION_MS;
// Independent sidecar of the accepted worker. Never patch deletion flags, intent,
// contact/send snapshots, manual evidence, or destructive-provider stages.
export const start = internalMutation({ args: requestArgs, handler: async (ctx, { id, owner }) => {
  const d = await exactRequest(ctx, id, owner);
  if (!preflightEnabled() || d.automationRevision === undefined) return;
  for (const provider of ["clerk", "revenuecat"] as const) {
    const existing = await ctx.db.query("deletionPreflights").withIndex("by_request_provider", q => q.eq("request", id).eq("provider", provider)).unique();
    const receipt = await ctx.db.query("deletionPreflightReceipts").withIndex("by_request_provider", q => q.eq("request", id).eq("provider", provider)).unique();
    if (existing || receipt) continue; // Frozen once, including after identifier compaction.
    const config = preflightConfig(provider) ?? "";
    const phase = provider === "clerk" ? "user" : "customer";
    const target = { owner, subject: d.subject, provider, config, phase, cursor: "" } as const;
    const code = !config ? "config_unverified" : !bindingMatches(target) ? "identity_mismatch" : "inventory_observed";
    const row = await ctx.db.insert("deletionPreflights", { request: id, requestedAt: d.requestedAt, ...target,
      state: code === "inventory_observed" ? "queued" : "blocked", code, inventoryComplete: false,
      fence: 0, attempts: 0, claims: 0, pages: 0, due: Date.now(), createdAt: Date.now(), updatedAt: Date.now(),
      purgeAt: purgeAt(), externalAccounts: [], sessions: [], aliases: [], cursors: [] });
    if (code === "inventory_observed") await ctx.scheduler.runAfter(0, internal.deletionPreflight.run, { id: row });
  }
} });

export const claim = internalMutation({ args: { id: v.id("deletionPreflights") }, handler: async (ctx, { id }) => {
  const s = await ctx.db.get(id);
  if (!s || !preflightEnabled() || !["queued", "retry"].includes(s.state) || s.due > Date.now()) return null;
  if (!await targetMatches(ctx, s)) {
    await ctx.db.patch(id, { state: "blocked", code: "config_changed", updatedAt: Date.now(), purgeAt: purgeAt() }); return null;
  }
  if (s.attempts >= MAX_ATTEMPTS || s.claims >= MAX_CLAIMS) {
    await ctx.db.patch(id, { state: "exhausted", code: "attempts_exhausted", updatedAt: Date.now(), purgeAt: purgeAt() }); return null;
  }
  const leaseUntil = Date.now() + LEASE_MS;
  await ctx.db.patch(id, { state: "running", attempts: s.attempts + 1, claims: s.claims + 1, fence: s.fence + 1,
    leaseUntil, due: leaseUntil, updatedAt: Date.now(), purgeAt: purgeAt() });
  await ctx.scheduler.runAt(leaseUntil, internal.deletionPreflight.expire, { id, fence: s.fence + 1 });
  return (await ctx.db.get(id))!;
} });
export const authorized = internalQuery({ args: fenceArgs, handler: async (ctx, args) => {
  const s = await ctx.db.get(args.id);
  return preflightEnabled() && matches(s, args) && await targetMatches(ctx, s);
} });

function validatePage(s: Row, r: PageResult): boolean {
  if (r.code !== "inventory_observed" || r.retryAfterMs !== undefined) return false;
  switch (s.phase) {
    case "user": return r.externalAccounts !== undefined && r.externalAccounts.length <= 128 && r.sessions === undefined && r.aliases === undefined && r.next === undefined &&
      r.externalAccounts.every(e => identifier(e.id) && identifier(e.provider) && identifier(e.providerUserId)) && new Set(r.externalAccounts.map(e => e.id)).size === r.externalAccounts.length;
    case "customer": return r.externalAccounts === undefined && r.sessions === undefined && r.aliases === undefined && r.next === undefined;
    case "sessions": return r.externalAccounts === undefined && r.aliases === undefined && r.sessions !== undefined && r.sessions.length <= PAGE_SIZE && r.sessions.every(validSession) &&
      (r.sessions.length === PAGE_SIZE ? r.next === String(Number(s.cursor) + PAGE_SIZE) : r.next === undefined);
    case "aliases": return r.externalAccounts === undefined && r.sessions === undefined && r.aliases !== undefined && r.aliases.length <= PAGE_SIZE &&
      r.aliases.every(a => identifier(a, 1500)) && (r.next === undefined || (!!r.next && r.next === r.aliases.at(-1)));
  }
}
export const finish = internalMutation({ args: { ...fenceArgs, result: pageResult }, handler: async (ctx, args) => {
  const s = await ctx.db.get(args.id);
  if (!matches(s, args)) return false;
  let r = args.result;
  if (!preflightEnabled() || !await targetMatches(ctx, s)) r = { state: "blocked", code: "config_changed" };
  if (!(codes as readonly string[]).includes(r.code) || (r.retryAfterMs !== undefined && (!Number.isFinite(r.retryAfterMs) || r.retryAfterMs < 0 || r.retryAfterMs > Number.MAX_SAFE_INTEGER - Date.now())) ||
      (r.state === "page" ? !validatePage(s, r) : r.externalAccounts !== undefined || r.sessions !== undefined || r.aliases !== undefined || r.next !== undefined ||
        (r.state === "retry" ? !["provider_temporary", "transport_unknown"].includes(r.code) : ["inventory_observed", "provider_temporary", "transport_unknown"].includes(r.code)))) {
    r = { state: "blocked", code: "malformed_response" };
  }
  const common = { leaseUntil: undefined, updatedAt: Date.now(), purgeAt: purgeAt() };
  if (r.state !== "page") {
    const state = r.state === "retry" && (s.attempts >= MAX_ATTEMPTS || s.claims >= MAX_CLAIMS) ? "exhausted" : r.state;
    const due = state === "retry" ? Date.now() + retryDelay(s.attempts, Math.random(), r.retryAfterMs) : s.due;
    await ctx.db.patch(s._id, { ...common, state, code: r.code, due });
    if (state === "retry") await ctx.scheduler.runAt(due, internal.deletionPreflight.run, { id: s._id });
    return true;
  }
  const sessions = [...s.sessions, ...(r.sessions ?? [])], aliases = [...s.aliases, ...(r.aliases ?? [])];
  const cursors = [...s.cursors, s.cursor];
  if (new Set(sessions.map(e => e.id)).size !== sessions.length || new Set(aliases).size !== aliases.length || (r.next !== undefined && cursors.includes(r.next))) {
    await ctx.db.patch(s._id, { ...common, state: "blocked", code: "pagination_changed" }); return true;
  }
  const list = s.phase === "sessions" || s.phase === "aliases";
  const pages = s.pages + (list ? 1 : 0);
  if (sessions.length > MAX_ITEMS || aliases.length > MAX_ITEMS || (list && r.next !== undefined && pages >= MAX_PAGES)) {
    await ctx.db.patch(s._id, { ...common, state: "blocked", code: "pagination_limit" }); return true;
  }
  const externalAccounts = r.externalAccounts ?? s.externalAccounts;
  const done = list && r.next === undefined;
  const code = done && s.provider === "clerk" && externalAccounts.some(e => ["oauth_apple", "apple"].includes(e.provider)) ? "apple_provenance_unverified" :
    done && s.provider === "revenuecat" && aliases.some(a => a !== s.subject) ? "alias_ownership_unverified" : "inventory_observed";
  const phase = s.phase === "user" ? "sessions" : s.phase === "customer" ? "aliases" : s.phase;
  const cursor = s.phase === "user" ? "0" : s.phase === "customer" ? "" : r.next ?? s.cursor;
  await ctx.db.patch(s._id, { ...common, phase, cursor, pages, externalAccounts, sessions, aliases,
    cursors: list ? cursors : [], inventoryComplete: done, code,
    state: done ? (code === "inventory_observed" ? "observed" : "blocked") : "queued", attempts: 0, due: Date.now() });
  if (!done) await ctx.scheduler.runAfter(0, internal.deletionPreflight.run, { id: s._id });
  return true;
} });
export const run = internalAction({ args: { id: v.id("deletionPreflights") }, handler: async (ctx, { id }): Promise<void> => {
  const row: Row | null = await ctx.runMutation(internal.deletionPreflight.claim, { id });
  if (!row) return;
  const args = { id, owner: row.owner, subject: row.subject, config: row.config, fence: row.fence, cursor: row.cursor };
  if (!await ctx.runQuery(internal.deletionPreflight.authorized, args)) return;
  const result = await readPreflightPage(row);
  await ctx.runMutation(internal.deletionPreflight.finish, { ...args, result });
} });
export const expire = internalMutation({ args: { id: v.id("deletionPreflights"), fence: v.number() }, handler: async (ctx, { id, fence }) => {
  const s = await ctx.db.get(id);
  if (!s || s.state !== "running" || s.fence !== fence || s.leaseUntil === undefined || s.leaseUntil > Date.now()) return;
  const state = s.attempts >= MAX_ATTEMPTS || s.claims >= MAX_CLAIMS ? "exhausted" : "retry";
  const due = Date.now() + retryDelay(s.attempts, Math.random());
  await ctx.db.patch(id, { state, fence: s.fence + 1, code: "lease_expired_unknown", leaseUntil: undefined, due, updatedAt: Date.now(), purgeAt: purgeAt() });
  if (preflightEnabled() && state === "retry") await ctx.scheduler.runAt(due, internal.deletionPreflight.run, { id });
} });
export const recover = internalMutation({ args: {}, handler: async ctx => {
  if (!preflightEnabled()) return;
  for (const state of ["queued", "retry", "running"] as const) {
    const rows = await ctx.db.query("deletionPreflights").withIndex("by_state_due", q => q.eq("state", state).lte("due", Date.now())).take(16);
    for (const s of rows) {
      if (state === "running") await ctx.scheduler.runAfter(0, internal.deletionPreflight.expire, { id: s._id, fence: s.fence });
      else await ctx.scheduler.runAfter(0, internal.deletionPreflight.run, { id: s._id });
    }
  }
} });
export const purgeExpired = internalMutation({ args: {}, handler: async ctx => {
  const compact = async (s: Row) => {
    const existing = await ctx.db.query("deletionPreflightReceipts").withIndex("by_request_provider", q => q.eq("request", s.request).eq("provider", s.provider)).unique();
    if (!existing) await ctx.db.insert("deletionPreflightReceipts", { request: s.request, provider: s.provider,
      state: s.state, code: s.code, inventoryComplete: s.inventoryComplete, createdAt: s.createdAt,
      updatedAt: s.updatedAt, purgedAt: Date.now() });
    await ctx.db.delete(s._id);
  };
  const legacy = await ctx.db.query("deletionPreflights").filter(q => q.eq(q.field("purgeAt"), undefined)).take(PURGE_BATCH);
  let compacted = 0;
  for (const s of legacy) {
    const deadline = s.updatedAt + PREFLIGHT_RETENTION_MS;
    if (deadline <= Date.now()) { await compact(s); compacted += 1; }
    else await ctx.db.patch(s._id, { purgeAt: deadline });
  }
  const rows = compacted < PURGE_BATCH ? await ctx.db.query("deletionPreflights")
    .withIndex("by_purge_at", q => q.lte("purgeAt", Date.now())).take(PURGE_BATCH - compacted) : [];
  for (const s of rows) await compact(s);
  return compacted + rows.length;
} });
export const inventory = internalQuery({ args: requestArgs, handler: async (ctx, { id, owner }) => {
  await exactRequest(ctx, id, owner);
  return { enabled: preflightEnabled(), observations: await ctx.db.query("deletionPreflights")
    .withIndex("by_request_provider", q => q.eq("request", id)).take(2), receipts: await ctx.db.query("deletionPreflightReceipts")
    .withIndex("by_request_provider", q => q.eq("request", id)).take(2) };
} });
