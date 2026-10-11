const assert = require("node:assert");
const test = require("node:test");
const {
  fundedSen,
  checkFundedPriceChange,
  planIncrease,
  planDecrease,
  finishedByDecrease,
  canCancelFunded,
  cancellationPlan,
  disputeRefundPlan,
} = require("./payouts");

const ms = (order, status, amountSen) =>
  ({id: `m${order}`, order, status, amountSen});

test("fundedSen counts only funded stages", () => {
  const all = ["proposed", "pending", "funded", "submitted", "disputed",
    "released", "resolved"].map((s, i) => ms(i, s, 100));
  assert.strictEqual(fundedSen(all), 100);
  assert.strictEqual(fundedSen([]), 0);
});

test("checkFundedPriceChange: decrease limited to funded stages", () => {
  const stages = [ms(0, "released", 4000), ms(1, "funded", 3000),
    ms(2, "submitted", 3000)];
  assert.strictEqual(checkFundedPriceChange(stages, -3000), null);
  assert.match(checkFundedPriceChange(stages, -3001), /30\.00 still in/);
  assert.strictEqual(checkFundedPriceChange(stages, 5000), null);
  assert.match(checkFundedPriceChange([], -1), /0\.00 still in/);
});

test("planIncrease grows a lone funded stage", () => {
  assert.deepStrictEqual(planIncrease([ms(0, "funded", 10000)], 2500),
      {grow: {id: "m0", amountSen: 12500}});
});

test("planIncrease adds a stage when the lone stage is submitted", () => {
  assert.deepStrictEqual(planIncrease([ms(0, "submitted", 10000)], 2500),
      {add: {id: "m1", order: 1, amountSen: 2500}});
});

test("planIncrease adds a stage after the last when there are several", () => {
  const stages = [ms(0, "released", 4000), ms(3, "funded", 6000)];
  assert.deepStrictEqual(planIncrease(stages, 100),
      {add: {id: "m4", order: 4, amountSen: 100}});
});

test("planDecrease takes the highest order first and deletes emptied", () => {
  const stages = [ms(0, "funded", 5000), ms(1, "funded", 2000),
    ms(2, "funded", 1000)];
  assert.deepStrictEqual(planDecrease(stages, 2500),
      {updates: [{id: "m1", amountSen: 500}], deleteIds: ["m2"]});
  assert.deepStrictEqual(planDecrease(stages, 8000),
      {updates: [], deleteIds: ["m2", "m1", "m0"]});
});

test("planDecrease skips stages that are not funded", () => {
  const stages = [ms(0, "funded", 5000), ms(1, "submitted", 2000),
    ms(2, "released", 1000)];
  assert.deepStrictEqual(planDecrease(stages, 1000),
      {updates: [{id: "m0", amountSen: 4000}], deleteIds: []});
});

test("finishedByDecrease: only when nothing unpaid remains", () => {
  const stages = [ms(0, "released", 4000), ms(1, "funded", 6000)];
  assert.strictEqual(finishedByDecrease(stages, ["m1"]), true);
  assert.strictEqual(finishedByDecrease(stages, []), false);
});

test("canCancelFunded: blocked by submitted or disputed only", () => {
  assert.strictEqual(canCancelFunded([ms(0, "funded", 1)]), true);
  assert.strictEqual(canCancelFunded([ms(0, "released", 1),
    ms(1, "pending", 1)]), true);
  assert.strictEqual(canCancelFunded([ms(0, "submitted", 1)]), false);
  assert.strictEqual(canCancelFunded([ms(0, "funded", 1),
    ms(1, "disputed", 1)]), false);
});

test("cancellationPlan refunds funded, keeps paid, deletes unfunded", () => {
  const stages = [ms(0, "released", 4000), ms(1, "funded", 3000),
    ms(2, "pending", 2000), ms(3, "funded", 500)];
  assert.deepStrictEqual(cancellationPlan(stages), {
    refunds: [{id: "m1", amountSen: 3000}, {id: "m3", amountSen: 500}],
    deleteIds: ["m1", "m3", "m2"],
  });
});

test("disputeRefundPlan refunds every held stage and deletes the rest", () => {
  const stages = [ms(0, "released", 4000), ms(1, "disputed", 3000),
    ms(2, "pending", 2000), ms(3, "submitted", 500)];
  assert.deepStrictEqual(disputeRefundPlan(stages), {
    refunds: [{id: "m1", amountSen: 3000}, {id: "m3", amountSen: 500}],
    deleteIds: ["m2"],
  });
});
