// Pure rules for the mutual price-change flow (requestPriceChange and
// respondToPriceChange in index.js). Needs no Firebase, so `npm test` covers them.

const {checkFundedPriceChange, isTerminal} = require("./payouts");

/** Max accepted price changes per job. */
const MAX_PRICE_CHANGES = 3;

/**
 * What:   Validator for a proposed price.
 * Input:  {job, milestones (data objects), newAmountSen}.
 * Output: An error message, or null when the change is allowed.
 * How:    In progress, not a bundle task, a new valid amount, under the change
 *         limit, no dispute, and a decrease fits the funded stages (payouts.js).
 */
function validatePriceChange({job, milestones, newAmountSen}) {
  if (job?.status !== "in_progress") return "This job is not in progress.";
  if (job.bundleId) return "Bundle tasks can't be re-priced yet.";
  if (!Number.isInteger(newAmountSen) || newAmountSen <= 0) {
    return "Enter a valid amount.";
  }
  if (newAmountSen === job.acceptedBidAmountSen) {
    return "That is already the agreed price.";
  }
  if ((job.priceChangeCount || 0) >= MAX_PRICE_CHANGES) {
    return `The price can be changed at most ${MAX_PRICE_CHANGES} times.`;
  }
  if (milestones.some((m) => m.status === "disputed")) {
    return "The price can't change while a milestone is in dispute.";
  }
  return checkFundedPriceChange(
      milestones, newAmountSen - job.acceptedBidAmountSen);
}

/**
 * What:   Completion check for a release.
 * Input:  [job], [milestones] as `{id, status, amountSen}`, the [releasingId].
 * Output: True when every other stage is finished and the stages add up to the
 *         agreed price.
 */
function completesJob(job, milestones, releasingId) {
  const allDone = milestones.every(
      (m) => m.id === releasingId || isTerminal(m.status));
  const planned = milestones.reduce((sum, m) => sum + (m.amountSen || 0), 0);
  return allDone && planned === job.acceptedBidAmountSen;
}

exports.MAX_PRICE_CHANGES = MAX_PRICE_CHANGES;
exports.validatePriceChange = validatePriceChange;
exports.completesJob = completesJob;
