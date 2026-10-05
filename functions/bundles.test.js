const assert = require("node:assert");
const {
  validateBundle,
  validateBundleBid,
  bundleBiddingOpen,
  splitBundlePrice,
  uidsToCount,
} = require("./bundles");

let failed = 0;
function test(name, fn) {
  try {
    fn();
    console.log(`  ok  ${name}`);
  } catch (err) {
    failed++;
    console.log(`  FAIL  ${name}\n        ${err.message}`);
  }
}

/** A task that passes validation; each test breaks one thing on purpose. */
function task(overrides = {}) {
  return {
    title: "Replace ceiling light",
    description: "One light in the bathroom.",
    category: "Electrical",
    ...overrides,
  };
}

/** A valid bundle payload. */
function payload(overrides = {}) {
  return {
    title: "Bathroom refresh",
    description: "Small bathroom, about 4 square metres.",
    location: {lat: 5.41, lng: 100.33, address: "George Town, Penang"},
    tasks: [task(), task({category: "Plumbing"})],
    ...overrides,
  };
}

/** Asserts [fn] throws the callable's `invalid-argument` error. */
function rejects(fn) {
  assert.throws(fn, (err) => err.code === "invalid-argument");
}

console.log("bundles.js validateBundle");

test("accepts a valid bundle and keeps its task order", () => {
  const result = validateBundle(payload({
    tasks: [
      task({title: "Waterproof floor", category: "Home Repair"}),
      task({title: "Tile floor", category: "Home Repair"}),
      task({budgetMinSen: 10000, budgetMaxSen: 25000}),
    ],
  }));
  assert.deepStrictEqual(result.tasks.map((t) => t.title),
      ["Waterproof floor", "Tile floor", "Replace ceiling light"]);
  assert.deepStrictEqual(result.tasks[2].budget,
      {minSen: 10000, maxSen: 25000, hourly: false});
  assert.strictEqual(result.tasks[0].budget, null);
  assert.deepStrictEqual(result.photoUrls, []);
  assert.strictEqual(result.deadline, null);
});

test("a bundle needs between 2 and 6 tasks", () => {
  rejects(() => validateBundle(payload({tasks: [task()]})));
  rejects(() => validateBundle(payload({tasks: Array(7).fill(task())})));
  validateBundle(payload({tasks: Array(6).fill(task())})); // 6 is fine
});

test("each task gets its tagged photos plus the untagged ones", () => {
  const result = validateBundle(payload({
    photoUrls: ["a.jpg", "b.jpg", "c.jpg"],
    tasks: [task({photoIndexes: [0]}), task({photoIndexes: [1]})],
  }));
  assert.deepStrictEqual(result.photoUrls, ["a.jpg", "b.jpg", "c.jpg"]);
  assert.deepStrictEqual(result.tasks[0].photoUrls, ["a.jpg", "c.jpg"]);
  assert.deepStrictEqual(result.tasks[1].photoUrls, ["b.jpg", "c.jpg"]);
});

test("with no tags every task gets every photo", () => {
  const result = validateBundle(payload({photoUrls: ["a.jpg", "b.jpg"]}));
  assert.deepStrictEqual(result.tasks[0].photoUrls, ["a.jpg", "b.jpg"]);
  assert.deepStrictEqual(result.tasks[1].photoUrls, ["a.jpg", "b.jpg"]);
});

test("photo tags must point at real, distinct photos", () => {
  const tagged = (photoIndexes) => payload({
    photoUrls: ["a.jpg"],
    tasks: [task({photoIndexes}), task()],
  });
  rejects(() => validateBundle(tagged([1]))); // no second photo
  rejects(() => validateBundle(tagged([-1])));
  rejects(() => validateBundle(tagged([0, 0])));
  rejects(() => validateBundle(tagged("0")));
  validateBundle(tagged([0]));
});

test("a category outside kServiceCategories is refused", () => {
  rejects(() => validateBundle(payload({
    tasks: [task({category: "Roofing"}), task()],
  })));
});

test("a budget range that is back to front is refused", () => {
  rejects(() => validateBundle(payload({
    tasks: [task({budgetMinSen: 50000, budgetMaxSen: 10000}), task()],
  })));
});

test("a past deadline is refused; a future one becomes a Timestamp", () => {
  rejects(() => validateBundle(payload({deadlineMillis: Date.now() - 1000})));
  const inAWeek = Date.now() + 7 * 24 * 60 * 60 * 1000;
  const result = validateBundle(payload({deadlineMillis: inAWeek}));
  assert.strictEqual(result.deadline.toMillis(), inAWeek);
});

test("blank text and a missing map pin are refused", () => {
  rejects(() => validateBundle(payload({title: "   "})));
  rejects(() => validateBundle(payload({location: {address: "Penang"}})));
  rejects(() => validateBundle(payload({
    tasks: [task({description: ""}), task()],
  })));
  rejects(() => validateBundle(undefined));
});

console.log("bundles.js validateBundleBid");

/** A valid bundle-bid payload: two tasks, no bundle price. */
function bidPayload(overrides = {}) {
  return {
    taskPrices: {task1: 15000, task2: 9000},
    estimatedDuration: "1 week",
    message: "I can do both of these in one visit.",
    ...overrides,
  };
}

