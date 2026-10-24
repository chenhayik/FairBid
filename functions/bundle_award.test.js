// Unit tests for the award engine in bundle_award.js, on a four-task bathroom
// bundle whose numbers were pinned from the original prototype.

const assert = require("node:assert");
const test = require("node:test");
const {
  offersFor,
  buildAwardOptions,
  checkManualAward,
  bidFromSnap,
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
  const options = buildAwardOptions({tasks: TASKS, bids: BIDS});
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

  // Best Value: swapping Budi (RM 180, Trust 760) for Aida's plumbing (RM
  // 185, Trust 820) costs RM 5 more and scores 0.902 against the cheapest's
  // 0.6 + 0.4 * 0.75 = 0.900. The generalist at RM 900 scores only 0.888.
  const bestValue = pick(options, "bestValue");
  assert.strictEqual(bestValue.totalSen, 84500);
  assert.strictEqual(bestValue.providerCount, 3);
  assert.strictEqual(bestValue.premiumSen, 500);
  assert.strictEqual(bestValue.weightedTrust, 764);
});

test("options come in order with the agreed keys and labels", () => {
  const options = buildAwardOptions({tasks: TASKS, bids: BIDS});
  assert.deepStrictEqual(
      options.map((o) => [o.key, o.label]),
      [
        ["cheapest", "Lowest total"],
        ["fewest", "Fewest providers"],
        ["bestValue", "Best Value"],
      ]);
});

test("trust is shown only when every hired provider has a visible score", () => {
  const visible = BIDS.map((b) => ({...b, scoreVisible: true}));
  const shown = buildAwardOptions({tasks: TASKS, bids: visible});
  assert.ok(shown.every((o) => o.trustVisible));

  // Dev is new: options hiring him hide trust, the rest still show it.
  const devNew = visible.map((b) =>
    b.providerId === "dev" ? {...b, scoreVisible: false} : b);
  const options = buildAwardOptions({tasks: TASKS, bids: devNew});
  assert.strictEqual(pick(options, "cheapest").trustVisible, false);
  assert.strictEqual(pick(options, "fewest").trustVisible, true);
});

test("coverage comes before price", () => {
  // Only the plumber and the tiler bid, so nobody can do the electrics.
  const thin = BIDS.filter((b) => b.providerId !== "aida" &&
      b.providerId !== "chandran");
  const options = buildAwardOptions({tasks: TASKS, bids: thin});
  const cheapest = pick(options, "cheapest");
  assert.deepStrictEqual(cheapest.uncoveredTaskIds, ["electrical"]);
  assert.strictEqual(cheapest.totalSen, 68000); // 18000 + the 50000 package
});

test("no bids at all means no options", () => {
  assert.deepStrictEqual(
      buildAwardOptions({tasks: TASKS, bids: []}), []);
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

  const options = buildAwardOptions({tasks, bids});
  const cheapest = pick(options, "cheapest");
  assert.strictEqual(cheapest.awards.length, 1);
  assert.strictEqual(cheapest.awards[0].providerId, "y");
  assert.deepStrictEqual(cheapest.awards[0].taskAmountsSen, {A: 100});
  assert.deepStrictEqual(cheapest.uncoveredTaskIds, ["C"]);
});

/** Two tasks both priced by two whole-bundle providers. */
const TWO_TASKS = [
  {id: "A", title: "Task A"},
  {id: "B", title: "Task B"},
];

/** A bid covering both of TWO_TASKS for [totalSen], split evenly. */
function wholeBid(providerId, trustScore, totalSen, extra = {}) {
  return {
    providerId, providerName: providerId.toUpperCase(), trustScore,
    scoreVisible: true,
    taskPrices: {A: totalSen / 2, B: totalSen / 2}, bundlePriceSen: null,
    ...extra,
  };
}

test("Best Value can pick a pricier but more trusted combination", () => {
  // RM 1,000 at Trust 700 scores 0.6 + 0.4 * 0.70 = 0.880. RM 1,100 at
  // Trust 850 scores 0.6 * 1000 / 1100 + 0.4 * 0.85 = 0.8854.
  const bids = [wholeBid("x", 700, 100000), wholeBid("y", 850, 110000)];
  const options = buildAwardOptions({tasks: TWO_TASKS, bids});
  assert.strictEqual(pick(options, "cheapest").awards[0].providerId, "x");
  const bestValue = pick(options, "bestValue");
  assert.strictEqual(bestValue.awards[0].providerId, "y");
  assert.strictEqual(bestValue.totalSen, 110000);
  assert.strictEqual(bestValue.premiumSen, 10000);
  assert.strictEqual(bestValue.weightedTrust, 850);
});

test("Best Value stays on the cheapest when the extra Trust is not worth it",
    () => {
  // RM 1,100 at Trust 800 scores 0.5454 + 0.32 = 0.8654, below 0.880.
  const bids = [wholeBid("x", 700, 100000), wholeBid("y", 800, 110000)];
  const options = buildAwardOptions({tasks: TWO_TASKS, bids});
  assert.strictEqual(pick(options, "bestValue").awards[0].providerId, "x");
});

