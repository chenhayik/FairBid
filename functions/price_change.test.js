const assert = require("node:assert");
const test = require("node:test");
const {
  MAX_PRICE_CHANGES,
  validatePriceChange,
  completesJob,
} = require("./price_change");

const job = (o = {}) => ({
  status: "in_progress", acceptedBidAmountSen: 10000, ...o,
});
const ms = (status, amountSen) => ({status, amountSen});
const check = (o) => validatePriceChange({
  job: job(), milestones: [], newAmountSen: 12000, ...o,
});

test("valid change passes", () => assert.strictEqual(check({}), null));

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
test("a decrease is limited to the refundable funded stages", () => {
  const funded = job();
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

test("completesJob: last release on a full plan completes", () => {
  const job = {acceptedBidAmountSen: 10000};
  const ms = [
    {id: "m0", status: "released", amountSen: 4000},
    {id: "m1", status: "submitted", amountSen: 6000},
  ];
  assert.strictEqual(completesJob(job, ms, "m1"), true);
  assert.strictEqual(completesJob(job, ms, "m0"), false);
});

test("completesJob: stages short of the price block completion", () => {
  const ms = [{id: "m0", status: "submitted", amountSen: 4000}];
  assert.strictEqual(completesJob({acceptedBidAmountSen: 15000}, ms, "m0"),
      false);
  assert.strictEqual(completesJob({acceptedBidAmountSen: 4000}, ms, "m0"),
      true);
});
