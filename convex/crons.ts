import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();
crons.interval("recover deletion automation", { minutes: 1 }, internal.deletionAutomation.recover, {});
crons.interval("recover deletion notifications", { minutes: 1 }, internal.deletionNotifications.recover, {});
crons.interval("recover deletion preflight", { minutes: 1 }, internal.deletionPreflight.recover, {});
crons.daily("purge deletion preflight identifiers", { hourUTC: 3, minuteUTC: 17 }, internal.deletionPreflight.purgeExpired, {});
crons.daily("purge completed deletion ledgers", { hourUTC: 3, minuteUTC: 29 }, internal.deletionRetention.purgeExpired, {});
export default crons;