test("accepts a valid bid and adds the task prices up", () => {
  const result = validateBundleBid(bidPayload());
  assert.deepStrictEqual(result.taskPrices, {task1: 15000, task2: 9000});
  assert.strictEqual(result.taskTotalSen, 24000);
  assert.strictEqual(result.bundlePriceSen, null);
  assert.strictEqual(result.estimatedDuration, "1 week");
});

test("a bid must cover between 1 and 6 tasks", () => {
  rejects(() => validateBundleBid(bidPayload({taskPrices: {}})));
  rejects(() => validateBundleBid(bidPayload({taskPrices: []})));
  const seven = {};
  for (let i = 0; i < 7; i++) seven[`task${i}`] = 1000;
  rejects(() => validateBundleBid(bidPayload({taskPrices: seven})));
});

test("every task price must be a whole number of sen above zero", () => {
  rejects(() => validateBundleBid(bidPayload({taskPrices: {task1: 0}})));
  rejects(() => validateBundleBid(bidPayload({taskPrices: {task1: -500}})));
  rejects(() => validateBundleBid(bidPayload({taskPrices: {task1: 12.5}})));
  rejects(() => validateBundleBid(bidPayload({taskPrices: {task1: "15000"}})));
  rejects(() => validateBundleBid(
      bidPayload({taskPrices: {task1: 100000001}})));
});

test("a bid can't pass the RM 50,000 wallet cap", () => {
  rejects(() => validateBundleBid(bidPayload({taskPrices: {task1: 5000001}})));
  // Two tasks under the cap alone, over it together.
  rejects(() => validateBundleBid(
      bidPayload({taskPrices: {task1: 3000000, task2: 3000000}})));
  // A bundle price brings the same pair back under it.
  validateBundleBid(bidPayload({
    taskPrices: {task1: 3000000, task2: 3000000},
    bundlePriceSen: 5000000,
  }));
});

test("a bundle price must be lower than the task prices added up", () => {
  rejects(() => validateBundleBid(bidPayload({bundlePriceSen: 24000})));
  rejects(() => validateBundleBid(bidPayload({bundlePriceSen: 30000})));
  rejects(() => validateBundleBid(bidPayload({bundlePriceSen: 0})));
  const result = validateBundleBid(bidPayload({bundlePriceSen: 21000}));
  assert.strictEqual(result.bundlePriceSen, 21000);
});

test("a normal bundle price is accepted", () => {
  const result = validateBundleBid(bidPayload({bundlePriceSen: 20000}));
  assert.strictEqual(result.bundlePriceSen, 20000);
});

test("a bundle price too low to share across every task is refused", () => {
  // Splitting RM 5,000 in proportion to a RM 0.01 task and a RM 10,000 task
  // rounds the small task's share down to 0 - it would be awarded at RM 0
  // and could never get a milestone plan.
  rejects(() => validateBundleBid(bidPayload({
    taskPrices: {task1: 1, task2: 1000000},
    bundlePriceSen: 500000,
  })));
});

test("splitBundlePrice sums exactly and gives every task at least 1 sen",
    () => {
  const amounts = splitBundlePrice({task1: 15000, task2: 9000}, 20000);
  assert.strictEqual(amounts.task1 + amounts.task2, 20000);
  assert.ok(Object.values(amounts).every((sen) => sen >= 1));
  const thirds = splitBundlePrice({a: 1, b: 1, c: 1}, 100);
  assert.strictEqual(thirds.a + thirds.b + thirds.c, 100);
  assert.ok(Object.values(thirds).every((sen) => sen >= 1));
});

test("the duration and the message are required", () => {
  rejects(() => validateBundleBid(bidPayload({estimatedDuration: ""})));
  rejects(() => validateBundleBid(bidPayload({message: "   "})));
  rejects(() => validateBundleBid(undefined));
});

test("a bundle stops taking bids when it closes or its deadline passes", () => {
  const inAnHour = {toMillis: () => Date.now() + 3600000};
  const anHourAgo = {toMillis: () => Date.now() - 3600000};
  assert.strictEqual(bundleBiddingOpen({status: "open"}), true);
  assert.strictEqual(
      bundleBiddingOpen({status: "open", deadline: inAnHour}), true);
  assert.strictEqual(
      bundleBiddingOpen({status: "open", deadline: anHourAgo}), false);
  assert.strictEqual(bundleBiddingOpen({status: "awarded"}), false);
  assert.strictEqual(
      bundleBiddingOpen({status: "cancelled", deadline: inAnHour}), false);
});

// ---------------------------------------------------------------------------
// Phase 5: which participants a completed bundle task still owes a
// `jobsCompleted` bump - a bundle counts once per participant, not per task.
// ---------------------------------------------------------------------------

console.log("bundles.js uidsToCount");

test("with nobody already counted, every participant is due the bump", () => {
  assert.deepStrictEqual(
      uidsToCount(["provider1", "requestor1"], []),
      ["provider1", "requestor1"]);
});

test("a uid already counted for this bundle is skipped", () => {
  assert.deepStrictEqual(
      uidsToCount(["provider1", "requestor1"], ["provider1"]),
      ["requestor1"]);
});

test("once both are counted, nobody is due a further bump", () => {
  assert.deepStrictEqual(
      uidsToCount(["provider1", "requestor1"], ["provider1", "requestor1"]),
      []);
});

if (failed > 0) {
  console.log(`\n${failed} bundle validation test(s) failed.`);
  process.exit(1);
}
console.log("All bundle validation tests passed.\n");