// Unit tests for the award engine in bundle_award.js.
//
// The scenario is the bathroom bundle from reference/bundle_bidding/demo.dart,
// so the ported engine is pinned to the numbers the prototype produced.
// Plain node:assert, in the style of bundles.test.js. Run with `npm test`.

const assert = require("node:assert");
const {
  splitBundlePrice,
  offersFor,
  buildAwardOptions,
  checkManualAward,
  allowanceSen,
  manualOption,
} = require("./bundle_award");

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

// Waterproofing and tiling are one lot, so they always go together;
// waterproofing follows the plumbing, and tiling follows waterproofing.
const TASKS = [
  {id: "plumbing", title: "Plumbing rough-in", lotId: null,
    startsAfterJobId: null},
  {id: "electrical", title: "Electrical points", lotId: null,
    startsAfterJobId: null},
  {id: "waterproof", title: "Waterproofing", lotId: "wetWorks",
    startsAfterJobId: "plumbing"},
  {id: "tiling", title: "Tiling", lotId: "wetWorks",
    startsAfterJobId: "waterproof"},
];

const TASK_INDEX = {plumbing: 0, electrical: 1, waterproof: 2, tiling: 3};

// A generalist who prices everything with a discount, two single-trade
// specialists, and a tiler who only wants the wet works as a package.
const BIDS = [
  {
    providerId: "aida", providerName: "Aida Renovation", trustScore: 820,
    taskPrices: {plumbing: 18500, electrical: 19000, waterproof: 25000,
      tiling: 33000},
    allOrNothing: false, bundlePriceSen: 90000,
  },
  {
    providerId: "budi", providerName: "Budi Plumbing", trustScore: 760,
    taskPrices: {plumbing: 18000}, allOrNothing: false, bundlePriceSen: null,
  },
  {
    providerId: "chandran", providerName: "Chandran Electrical",
    trustScore: 900, taskPrices: {electrical: 16000}, allOrNothing: false,
    bundlePriceSen: null,
  },
  {
    providerId: "dev", providerName: "Dev Tiling Works", trustScore: 700,
    taskPrices: {waterproof: 22000, tiling: 30000}, allOrNothing: true,
    bundlePriceSen: 50000,
  },
];

const CAP = {capPct: 5, capSen: 50000}; // 5% AND RM 500, as PlatformConfig has

/** The option with this key, from a built set of three. */
function pick(options, key) {
  return options.find((o) => o.key === key);
}

console.log("bundle_award.js engine");

test("a bundle price splits across tasks and adds up exactly", () => {
  const amounts = splitBundlePrice({waterproof: 22000, tiling: 30000}, 50000);
  assert.strictEqual(amounts.waterproof + amounts.tiling, 50000);
  assert.strictEqual(amounts.waterproof, 21153);
  assert.strictEqual(amounts.tiling, 28847);
  // An awkward ratio still loses nothing to rounding.
  const thirds = splitBundlePrice({a: 1, b: 1, c: 1}, 100);
  assert.strictEqual(thirds.a + thirds.b + thirds.c, 100);
});

test("a bid offers every subset it would accept", () => {
  // Two tasks, no all-or-nothing: each on its own, plus both together.
  const offers = offersFor(BIDS[3], TASKS, TASK_INDEX);
  assert.strictEqual(offers.length, 1); // all-or-nothing: the pair only
  assert.strictEqual(offers[0].priceSen, 50000); // priced at the bundle price

  const generalist = offersFor(BIDS[0], TASKS, TASK_INDEX);
  // 15 non-empty subsets, minus the 8 holding exactly one of the two
  // wet-works tasks, which would split the lot.
  assert.strictEqual(generalist.length, 7);
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

  // Fewest providers: the generalist takes the lot at their bundle price.
  const fewest = pick(options, "fewest");
  assert.strictEqual(fewest.totalSen, 90000);
  assert.strictEqual(fewest.providerCount, 1);
  assert.strictEqual(fewest.premiumSen, 6000);
  assert.strictEqual(fewest.weightedTrust, 820);
  assert.deepStrictEqual(fewest.warnings, []); // one provider, no handovers

  // Recommended: two providers at RM 35 over the cheapest, inside the
  // RM 42 allowance (5% of RM 840).
  const recommended = pick(options, "recommended");
  assert.strictEqual(recommended.totalSen, 87500);
  assert.strictEqual(recommended.providerCount, 2);
  assert.strictEqual(recommended.premiumSen, 3500);
});

