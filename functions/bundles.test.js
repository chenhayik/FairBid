const assert = require("node:assert");
const {
  validateBundle,
  validateBundleBid,
  checkLots,
  bundleBiddingOpen,
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
      task({title: "Waterproof floor", category: "Home Repair", lotId: "wet"}),
      task({
        title: "Tile floor", category: "Home Repair", lotId: "wet",
        startsAfterIndex: 0, gapDays: 2,
      }),
      task({budgetMinSen: 10000, budgetMaxSen: 25000}),
    ],
  }));
  assert.deepStrictEqual(result.tasks.map((t) => t.title),
      ["Waterproof floor", "Tile floor", "Replace ceiling light"]);
  assert.strictEqual(result.tasks[1].startsAfterIndex, 0);
  assert.strictEqual(result.tasks[1].gapDays, 2);
  assert.strictEqual(result.tasks[1].lotId, "wet");
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

test("a task may only follow a task listed before it (no cycles)", () => {
  const follows = (index) => payload({
    tasks: [task(), task({startsAfterIndex: index}), task()],
  });
  rejects(() => validateBundle(follows(1))); // itself
  rejects(() => validateBundle(follows(2))); // a later task
  rejects(() => validateBundle(follows(-1)));
  rejects(() => validateBundle(follows(0.5)));
  validateBundle(follows(0)); // an earlier task is fine
});

test("gapDays is refused without a dependency to wait after", () => {
  rejects(() => validateBundle(payload({
    tasks: [task({gapDays: 3}), task()],
  })));
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

// ---------------------------------------------------------------------------
// Phase 2: the package bid a provider places on a bundle. The callable needs
// Firestore and an auth context, but everything it decides before writing
// lives in these pure functions - above all the price checks, because
// firestore.rules cannot walk the taskPrices map and the phase-3 award engine
// spends real money against those numbers.
// ---------------------------------------------------------------------------

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

/** The shape checkLots reads off a task document snapshot. */
function fakeTask(id, lotId) {
  return {id, data: () => (lotId == null ? {} : {lotId})};
}

test("accepts a valid bid and adds the task prices up", () => {
  const result = validateBundleBid(bidPayload());
  assert.deepStrictEqual(result.taskPrices, {task1: 15000, task2: 9000});
  assert.strictEqual(result.taskTotalSen, 24000);
  assert.strictEqual(result.bundlePriceSen, null);
  assert.strictEqual(result.allOrNothing, false);
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

test("a bundle price must be lower than the task prices added up", () => {
  rejects(() => validateBundleBid(bidPayload({bundlePriceSen: 24000})));
  rejects(() => validateBundleBid(bidPayload({bundlePriceSen: 30000})));
  rejects(() => validateBundleBid(bidPayload({bundlePriceSen: 0})));
  const result = validateBundleBid(bidPayload({bundlePriceSen: 21000}));
  assert.strictEqual(result.bundlePriceSen, 21000);
});

test("the duration and the message are required", () => {
  rejects(() => validateBundleBid(bidPayload({estimatedDuration: ""})));
  rejects(() => validateBundleBid(bidPayload({message: "   "})));
  rejects(() => validateBundleBid(undefined));
});

test("a lot is bid on whole or not at all", () => {
  // Tasks 1 and 2 share the 'wet' lot (waterproof, then tile); task 3 is
  // independent.
  const tasks = [
    fakeTask("task1", "wet"),
    fakeTask("task2", "wet"),
    fakeTask("task3", null),
  ];
  checkLots(tasks, ["task1", "task2"]);
  checkLots(tasks, ["task3"]);
  checkLots(tasks, ["task1", "task2", "task3"]);
  assert.throws(() => checkLots(tasks, ["task1"]),
      (err) => err.code === "invalid-argument");
  assert.throws(() => checkLots(tasks, ["task2", "task3"]),
      (err) => err.code === "invalid-argument");
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

if (failed > 0) {
  console.log(`\n${failed} bundle validation test(s) failed.`);
  process.exit(1);
}
console.log("All bundle validation tests passed.\n");