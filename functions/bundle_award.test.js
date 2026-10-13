// Unit tests for the award engine in bundle_award.js, on a four-task bathroom
// bundle whose numbers were pinned from the original prototype.

const assert = require("node:assert");
const test = require("node:test");
const {
  offersFor,
  buildAwardOptions,
  checkManualAward,
  allowanceSen,
  manualOption,
  leftoverTaskUpdate,
} = require("./bundle_award");

// A four-task bathroom bundle.
const TASKS = [
  {id: "plumbing", title: "Plumbing rough-in"},
  {id: "electrical", title: "Electrical points"},
  {id: "waterproof", title: "Waterproofing"},
  {id: "tiling", title: "Tiling"},
];

const TASK_INDEX = {plumbing: 0, electrical: 1, waterproof: 2, tiling: 3};

// A generalist who prices everything with a discount, two single-trade
// specialists, and a tiler with a wet-works package deal. Dev's bid is no
// longer all-or-nothing, but the totals hold: the RM 500 package still beats
// his two single prices (RM 520).
const BIDS = [
  {
    providerId: "aida", providerName: "Aida Renovation", trustScore: 820,
    taskPrices: {plumbing: 18500, electrical: 19000, waterproof: 25000,
      tiling: 33000},
    bundlePriceSen: 90000,
  },
  {
    providerId: "budi", providerName: "Budi Plumbing", trustScore: 760,
    taskPrices: {plumbing: 18000}, bundlePriceSen: null,
  },
  {
    providerId: "chandran", providerName: "Chandran Electrical",
    trustScore: 900, taskPrices: {electrical: 16000},
    bundlePriceSen: null,
  },
  {
    providerId: "dev", providerName: "Dev Tiling Works", trustScore: 700,
    taskPrices: {waterproof: 22000, tiling: 30000},
    bundlePriceSen: 50000,
  },
];

const CAP = {capPct: 5, capSen: 50000}; // 5% AND RM 500, as PlatformConfig has

/** The option with this key, from a built set of three. */
function pick(options, key) {
  return options.find((o) => o.key === key);
}

test("a bid offers every subset it would accept", () => {
  // Two tasks: each on its own, plus both together.
  const offers = offersFor(BIDS[3], TASK_INDEX);
  assert.strictEqual(offers.length, 3);
  const pair = offers.find((o) => o.taskMask === 0b1100);
  assert.strictEqual(pair.priceSen, 50000); // priced at the bundle price

  const generalist = offersFor(BIDS[0], TASK_INDEX);
  // Every non-empty subset of four tasks.
  assert.strictEqual(generalist.length, 15);
  const whole = generalist.find((o) => o.taskMask === 0b1111);
  assert.strictEqual(whole.priceSen, 90000);
});

test("the three options on the bathroom bundle", () => {
  const options = buildAwardOptions({tasks: TASKS, bids: BIDS, ...CAP});
  assert.strictEqual(options.length, 3);

  // Cheapest: the two specialists plus the tiler's wet-works package.
  const cheapest = pick(options, "cheapest");
  assert.strictEqual(cheapest.totalSen, 84000);
  assert.strictEqual(cheapest.providerCount, 3);
  assert.strictEqual(cheapest.premiumSen, 0);
  assert.strictEqual(cheapest.weightedTrust, 750);
  assert.deepStrictEqual(cheapest.uncoveredTaskIds, []);

  // Fewest providers: the generalist takes all four at their bundle price.
  const fewest = pick(options, "fewest");
  assert.strictEqual(fewest.totalSen, 90000);
  assert.strictEqual(fewest.providerCount, 1);
  assert.strictEqual(fewest.premiumSen, 6000);
  assert.strictEqual(fewest.weightedTrust, 820);

  // Recommended: two providers at RM 35 over the cheapest, inside the
  // RM 42 allowance (5% of RM 840).
  const recommended = pick(options, "recommended");
  assert.strictEqual(recommended.totalSen, 87500);
  assert.strictEqual(recommended.providerCount, 2);
  assert.strictEqual(recommended.premiumSen, 3500);
});

