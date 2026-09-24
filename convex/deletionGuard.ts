import type { MutationCtx, QueryCtx } from "./_generated/server";
import { fail } from "./limits";

export const deletionFor = (ctx: QueryCtx | MutationCtx, owner: string) =>
  ctx.db.query("deletions").withIndex("by_owner", q => q.eq("owner", owner)).unique();

export async function requireActive(ctx: QueryCtx | MutationCtx, owner: string) {
  if (await deletionFor(ctx, owner)) fail(403, "Account deletion requested. Cloud access is locked; check deletion status in Account settings.");
}
