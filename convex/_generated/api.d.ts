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
import type * as batches from "../batches.js";
import type * as batchJobs from "../batchJobs.js";
import type * as batchChat from "../batchChat.js";
import type * as batchChatJobs from "../batchChatJobs.js";
import type * as billing from "../billing.js";
import type * as billingPolicy from "../billingPolicy.js";
import type * as crons from "../crons.js";
import type * as deletion from "../deletion.js";
import type * as deletionAdapter from "../deletionAdapter.js";
import type * as deletionAutomation from "../deletionAutomation.js";
import type * as deletionAutomationState from "../deletionAutomationState.js";
import type * as deletionGuard from "../deletionGuard.js";
import type * as deletionNotifications from "../deletionNotifications.js";
import type * as deletionPreflight from "../deletionPreflight.js";
import type * as deletionRetention from "../deletionRetention.js";
import type * as gemini from "../gemini.js";
import type * as http from "../http.js";
import type * as jobs from "../jobs.js";
import type * as limits from "../limits.js";
import type * as media from "../media.js";
import type * as notificationAdapter from "../notificationAdapter.js";
import type * as preflightAdapter from "../preflightAdapter.js";
import type * as preflightContract from "../preflightContract.js";
import type * as recordings from "../recordings.js";
import type * as revenuecat from "../revenuecat.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  batches: typeof batches;
  batchJobs: typeof batchJobs;
  batchChat: typeof batchChat;
  batchChatJobs: typeof batchChatJobs;
  billable: typeof billable;
  billing: typeof billing;
  billingPolicy: typeof billingPolicy;
  crons: typeof crons;
  deletion: typeof deletion;
  deletionAdapter: typeof deletionAdapter;
  deletionAutomation: typeof deletionAutomation;
  deletionAutomationState: typeof deletionAutomationState;
  deletionGuard: typeof deletionGuard;
  deletionNotifications: typeof deletionNotifications;
  deletionPreflight: typeof deletionPreflight;
  deletionRetention: typeof deletionRetention;
  gemini: typeof gemini;
  http: typeof http;
  jobs: typeof jobs;
  limits: typeof limits;
  media: typeof media;
  notificationAdapter: typeof notificationAdapter;
  preflightAdapter: typeof preflightAdapter;
  preflightContract: typeof preflightContract;
  recordings: typeof recordings;
  revenuecat: typeof revenuecat;
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