test("Best Value searches every combination, not just the cheapest per " +
    "provider count", () => {
  // Cheapest: s1 + s2 (RM 8, Trust 500) scores 0.6 + 0.2 = 0.80. The
  // whole-bundle g1 (RM 10, Trust 900) scores 0.48 + 0.36 = 0.84, so a
  // one-provider award wins. Mixed awards (s1 on A, g2 on B) score lower.
  const bids = [
    {providerId: "s1", providerName: "S1", trustScore: 500,
      taskPrices: {A: 400}, bundlePriceSen: null},
    {providerId: "s2", providerName: "S2", trustScore: 500,
      taskPrices: {B: 400}, bundlePriceSen: null},
    wholeBid("g1", 900, 1000),
    {providerId: "g2", providerName: "G2", trustScore: 300,
      taskPrices: {B: 500}, bundlePriceSen: null},
  ];
  const options = buildAwardOptions({tasks: TWO_TASKS, bids});
  assert.strictEqual(pick(options, "cheapest").totalSen, 800);
  const bestValue = pick(options, "bestValue");
  assert.strictEqual(bestValue.providerCount, 1);
  assert.strictEqual(bestValue.awards[0].providerId, "g1");
});

test("Best Value only compares awards with the best coverage", () => {
  // Nobody bids on B, so every award leaves it uncovered; Best Value still
  // picks one provider for A (y scores higher: 0.5454 + 0.36 vs 0.6 + 0.24).
  const bids = [
    {providerId: "x", providerName: "X", trustScore: 600,
      taskPrices: {A: 100}, bundlePriceSen: null},
    {providerId: "y", providerName: "Y", trustScore: 900,
      taskPrices: {A: 110}, bundlePriceSen: null},
  ];
  const options = buildAwardOptions({tasks: TWO_TASKS, bids});
  const bestValue = pick(options, "bestValue");
  assert.deepStrictEqual(bestValue.uncoveredTaskIds, ["B"]);
  assert.strictEqual(bestValue.awards.length, 1);
});

test("a hidden score counts as the neutral 700 when ranking", () => {
  const doc = (id, data) => ({id, data: () => data});
  const base = {taskPrices: {A: 50000, B: 50000}, bundlePriceSen: null};
  // Hidden: whatever number is stored, it ranks as 700.
  const hidden = bidFromSnap(doc("new", {
    ...base, providerTrustScore: 100, providerScoreVisible: false,
  }));
  assert.strictEqual(hidden.trustScore, 700);
  assert.strictEqual(hidden.scoreVisible, false);
  const absent = bidFromSnap(doc("old", {...base, providerTrustScore: 900}));
  assert.strictEqual(absent.trustScore, 700);
  const shown = bidFromSnap(doc("pro", {
    ...base, providerTrustScore: 750, providerScoreVisible: true,
  }));
  assert.strictEqual(shown.trustScore, 750);

  // The newcomer (RM 1,000) against a visible Trust 680 provider (RM 1,000):
  // 700 beats 680, so the newcomer wins Best Value even though the stored
  // score of 100 would have lost.
  const rival = bidFromSnap(doc("rival", {
    ...base, providerTrustScore: 680, providerScoreVisible: true,
  }));
  const options = buildAwardOptions({tasks: TWO_TASKS, bids: [rival, hidden]});
  const bestValue = pick(options, "bestValue");
  assert.strictEqual(bestValue.awards[0].providerId, "new");
  assert.strictEqual(bestValue.weightedTrust, 700);
  assert.strictEqual(bestValue.trustVisible, false);
});

test("Best Value ties go to the lower total, then fewer providers", () => {
  // Two identical providers: the same total and score, one provider each.
  const equal = [wholeBid("p", 800, 100000), wholeBid("q", 800, 100000)];
  const options = buildAwardOptions({tasks: TWO_TASKS, bids: equal});
  assert.strictEqual(pick(options, "bestValue").totalSen, 100000);
  assert.strictEqual(pick(options, "bestValue").providerCount, 1);

  // One provider (RM 10, Trust 800) against two specialists with the same
  // total and the same money-weighted Trust: fewer providers wins.
  const bids = [
    wholeBid("one", 800, 1000),
    {providerId: "s1", providerName: "S1", trustScore: 800,
      taskPrices: {A: 500}, bundlePriceSen: null},
    {providerId: "s2", providerName: "S2", trustScore: 800,
      taskPrices: {B: 500}, bundlePriceSen: null},
  ];
  const tied = buildAwardOptions({tasks: TWO_TASKS, bids});
  assert.strictEqual(pick(tied, "bestValue").providerCount, 1);
  assert.strictEqual(pick(tied, "bestValue").awards[0].providerId, "one");
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
