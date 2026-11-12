// Pure retry rules for Gemini calls (suggestJobDetails in index.js). Gemini
// often answers 503 (overloaded) or 429 (rate limited) for a moment, so those
// are retried with a short wait. Needs no Gemini or Firebase, so `npm test`
// covers it.

/**
 * What:   Delays before each retry of a busy Gemini call.
 * Output: [1000, 2000] ms; at most 3 attempts and about 3 s of waiting in total.
 */
const DEFAULT_DELAYS_MS = [1000, 2000];

/**
 * What:   HTTP statuses that are worth retrying.
 * Output: 503 (overloaded) and 429 (rate limited).
 */
const RETRYABLE_STATUSES = [503, 429];

/**
 * What:   Numeric status of an error from the Gemini SDK.
 * Input:  [err], any thrown value.
 * Output: `err.status`, else `err.code`, when numeric; otherwise null.
 */
function errorStatus(err) {
  if (typeof err?.status === "number") return err.status;
  if (typeof err?.code === "number") return err.code;
  return null;
}

/**
 * What:   Check for a busy (retryable) reply.
 * Input:  [err], any thrown value.
 * Output: True for status 503 or 429, false for anything else.
 */
function isBusyError(err) {
  return RETRYABLE_STATUSES.includes(errorStatus(err));
}

/**
 * What:   Real wait used outside tests.
 * Input:  [ms] to wait.
 * Output: A promise that resolves after [ms].
 */
function realSleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * What:   Runs [fn], retrying only when it fails with a busy status.
 * Input:  [fn] async function to call; options `delaysMs` (wait before each
 *         retry, default [1000, 2000]), `sleep(ms)` (injectable for tests) and
 *         `onRetry({status, attempt})` called before each wait, where
 *         `attempt` is the number of the attempt that just failed (1-based).
 * Output: The result of [fn]. Throws the last error once the retries run out,
 *         or at once for an error that is not busy (including no status).
 */
async function withBusyRetry(fn, {
  delaysMs = DEFAULT_DELAYS_MS,
  sleep = realSleep,
  onRetry,
} = {}) {
  for (let attempt = 1; ; attempt++) {
    try {
      return await fn();
    } catch (err) {
      const retriesUsed = attempt - 1;
      if (!isBusyError(err) || retriesUsed >= delaysMs.length) throw err;
      if (onRetry) onRetry({status: errorStatus(err), attempt});
      await sleep(delaysMs[retriesUsed]);
    }
  }
}

module.exports = {
  DEFAULT_DELAYS_MS,
  RETRYABLE_STATUSES,
  errorStatus,
  isBusyError,
  withBusyRetry,
};