test("trust is shown only when every hired provider has a visible score", () => {
  const visible = BIDS.map((b) => ({...b, scoreVisible: true}));
  const shown = buildAwardOptions({tasks: TASKS, bids: visible, ...CAP});
  assert.ok(shown.every((o) => o.trustVisible));

  // Dev is new: options hiring him hide trust, the rest still show it.
  const devNew = visible.map((b) =>
    b.providerId === "dev" ? {...b, scoreVisible: false} : b);
  const options = buildAwardOptions({tasks: TASKS, bids: devNew, ...CAP});
  assert.strictEqual(pick(options, "cheapest").trustVisible, false);
  assert.strictEqual(pick(options, "fewest").trustVisible, true);
});

test("coverage comes before price", () => {
  // Only the plumber and the tiler bid, so nobody can do the electrics.
  const thin = BIDS.filter((b) => b.providerId !== "aida" &&
      b.providerId !== "chandran");
  const options = buildAwardOptions({tasks: TASKS, bids: thin, ...CAP});
  const cheapest = pick(options, "cheapest");
  assert.deepStrictEqual(cheapest.uncoveredTaskIds, ["electrical"]);
  assert.strictEqual(cheapest.totalSen, 68000); // 18000 + the 50000 package
});

test("no bids at all means no options", () => {
  assert.deepStrictEqual(
      buildAwardOptions({tasks: TASKS, bids: [], ...CAP}), []);
});

test("the cap is the smaller of the percentage and the ringgit ceiling", () => {
  assert.strictEqual(allowanceSen(84000, 5, 50000), 4200); // 5% is smaller
  assert.strictEqual(allowanceSen(8400000, 5, 50000), 50000); // ceiling wins
});

test("a hand-picked award may not break a bid's terms", () => {
  const refuse = (providerByTaskId) => checkManualAward(
      {tasks: TASKS, bids: BIDS, providerByTaskId}).problems;

  // Part of a bid is fine now: dev's tiling alone is priced at 30000.
  const partial = checkManualAward({
    tasks: TASKS, bids: BIDS, providerByTaskId: {tiling: "dev"},
  });
  assert.deepStrictEqual(partial.problems, []);
  assert.deepStrictEqual(partial.awards[0].taskAmountsSen, {tiling: 30000});
  // A task that provider never priced.
  assert.ok(refuse({plumbing: "chandran"})[0].includes("never priced"));
  // A provider who never bid at all.
  assert.ok(refuse({plumbing: "nobody"})[0].includes("No bid from provider"));
});

test("checkManualAward returns a problem, not a TypeError, for a " +
    "prototype-shaped provider id", () => {
  // A plain-object lookup table would resolve "constructor" through
  // Object.prototype instead of missing outright, turning the clean "No bid
  // from provider" problem into a crash deeper inside (`id in undefined`).
  const tasks = [{id: "A", title: "Task A"}];
  const {awards, problems} = checkManualAward({
    tasks, bids: [], providerByTaskId: {A: "constructor"},
  });
  assert.deepStrictEqual(awards, []);
  assert.ok(problems[0].includes("No bid from provider"));
});

test("offersFor / buildAwardOptions drop a bid pricing a task the bundle " +
    "no longer has", () => {
  const tasks = [
    {id: "A", title: "Task A"},
    {id: "C", title: "Task C"},
  ];
  const taskIndex = {A: 0, C: 1};
  const bids = [
    {providerId: "x", providerName: "X", trustScore: 50,
      taskPrices: {B: 50}, bundlePriceSen: null},
    {providerId: "y", providerName: "Y", trustScore: 50,
      taskPrices: {A: 100}, bundlePriceSen: null},
  ];
  // x priced task "B", which this bundle doesn't have (say, it stopped
  // being open) - it must offer nothing at all, not silently cover task A
  // the way `1 << taskIndex["B"]` (== `1 << undefined` == 1) would.
  assert.deepStrictEqual(offersFor(bids[0], taskIndex), []);

  const options = buildAwardOptions({tasks, bids, capPct: 5, capSen: 50000});
  const cheapest = pick(options, "cheapest");
  assert.strictEqual(cheapest.awards.length, 1);
  assert.strictEqual(cheapest.awards[0].providerId, "y");
  assert.deepStrictEqual(cheapest.awards[0].taskAmountsSen, {A: 100});
  assert.deepStrictEqual(cheapest.uncoveredTaskIds, ["C"]);
});

