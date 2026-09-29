const assert = require("node:assert");
const {
  validateBundle,
  validateBundleBid,
  checkLots,
  bundleBiddingOpen,
  splitBundlePrice,
  startsWhenText,
  handoverNotificationBody,
  validateHandover,
  uidsToCount,
  isHandoverDispute,
} = require("./bundles");
const {IMG_PREFIX} = require("./common");

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

// ---------------------------------------------------------------------------
// Phase 4: the dependent-task handover notification text and the
// recordHandover input checks.
// ---------------------------------------------------------------------------

console.log("bundles.js handover");

test("startsWhenText says 'now' with no gap, else 'after N day(s)'", () => {
  assert.strictEqual(startsWhenText(0), "now");
  assert.strictEqual(startsWhenText(null), "now");
  assert.strictEqual(startsWhenText(1), "after 1 day");
  assert.strictEqual(startsWhenText(3), "after 3 days");
});

test("the dependent-task notification names both tasks and the wait", () => {
  const body = handoverNotificationBody("Plumbing rough-in", "Tiling", 2);
  assert.strictEqual(body,
      "\"Plumbing rough-in\" is done. \"Tiling\" can start after 2 days. " +
      "Record a site handover before you begin.");
  assert.ok(handoverNotificationBody("A", "B", 0).includes("can start now."));
});

/** A valid recordHandover payload. */
function handoverPayload(overrides = {}) {
  return {
    note: "Left the key with the neighbour, photos attached.",
    photoUrls: [`${IMG_PREFIX}jobs%2Fabc%2Fphoto.jpg?alt=media`],
    ...overrides,
  };
}

test("a valid handover note and photos are accepted", () => {
  const result = validateHandover(handoverPayload());
  assert.strictEqual(result.note,
      "Left the key with the neighbour, photos attached.");
  assert.strictEqual(result.photoUrls.length, 1);
});

test("a handover needs a non-empty note, at most 1000 characters", () => {
  rejects(() => validateHandover(handoverPayload({note: ""})));
  rejects(() => validateHandover(handoverPayload({note: "   "})));
  rejects(() => validateHandover(handoverPayload({note: "x".repeat(1001)})));
  validateHandover(handoverPayload({note: "x".repeat(1000)})); // exactly fine
});

test("photos are optional, capped at 5, and must be our own uploads", () => {
  validateHandover(handoverPayload({photoUrls: undefined}));
  rejects(() => validateHandover(
      handoverPayload({photoUrls: Array(6).fill(`${IMG_PREFIX}x.jpg`)})));
  rejects(() => validateHandover(
      handoverPayload({photoUrls: ["https://evil.example/x.jpg"]})));
  rejects(() => validateHandover(handoverPayload({photoUrls: [""]})));
  rejects(() => validateHandover(handoverPayload({photoUrls: "not-a-list"})));
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

// ---------------------------------------------------------------------------
// Phase 6: flagging a dispute as a split handover, for the deliverable
// metric in docs/BUNDLE_BIDDING.md.
// ---------------------------------------------------------------------------

console.log("bundles.js isHandoverDispute");

test("not a handover dispute when the job has no predecessor", () => {
  assert.strictEqual(
      isHandoverDispute({startsAfterJobId: null}, null), false);
  assert.strictEqual(
      isHandoverDispute({startsAfterJobId: null}, {acceptedProviderId: "p1"}),
      false);
});

test("not flagged when the predecessor is missing", () => {
  assert.strictEqual(
      isHandoverDispute({startsAfterJobId: "task1"}, null), false);
});

test("flagged when the predecessor went to a different provider", () => {
  assert.strictEqual(isHandoverDispute(
      {startsAfterJobId: "task1", acceptedProviderId: "p2"},
      {acceptedProviderId: "p1"}), true);
});

test("not flagged when the same provider won both tasks", () => {
  assert.strictEqual(isHandoverDispute(
      {startsAfterJobId: "task1", acceptedProviderId: "p1"},
      {acceptedProviderId: "p1"}), false);
});

if (failed > 0) {
  console.log(`\n${failed} bundle validation test(s) failed.`);
  process.exit(1);
}
console.log("All bundle validation tests passed.\n");