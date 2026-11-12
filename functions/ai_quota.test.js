const assert = require("node:assert");
const test = require("node:test");
const {
  DAILY_AI_LIMIT, takeOne, giveOneBack, reserveAiCall, refundAiCall,
} = require("./ai_quota");

// 11:00 on 26 Oct and 00:30 on 27 Oct, Malaysia time (UTC+8).
const DAY1 = new Date("2026-10-26T03:00:00Z");
const DAY2 = new Date("2026-10-26T16:30:00Z");

/**
 * What:   In-memory stand-in for Firestore, enough for one-document
 *         transactions.
 * Input:  Optional starting documents, keyed by path.
 * Output: {docs, doc, runTransaction}.
 */
function fakeDb(initial = {}) {
  const docs = new Map(Object.entries(initial));
  return {
    docs,
    doc: (path) => ({path}),
    runTransaction: (fn) => fn({
      get: (ref) => Promise.resolve({data: () => docs.get(ref.path)}),
      set: (ref, value) => docs.set(ref.path, value),
    }),
  };
}

test("takeOne: the first call of the day is allowed", () => {
  assert.deepStrictEqual(takeOne(undefined, "2026-10-26"),
      {allowed: true, next: {day: "2026-10-26", count: 1}});
});

test("takeOne: a call over the daily limit is refused", () => {
  const used = {day: "2026-10-26", count: DAILY_AI_LIMIT};
  assert.deepStrictEqual(takeOne(used, "2026-10-26"),
      {allowed: false, next: null});
});

test("takeOne: a new day starts again from zero", () => {
  const yesterday = {day: "2026-10-25", count: DAILY_AI_LIMIT};
  assert.deepStrictEqual(takeOne(yesterday, "2026-10-26"),
      {allowed: true, next: {day: "2026-10-26", count: 1}});
});

test("giveOneBack: returns a call today, nothing for another day", () => {
  assert.deepStrictEqual(giveOneBack({day: "2026-10-26", count: 3},
      "2026-10-26"), {day: "2026-10-26", count: 2});
  assert.strictEqual(giveOneBack({day: "2026-10-25", count: 3},
      "2026-10-26"), null);
  assert.strictEqual(giveOneBack({day: "2026-10-26", count: 0},
      "2026-10-26"), null);
  assert.strictEqual(giveOneBack(undefined, "2026-10-26"), null);
});

test("reserveAiCall: allows the daily limit, then refuses until midnight",
    async () => {
      const db = fakeDb();
      for (let i = 0; i < DAILY_AI_LIMIT; i++) {
        assert.strictEqual(await reserveAiCall(db, "u1", DAY1), true);
      }
      assert.strictEqual(await reserveAiCall(db, "u1", DAY1), false);
      // Other users have their own allowance.
      assert.strictEqual(await reserveAiCall(db, "u2", DAY1), true);
      // After midnight in Malaysia the allowance starts again.
      assert.strictEqual(await reserveAiCall(db, "u1", DAY2), true);
      assert.deepStrictEqual(db.docs.get("aiUsage/u1"),
          {day: "2026-10-27", count: 1});
    });

test("refundAiCall: a call the model never answered is given back",
    async () => {
      const db = fakeDb({"aiUsage/u1": {day: "2026-10-26",
        count: DAILY_AI_LIMIT}});
      assert.strictEqual(await reserveAiCall(db, "u1", DAY1), false);
      await refundAiCall(db, "u1", DAY1);
      assert.strictEqual(await reserveAiCall(db, "u1", DAY1), true);
      assert.strictEqual(await reserveAiCall(db, "u1", DAY1), false);
    });
