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
      .some((p) => p.includes("part of a lot") || p.includes("all or nothing")));
  // A provider who never bid at all.
  assert.ok(refuse({plumbing: "nobody"})[0].includes("No bid from provider"));
});

if (failed > 0) {
  console.log(`\n${failed} award engine test(s) failed.`);
  process.exit(1);
}
console.log("All award engine tests passed.\n");
