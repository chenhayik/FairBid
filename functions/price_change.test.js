const assert = require("node:assert");
const {
  MAX_PRICE_CHANGES,
  committedSen,
  validatePriceChange,
  escrowLockDelta,
  completesJob,
} = require("./price_change");

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

const job = (o = {}) => ({
  status: "in_progress", acceptedBidAmountSen: 10000, ...o,
});
const ms = (status, amountSen) => ({status, amountSen});
const check = (o) => validatePriceChange({
  job: job(), milestones: [], newAmountSen: 12000, ...o,
});

test("committedSen counts only locked statuses", () => {
  const all = ["proposed", "pending", "funded", "submitted", "disputed",
    "released", "resolved"].map((s) => ms(s, 100));
  assert.strictEqual(committedSen(all), 500);
  assert.strictEqual(committedSen([]), 0);
  assert.strictEqual(committedSen([ms("proposed", 5), ms("pending", 5)]), 0);
});

test("valid change passes", () => assert.strictEqual(check({}), null));
test("decrease passes", () =>
  assert.strictEqual(check({newAmountSen: 8000}), null));

test("not in progress rejected", () =>
  assert.match(check({job: job({status: "open"})}), /not in progress/));
test("bundle task rejected", () =>
  assert.match(check({job: job({bundleId: "b1"})}), /Bundle tasks/));
test("non-integer rejected", () =>
  assert.match(check({newAmountSen: 100.5}), /valid amount/));
test("zero and negative rejected", () => {
  assert.match(check({newAmountSen: 0}), /valid amount/);
  assert.match(check({newAmountSen: -5}), /valid amount/);
});
test("same as current rejected", () =>
  assert.match(check({newAmountSen: 10000}), /already the agreed/));
test("disputed milestone rejected", () =>
  assert.match(check({milestones: [ms("disputed", 1000)]}), /dispute/));
test("count at max rejected, below max ok", () => {
  assert.match(check({job: job({priceChangeCount: MAX_PRICE_CHANGES})}),
      /at most/);
  assert.strictEqual(
      check({job: job({priceChangeCount: MAX_PRICE_CHANGES - 1})}), null);
});
test("strict floor: equal to committed rejected, +1 ok", () => {
  const milestones = [ms("funded", 4000), ms("released", 2000),
    ms("proposed", 4000)];
  assert.match(check({milestones, newAmountSen: 6000}), /60\.00 already/);
  assert.strictEqual(check({milestones, newAmountSen: 6001}), null);
  assert.match(check({milestones, newAmountSen: 5000}), /already committed/);
});

test("funded at award: floor rule is replaced by the refundable limit", () => {
  const funded = job({fundedAtAward: true});
  const milestones = [ms("released", 4000), ms("funded", 6000)];
  // Below the committed total is fine (the funded part is refunded)...
  assert.strictEqual(
      check({job: funded, milestones, newAmountSen: 5000}), null);
  // ...but not by more than the funded stages hold.
  assert.match(
      check({job: funded, milestones, newAmountSen: 3999}), /60\.00 still in/);
  assert.strictEqual(
      check({job: funded, milestones, newAmountSen: 20000}), null);
});

test("funded at award: disputed, same price and max count still rejected", () => {
  const funded = job({fundedAtAward: true});
  assert.match(check({job: funded, milestones: [ms("disputed", 100)]}),
      /dispute/);
  assert.match(check({job: funded, newAmountSen: 10000}), /already the agreed/);
  assert.match(
      check({job: job({fundedAtAward: true, priceChangeCount: 3})}), /at most/);
  assert.match(check({job: job({fundedAtAward: true, bundleId: "b"})}),
      /Bundle tasks/);
});

test("escrowLockDelta", () => {
  assert.strictEqual(escrowLockDelta(10000, 12000), 2000);
  assert.strictEqual(escrowLockDelta(10000, 8000), -2000);
});

test("completesJob: last release on a full plan completes", () => {
  const job = {acceptedBidAmountSen: 10000};
  const ms = [
    {id: "m0", status: "released", amountSen: 4000},
    {id: "m1", status: "submitted", amountSen: 6000},
  ];
  assert.strictEqual(completesJob(job, ms, "m1"), true);
  assert.strictEqual(completesJob(job, ms, "m0"), false);
});

test("completesJob: unplanned remainder after a price change blocks it", () => {
  // Price raised to 150 and the unfunded tail deleted: releasing the only
  // funded milestone must not complete the job.
  const ms = [{id: "m0", status: "submitted", amountSen: 4000}];
  assert.strictEqual(completesJob({acceptedBidAmountSen: 15000}, ms, "m0"),
      false);
  assert.strictEqual(completesJob({acceptedBidAmountSen: 4000}, ms, "m0"),
      true);
});

if (failed > 0) {
  console.log(`\n${failed} price change test(s) failed.`);
  process.exit(1);
}
console.log("All price change tests passed.\n");