test("an award that splits a dependency is flagged", () => {
  const options = buildAwardOptions({tasks: TASKS, bids: BIDS, ...CAP});
  const warnings = pick(options, "cheapest").warnings;
  assert.strictEqual(warnings.length, 1);
  assert.ok(warnings[0].includes("Waterproofing starts after Plumbing"));
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

test("a hand-picked award is priced from the stored bids", () => {
  const {awards, problems} = checkManualAward({
    tasks: TASKS,
    bids: BIDS,
    providerByTaskId: {
      plumbing: "budi",
      electrical: "chandran",
      waterproof: "dev",
      tiling: "dev",
    },
  });
  assert.deepStrictEqual(problems, []);
  const dev = awards.find((a) => a.providerId === "dev");
  assert.strictEqual(
      dev.taskAmountsSen.waterproof + dev.taskAmountsSen.tiling, 50000);
});

test("a hand-picked award may not break a bid's terms", () => {
  const refuse = (providerByTaskId) => checkManualAward(
      {tasks: TASKS, bids: BIDS, providerByTaskId}).problems;

  // All-or-nothing: the tiler takes both wet-works tasks or neither.
  assert.ok(refuse({tiling: "dev"})[0].includes("all or nothing"));
  // A task that provider never priced.
  assert.ok(refuse({plumbing: "chandran"})[0].includes("never priced"));
  // A lot cannot be split, even between willing providers.
  assert.ok(refuse({waterproof: "aida", tiling: "dev"})
      .some((p) => p.includes("linked tasks") || p.includes("all or nothing")));
  // A provider who never bid at all.
  assert.ok(refuse({plumbing: "nobody"})[0].includes("No bid from provider"));
});

test("checkManualAward returns a problem, not a TypeError, for a " +
    "prototype-shaped provider id", () => {
  // A plain-object lookup table would resolve "constructor" through
  // Object.prototype instead of missing outright, turning the clean "No bid
  // from provider" problem into a crash deeper inside (`id in undefined`).
  const tasks = [{id: "A", title: "Task A", lotId: null,
    startsAfterJobId: null}];
  const {awards, problems} = checkManualAward({
    tasks, bids: [], providerByTaskId: {A: "constructor"},
  });
  assert.deepStrictEqual(awards, []);
  assert.ok(problems[0].includes("No bid from provider"));
});

test("offersFor / buildAwardOptions drop a bid pricing a task the bundle " +
    "no longer has", () => {
  const tasks = [
    {id: "A", title: "Task A", lotId: null, startsAfterJobId: null},
    {id: "C", title: "Task C", lotId: null, startsAfterJobId: null},
  ];
  const taskIndex = {A: 0, C: 1};
  const bids = [
    {providerId: "x", providerName: "X", trustScore: 50,
      taskPrices: {B: 50}, allOrNothing: false, bundlePriceSen: null},
    {providerId: "y", providerName: "Y", trustScore: 50,
      taskPrices: {A: 100}, allOrNothing: false, bundlePriceSen: null},
  ];
  // x priced task "B", which this bundle doesn't have (say, it stopped
  // being open) - it must offer nothing at all, not silently cover task A
  // the way `1 << taskIndex["B"]` (== `1 << undefined` == 1) used to.
  assert.deepStrictEqual(offersFor(bids[0], tasks, taskIndex), []);

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
    {id: "A", title: "Task A", lotId: null, startsAfterJobId: null},
    {id: "B", title: "Task B", lotId: null, startsAfterJobId: null},
  ];
  const bids = [
    {providerId: "x", providerName: "X", trustScore: 50,
      taskPrices: {A: 500, B: 500}, allOrNothing: false, bundlePriceSen: null},
    {providerId: "y", providerName: "Y", trustScore: 90,
      taskPrices: {A: 510, B: 510}, allOrNothing: false, bundlePriceSen: null},
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
    {id: "A", title: "Task A", lotId: null, startsAfterJobId: null},
    {id: "B", title: "Task B", lotId: null, startsAfterJobId: null},
  ];
  const bids = [
    // Two specialists: the overall cheapest, at RM 8 total.
    {providerId: "s1", providerName: "S1", trustScore: 99,
      taskPrices: {A: 400}, allOrNothing: false, bundlePriceSen: null},
    {providerId: "s2", providerName: "S2", trustScore: 99,
      taskPrices: {B: 400}, allOrNothing: false, bundlePriceSen: null},
    // Two generalists, same Trust Score, one cheaper than the other - both
    // inside a cap wide enough to admit either.
    {providerId: "g1", providerName: "G1", trustScore: 60,
      taskPrices: {A: 500, B: 500}, allOrNothing: false, bundlePriceSen: null},
    {providerId: "g2", providerName: "G2", trustScore: 60,
      taskPrices: {A: 520, B: 520}, allOrNothing: false, bundlePriceSen: null},
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

// ---------------------------------------------------------------------------
// Phase 4: pricing the requestor's own hand-picked award for the preview
// ("Your pick"), via the same pure helper previewBundleAward calls.
// ---------------------------------------------------------------------------

test("manualOption returns problems, not an option, for a bad pick", () => {
  // Dev bid all-or-nothing on waterproof+tiling; picking only tiling breaks
  // that term, same as checkManualAward on its own.
  const {manual, problems} = manualOption({
    tasks: TASKS, bids: BIDS, providerByTaskId: {tiling: "dev"},
    cheapestCostSen: 84000,
  });
  assert.strictEqual(manual, null);
  assert.ok(problems[0].includes("all or nothing"));
});

test("manualOption prices a valid pick as an option card", () => {
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

if (failed > 0) {
  console.log(`\n${failed} award engine test(s) failed.`);
  process.exit(1);
}
console.log("All award engine tests passed.\n");
