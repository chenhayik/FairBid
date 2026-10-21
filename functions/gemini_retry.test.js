const assert = require("node:assert");
const test = require("node:test");
const {
  errorStatus,
  isBusyError,
  withBusyRetry,
} = require("./gemini_retry");

const httpError = (status) => Object.assign(new Error(`HTTP ${status}`), {status});

/** A fn that fails with the given errors in order, then returns "ok". */
function flaky(errors) {
  const state = {calls: 0};
  state.fn = () => {
    state.calls++;
    if (state.calls <= errors.length) {
      return Promise.reject(errors[state.calls - 1]);
    }
    return Promise.resolve("ok");
  };
  return state;
}

/** Records the sleep delays instead of waiting. */
function fakeSleep() {
  const delays = [];
  const sleep = (ms) => {
    delays.push(ms);
    return Promise.resolve();
  };
  return {delays, sleep};
}

test("errorStatus reads status, then code, else null", () => {
  assert.strictEqual(errorStatus({status: 503}), 503);
  assert.strictEqual(errorStatus({code: 429}), 429);
  assert.strictEqual(errorStatus({status: 503, code: 429}), 503);
  assert.strictEqual(errorStatus({code: "ECONNRESET"}), null);
  assert.strictEqual(errorStatus(new Error("x")), null);
  assert.strictEqual(errorStatus(null), null);
});

test("isBusyError is true only for 503 and 429", () => {
  assert.strictEqual(isBusyError({status: 503}), true);
  assert.strictEqual(isBusyError({code: 429}), true);
  assert.strictEqual(isBusyError({status: 400}), false);
  assert.strictEqual(isBusyError({status: 500}), false);
  assert.strictEqual(isBusyError(new Error("x")), false);
});

test("success on the first try does not sleep or retry", async () => {
  const {delays, sleep} = fakeSleep();
  const f = flaky([]);
  const retries = [];
  const out = await withBusyRetry(f.fn, {sleep, onRetry: (r) => retries.push(r)});
  assert.strictEqual(out, "ok");
  assert.strictEqual(f.calls, 1);
  assert.deepStrictEqual(delays, []);
  assert.deepStrictEqual(retries, []);
});

test("503 then success retries once", async () => {
  const {delays, sleep} = fakeSleep();
  const f = flaky([httpError(503)]);
  const retries = [];
  const out = await withBusyRetry(f.fn, {sleep, onRetry: (r) => retries.push(r)});
  assert.strictEqual(out, "ok");
  assert.strictEqual(f.calls, 2);
  assert.deepStrictEqual(delays, [1000]);
  assert.deepStrictEqual(retries, [{status: 503, attempt: 1}]);
});

test("429 twice then success uses both retries", async () => {
  const {delays, sleep} = fakeSleep();
  const f = flaky([httpError(429), httpError(429)]);
  const retries = [];
  const out = await withBusyRetry(f.fn, {sleep, onRetry: (r) => retries.push(r)});
  assert.strictEqual(out, "ok");
  assert.strictEqual(f.calls, 3);
  assert.deepStrictEqual(delays, [1000, 2000]);
  assert.deepStrictEqual(retries, [
    {status: 429, attempt: 1},
    {status: 429, attempt: 2},
  ]);
});

test("503 three times throws the last error after 2 retries", async () => {
  const {delays, sleep} = fakeSleep();
  const errors = [httpError(503), httpError(503), httpError(503)];
  const f = flaky(errors);
  await assert.rejects(withBusyRetry(f.fn, {sleep}), (err) => err === errors[2]);
  assert.strictEqual(f.calls, 3);
  assert.deepStrictEqual(delays, [1000, 2000]);
});

test("a 400 error is thrown at once with no retry", async () => {
  const {delays, sleep} = fakeSleep();
  const e = httpError(400);
  const f = flaky([e]);
  const retries = [];
  await assert.rejects(
      withBusyRetry(f.fn, {sleep, onRetry: (r) => retries.push(r)}),
      (err) => err === e);
  assert.strictEqual(f.calls, 1);
  assert.deepStrictEqual(delays, []);
  assert.deepStrictEqual(retries, []);
});

test("an error with no status is not retried", async () => {
  const {delays, sleep} = fakeSleep();
  const e = new Error("network down");
  const f = flaky([e]);
  await assert.rejects(withBusyRetry(f.fn, {sleep}), (err) => err === e);
  assert.strictEqual(f.calls, 1);
  assert.deepStrictEqual(delays, []);
});

test("a non-busy error after a busy one stops retrying", async () => {
  const {delays, sleep} = fakeSleep();
  const e = httpError(403);
  const f = flaky([httpError(503), e]);
  await assert.rejects(withBusyRetry(f.fn, {sleep}), (err) => err === e);
  assert.strictEqual(f.calls, 2);
  assert.deepStrictEqual(delays, [1000]);
});
