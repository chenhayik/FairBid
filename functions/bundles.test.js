const assert = require("node:assert");
const test = require("node:test");
const {
  validateBundle,
  validateBundleBid,
  bundleBiddingOpen,
  splitBundlePrice,
} = require("./bundles");

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

const INVALID = {code: "invalid-argument"};

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
  assert.throws(() => validateBundle(payload({tasks: [task()]})), INVALID);
  assert.throws(() => validateBundle(payload({tasks: Array(7).fill(task())})), INVALID);
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
  assert.throws(() => validateBundle(tagged([1])), INVALID); // no second photo
  assert.throws(() => validateBundle(tagged([-1])), INVALID);
  assert.throws(() => validateBundle(tagged([0, 0])), INVALID);
  assert.throws(() => validateBundle(tagged("0")), INVALID);
  validateBundle(tagged([0]));
});

test("a category outside kServiceCategories is refused", () => {
  assert.throws(() => validateBundle(payload({
    tasks: [task({category: "Roofing"}), task()],
  })), INVALID);
});

test("a budget range that is back to front is refused", () => {
  assert.throws(() => validateBundle(payload({
    tasks: [task({budgetMinSen: 50000, budgetMaxSen: 10000}), task()],
  })), INVALID);
});

test("a past deadline is refused; a future one becomes a Timestamp", () => {
  assert.throws(() => validateBundle(payload({deadlineMillis: Date.now() - 1000})), INVALID);
  const inAWeek = Date.now() + 7 * 24 * 60 * 60 * 1000;
  const result = validateBundle(payload({deadlineMillis: inAWeek}));
  assert.strictEqual(result.deadline.toMillis(), inAWeek);
});

test("blank text and a missing map pin are refused", () => {
  assert.throws(() => validateBundle(payload({title: "   "})), INVALID);
  assert.throws(() => validateBundle(payload({location: {address: "Penang"}})), INVALID);
  assert.throws(() => validateBundle(payload({
    tasks: [task({description: ""}), task()],
  })), INVALID);
  assert.throws(() => validateBundle(undefined), INVALID);
});

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
  assert.throws(() => validateBundleBid(bidPayload({taskPrices: {}})), INVALID);
  assert.throws(() => validateBundleBid(bidPayload({taskPrices: []})), INVALID);
  const seven = {};
  for (let i = 0; i < 7; i++) seven[`task${i}`] = 1000;
  assert.throws(() => validateBundleBid(bidPayload({taskPrices: seven})), INVALID);
});

test("every task price must be a whole number of sen above zero", () => {
  assert.throws(() => validateBundleBid(bidPayload({taskPrices: {task1: 0}})), INVALID);
  assert.throws(() => validateBundleBid(bidPayload({taskPrices: {task1: -500}})), INVALID);
  assert.throws(() => validateBundleBid(bidPayload({taskPrices: {task1: 12.5}})), INVALID);
  assert.throws(() => validateBundleBid(bidPayload({taskPrices: {task1: "15000"}})), INVALID);
  assert.throws(() => validateBundleBid(
      bidPayload({taskPrices: {task1: 100000001}})), INVALID);
});

test("a bid can't pass the RM 50,000 wallet cap", () => {
  assert.throws(() => validateBundleBid(bidPayload({taskPrices: {task1: 5000001}})), INVALID);
  // Two tasks under the cap alone, over it together.
  assert.throws(() => validateBundleBid(
      bidPayload({taskPrices: {task1: 3000000, task2: 3000000}})), INVALID);
  // A bundle price brings the same pair back under it.
  validateBundleBid(bidPayload({
    taskPrices: {task1: 3000000, task2: 3000000},
    bundlePriceSen: 5000000,
  }));
});

test("a bundle price must be lower than the task prices added up", () => {
  assert.throws(() => validateBundleBid(bidPayload({bundlePriceSen: 24000})), INVALID);
  assert.throws(() => validateBundleBid(bidPayload({bundlePriceSen: 30000})), INVALID);
  assert.throws(() => validateBundleBid(bidPayload({bundlePriceSen: 0})), INVALID);
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
  // and could never be funded.
  assert.throws(() => validateBundleBid(bidPayload({
    taskPrices: {task1: 1, task2: 1000000},
    bundlePriceSen: 500000,
  })), INVALID);
});

test("splitBundlePrice sums exactly and gives every task at least 1 sen",
    () => {
  const amounts = splitBundlePrice({task1: 15000, task2: 9000}, 20000);
  assert.strictEqual(amounts.task1 + amounts.task2, 20000);
  assert.ok(Object.values(amounts).every((sen) => sen >= 1));
  // The last task absorbs the rounding.
  assert.deepStrictEqual(
      splitBundlePrice({waterproof: 22000, tiling: 30000}, 50000),
      {waterproof: 21153, tiling: 28847});
  const thirds = splitBundlePrice({a: 1, b: 1, c: 1}, 100);
  assert.strictEqual(thirds.a + thirds.b + thirds.c, 100);
  assert.ok(Object.values(thirds).every((sen) => sen >= 1));
});

test("the duration and the message are required", () => {
  assert.throws(() => validateBundleBid(bidPayload({estimatedDuration: ""})), INVALID);
  assert.throws(() => validateBundleBid(bidPayload({message: "   "})), INVALID);
  assert.throws(() => validateBundleBid(undefined), INVALID);
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
