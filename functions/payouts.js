// Pure rules for jobs funded at award (`fundedAtAward`): how a price change is
// spread over the funded stages and what a cancellation refunds. Needs no
// Firebase. [milestones] is an array of `{id, status, amountSen, order}` rows.

/**
 * What:   Finished-stage check.
 * Input:  A milestone [status] string.
 * Output: True for released, refunded, or the old `resolved`.
 */
const isTerminal = (status) =>
  status === "released" || status === "resolved" || status === "refunded";

/**
 * What:   Total of stage amounts.
 * Input:  [rows] with an optional `amountSen`.
 * Output: Sum in sen; a missing amount counts as 0.
 */
const sumAmounts = (rows) => rows.reduce((s, m) => s + (m.amountSen || 0), 0);

/**
 * What:   Escrow not yet delivered against.
 * Input:  [milestones] rows.
 * Output: Total sen of `funded` stages.
 */
const fundedSen = (milestones) =>
  sumAmounts(milestones.filter((m) => m.status === "funded"));

/**
 * What:   Limit check for a price change.
 * Input:  [milestones] and [deltaSen] (new price minus old).
 * Output: An error message, or null. Only a decrease is limited: it is refunded
 *         from stages not yet delivered, disputed or paid.
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
 * What:   Plan for a price increase.
 * Input:  [milestones] and [deltaSen] > 0.
 * Output: `{grow: {id, amountSen}}` (the only stage, if still funded, gets its
 *         new amount) or `{add: {id, order, amountSen}}` (a new "Price change"
 *         stage after the last).
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
 * What:   Plan for a price decrease.
 * Input:  [milestones] and [refundSen] > 0.
 * Output: `{updates: [{id, amountSen}], deleteIds}`: reduced stages and those
 *         that reached zero, taken from `funded` stages, highest order first.
 * Notes:  Validate with checkFundedPriceChange first.
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
 * What:   Completion check after a decrease.
 * Input:  [milestones] and the [deleteIds] removed.
 * Output: True when only finished stages remain, so the decrease finished the job.
 */
function finishedByDecrease(milestones, deleteIds) {
  const gone = new Set(deleteIds);
  return milestones.every((m) => gone.has(m.id) || isTerminal(m.status));
}

/**
 * What:   Cancellation guard.
 * Input:  [milestones] rows.
 * Output: False when any stage is delivered or disputed, else true.
 */
const canCancelFunded = (milestones) =>
  !milestones.some((m) => m.status === "submitted" || m.status === "disputed");

/**
 * What:   Plan for a cancellation.
 * Input:  [milestones] rows.
 * Output: `{refunds: [{id, amountSen}], deleteIds}`: funded stages refunded in
 *         full; every unpaid stage deleted; paid stages stay.
 */
function cancellationPlan(milestones) {
  const refunds = milestones
      .filter((m) => m.status === "funded")
      .map((m) => ({id: m.id, amountSen: m.amountSen}));
  const open = milestones.filter(
      (m) => m.status !== "funded" && !isTerminal(m.status));
  return {
    refunds,
    deleteIds: [...refunds.map((r) => r.id), ...open.map((m) => m.id)],
  };
}

/**
 * What:   Plan for a dispute ruling that refunds the client.
 * Input:  [milestones] rows.
 * Output: `{refunds, deleteIds}`: every stage still holding money (funded,
 *         submitted, disputed) refunded; unfunded stages deleted.
 */
function disputeRefundPlan(milestones) {
  const held = ["funded", "submitted", "disputed"];
  const refunds = milestones
      .filter((m) => held.includes(m.status))
      .map((m) => ({id: m.id, amountSen: m.amountSen}));
  const unfunded = milestones.filter(
      (m) => !held.includes(m.status) && !isTerminal(m.status));
  return {refunds, deleteIds: unfunded.map((m) => m.id)};
}

exports.isTerminal = isTerminal;
exports.fundedSen = fundedSen;
exports.disputeRefundPlan = disputeRefundPlan;
exports.checkFundedPriceChange = checkFundedPriceChange;
exports.planIncrease = planIncrease;
exports.planDecrease = planDecrease;
exports.finishedByDecrease = finishedByDecrease;
exports.canCancelFunded = canCancelFunded;
exports.cancellationPlan = cancellationPlan;
