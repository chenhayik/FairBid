// Pure rules for jobs funded at award (`fundedAtAward`): how a price change is
// spread over the funded stages and what a cancellation refunds. Dependency-
// free so `npm test` can cover every rule without Firebase, like
// price_change.js. [milestones] is an array of `{id, status, amountSen,
// order}` rows (the milestone doc id plus its data).

// Mirrors isTerminal in index.js; duplicated so this stays a leaf module.
const isTerminal = (status) =>
  status === "released" || status === "resolved" || status === "refunded";

const sumAmounts = (rows) => rows.reduce((s, m) => s + (m.amountSen || 0), 0);

/** Money held in escrow that no one has delivered against yet. */
const fundedSen = (milestones) =>
  sumAmounts(milestones.filter((m) => m.status === "funded"));

/**
 * Error message if a price change of [deltaSen] (new price minus old) can't
 * be taken from the funded stages, else null. Only a decrease is limited: it
 * is refunded out of stages that haven't been delivered, disputed or paid.
 */
function checkFundedPriceChange(milestones, deltaSen) {
  const available = fundedSen(milestones);
  if (deltaSen < 0 && -deltaSen > available) {
    return "The price can only be reduced by the RM " +
        `${(available / 100).toFixed(2)} still in escrow for work that ` +
        "hasn't been delivered.";
  }
  return null;
}

/**
 * How an increase of [deltaSen] lands on the stages: it grows the only stage
 * when the job has exactly one and it is still `funded`, otherwise it becomes
 * a new "Price change" stage after the last one. Returns
 * `{grow: {id, amountSen}}` (the stage's new amount) or
 * `{add: {id, order, amountSen}}`.
 */
function planIncrease(milestones, deltaSen) {
  if (milestones.length === 1 && milestones[0].status === "funded") {
    const only = milestones[0];
    return {grow: {id: only.id, amountSen: only.amountSen + deltaSen}};
  }
  const order = milestones.reduce((max, m) => Math.max(max, m.order ?? -1), -1) + 1;
  return {add: {id: `m${order}`, order, amountSen: deltaSen}};
}

/**
 * How a decrease of [refundSen] is taken: from `funded` stages, highest order
 * first. Returns `{updates: [{id, amountSen}], deleteIds: [id]}` where
 * `updates` holds the reduced stages' new amounts and `deleteIds` those that
 * reached zero. Callers validate with [checkFundedPriceChange] first.
 */
function planDecrease(milestones, refundSen) {
  const funded = milestones
      .filter((m) => m.status === "funded")
      .sort((a, b) => (b.order ?? 0) - (a.order ?? 0));
  const updates = [];
  const deleteIds = [];
  let left = refundSen;
  for (const m of funded) {
    if (left <= 0) break;
    const take = Math.min(left, m.amountSen);
    left -= take;
    if (take === m.amountSen) deleteIds.push(m.id);
    else updates.push({id: m.id, amountSen: m.amountSen - take});
  }
  return {updates, deleteIds};
}

/**
 * True when removing [deleteIds] leaves only paid stages, i.e. the decrease
 * itself finished the job (nothing is left to deliver or release).
 */
function finishedByDecrease(milestones, deleteIds) {
  const gone = new Set(deleteIds);
  return milestones.every((m) => gone.has(m.id) || isTerminal(m.status));
}

/** A cancellation can go ahead unless a stage is delivered or disputed. */
const canCancelFunded = (milestones) =>
  !milestones.some((m) => m.status === "submitted" || m.status === "disputed");

/**
 * What cancelling refunds and cleans up: every `funded` stage is refunded in
 * full (`refunds`), and every stage that is neither funded nor paid is deleted
 * (`deleteIds`). A `pending` stage (a dispute refund re-locked its amount
 * against the wallet) also releases that amount from `escrowLockedSen`
 * (`unlockSen`). Paid stages stay.
 */
function cancellationPlan(milestones) {
  const refunds = milestones
      .filter((m) => m.status === "funded")
      .map((m) => ({id: m.id, amountSen: m.amountSen}));
  const open = milestones.filter(
      (m) => m.status !== "funded" && !isTerminal(m.status));
  const unlockSen =
      sumAmounts(open.filter((m) => m.status === "pending"));
  return {
    refunds,
    deleteIds: [...refunds.map((r) => r.id), ...open.map((m) => m.id)],
    unlockSen,
  };
}

/**
 * What a "refund the client and end the job" ruling settles: every stage
 * still holding money is refunded, unfunded ones are deleted and unlocked.
 */
function disputeRefundPlan(job, milestones) {
  const held = ["funded", "submitted", "disputed"];
  const refunds = milestones
      .filter((m) => held.includes(m.status))
      .map((m) => ({id: m.id, amountSen: m.amountSen}));
  const unfunded = milestones.filter(
      (m) => !held.includes(m.status) && !isTerminal(m.status));
  // Legacy jobs lock the whole price at award and unlock it stage by stage.
  const everFunded = sumAmounts(milestones.filter(
      (m) => held.includes(m.status) || isTerminal(m.status)));
  const unlockSen = job.fundedAtAward ?
      sumAmounts(unfunded.filter((m) => m.status === "pending")) :
      Math.max(0, (job.acceptedBidAmountSen || 0) - everFunded);
  return {refunds, deleteIds: unfunded.map((m) => m.id), unlockSen};
}

exports.fundedSen = fundedSen;
exports.disputeRefundPlan = disputeRefundPlan;
exports.checkFundedPriceChange = checkFundedPriceChange;
exports.planIncrease = planIncrease;
exports.planDecrease = planDecrease;
exports.finishedByDecrease = finishedByDecrease;
exports.canCancelFunded = canCancelFunded;
exports.cancellationPlan = cancellationPlan;
