const assert = require("node:assert");
const {validateBundle} = require("./bundles");

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

if (failed > 0) {
  console.log(`\n${failed} bundle validation test(s) failed.`);
  process.exit(1);
}
console.log("All bundle validation tests passed.\n");