test("Recommended breaks a tie within the cap by Trust Score, not price",
    () => {
  const tasks = [
    {id: "A", title: "Task A"},
    {id: "B", title: "Task B"},
  ];
  const bids = [
    {providerId: "x", providerName: "X", trustScore: 50,
      taskPrices: {A: 500, B: 500}, bundlePriceSen: null},
    {providerId: "y", providerName: "Y", trustScore: 90,
      taskPrices: {A: 510, B: 510}, bundlePriceSen: null},
  ];
  const options = buildAwardOptions({tasks, bids, capPct: 5, capSen: 50000});
  // Cheapest: x, at RM 10 total. Recommended: RM 10.20, inside the RM 10.50
  // allowance (5% of RM 10) - and y's Trust Score of 90 beats x's 50, so
  // Recommended takes y even though it costs more.
  assert.strictEqual(pick(options, "cheapest").awards[0].providerId, "x");
  assert.strictEqual(pick(options, "recommended").awards[0].providerId, "y");
});

test("when Trust Score ties within the cap, Recommended takes the cheaper",
    () => {
  const tasks = [
    {id: "A", title: "Task A"},
    {id: "B", title: "Task B"},
  ];
  const bids = [
    // Two specialists: the overall cheapest, at RM 8 total.
    {providerId: "s1", providerName: "S1", trustScore: 99,
      taskPrices: {A: 400}, bundlePriceSen: null},
    {providerId: "s2", providerName: "S2", trustScore: 99,
      taskPrices: {B: 400}, bundlePriceSen: null},
    // Two generalists, same Trust Score, one cheaper than the other - both
    // inside a cap wide enough to admit either.
    {providerId: "g1", providerName: "G1", trustScore: 60,
      taskPrices: {A: 500, B: 500}, bundlePriceSen: null},
    {providerId: "g2", providerName: "G2", trustScore: 60,
      taskPrices: {A: 520, B: 520}, bundlePriceSen: null},
  ];
  // Cheapest is the two specialists (RM 8); a 30% cap admits either
  // generalist (RM 10 and RM 10.40), so Recommended prefers 1 provider over
  // 2 - and between the two tied-trust generalists, the cheaper one.
  const options = buildAwardOptions({tasks, bids, capPct: 30, capSen: 50000});
  assert.strictEqual(pick(options, "cheapest").providerCount, 2);
  const recommended = pick(options, "recommended");
  assert.strictEqual(recommended.providerCount, 1);
  assert.strictEqual(recommended.awards[0].providerId, "g1");
  assert.strictEqual(recommended.totalSen, 1000);
});

test("manualOption prices a valid pick and refuses a bad one", () => {
  // Chandran never priced plumbing: problems, not an option.
  const bad = manualOption({
    tasks: TASKS, bids: BIDS, providerByTaskId: {plumbing: "chandran"},
    cheapestCostSen: 84000,
  });
  assert.strictEqual(bad.manual, null);
  assert.ok(bad.problems[0].includes("never priced"));

  const {manual, problems} = manualOption({
    tasks: TASKS,
    bids: BIDS,
    providerByTaskId: {
      plumbing: "budi", electrical: "chandran", waterproof: "dev",
      tiling: "dev",
    },
    cheapestCostSen: 84000,
  });
  assert.deepStrictEqual(problems, []);
  assert.strictEqual(manual.key, "manual");
  assert.strictEqual(manual.label, "Your pick");
  assert.strictEqual(manual.totalSen, 84000);
  assert.strictEqual(manual.providerCount, 3);
  assert.strictEqual(manual.premiumSen, 0); // matches the cheapest option
  assert.deepStrictEqual(manual.uncoveredTaskIds, []);
});

test("leftoverTaskUpdate releases a task with a fresh deadline", () => {
  const deadline = {marker: "deadline"};
  const update = leftoverTaskUpdate({drop: false, uid: "req", deadline});
  assert.strictEqual(update.deadline, deadline);
  assert.strictEqual(update.bidCount, 0);
  assert.ok(update.releasedAt);
  assert.strictEqual(update.status, undefined);
});

test("leftoverTaskUpdate drops a task by cancelling it", () => {
  const update = leftoverTaskUpdate({drop: true, uid: "req", deadline: null});
  assert.strictEqual(update.status, "cancelled");
  assert.strictEqual(update.cancelledBy, "req");
  assert.ok(update.cancelledAt);
  assert.ok(update.cancellationReason.includes("dropped"));
  assert.strictEqual(update.releasedAt, undefined);
});
