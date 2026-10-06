// Pure helpers for the mutual price-change flow (requestPriceChange /
// respondToPriceChange in index.js). Dependency-free so `npm test` can cover
// every rule without Firebase, like bundles.js.

const {checkFundedPriceChange} = require("./payouts");

/** Max accepted price changes per job. */
const MAX_PRICE_CHANGES = 3;

// A finished milestone status; `resolved` is only kept for old data.
const isTerminal = (status) =>
  status === "released" || status === "resolved" || status === "refunded";

/**
 * Returns an error message if [newAmountSen] can't become the job's agreed
 * price, else null. [milestones] is an array of milestone data objects. The
 * new price is a top-up or a refund of the undelivered part (see payouts.js).
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
 * Whether releasing milestone [releasingId] completes the job: every other
 * milestone is terminal AND the stages cover the agreed price. [milestones]
 * is an array of `{id, status, amountSen}`.
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
