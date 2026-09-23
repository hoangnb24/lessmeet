/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as billable from "../billable.js";
import type * as billing from "../billing.js";
import type * as gemini from "../gemini.js";
import type * as http from "../http.js";
import type * as jobs from "../jobs.js";
import type * as limits from "../limits.js";
import type * as recordings from "../recordings.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  billable: typeof billable;
  billing: typeof billing;
  gemini: typeof gemini;
  http: typeof http;
  jobs: typeof jobs;
  limits: typeof limits;
  recordings: typeof recordings;
}>;

/**
 * A utility for referencing Convex functions in your app's public API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = api.myModule.myFunction;
 * ```
 */
export declare const api: FilterApi<
  typeof fullApi,
  FunctionReference<any, "public">
>;

/**
 * A utility for referencing Convex functions in your app's internal API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = internal.myModule.myFunction;
 * ```
 */
export declare const internal: FilterApi<
  typeof fullApi,
  FunctionReference<any, "internal">
>;

export declare const components: {};
