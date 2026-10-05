// Pure helpers for the mutual price-change flow (requestPriceChange /
// respondToPriceChange in index.js). Dependency-free so `npm test` can cover
// every rule without Firebase, like bundles.js.

const {checkFundedPriceChange} = require("./payouts");

/** Max accepted price changes per job. */
const MAX_PRICE_CHANGES = 3;

// Mirrors isTerminal/isLocked in index.js (a milestone whose money is
// committed). Duplicated so this module stays a dependency-free leaf; keep
// the two in sync.
const isTerminal = (status) =>
  status === "released" || status === "resolved" || status === "refunded";
const isLocked = (status) =>
  status === "funded" || status === "submitted" ||
  status === "disputed" || isTerminal(status);

/** Sum of the milestones whose money is already committed. */
function committedSen(milestones) {
  return milestones.reduce(
      (sum, m) => (isLocked(m.status) ? sum + (m.amountSen || 0) : sum), 0);
}

/**
 * Returns an error message if [newAmountSen] can't become the job's agreed
 * price, else null. [milestones] is an array of milestone data objects. The
 * new price must strictly exceed what is already committed, so an unfunded
 * remainder is left for a fresh milestone plan. Jobs funded at award skip
 * that rule (see payouts.js).
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
  // Funded at award: the whole price is already in escrow, so a change is a
  // top-up or a refund of the undelivered part, never a re-plan.
  if (job.fundedAtAward) {
    return checkFundedPriceChange(
        milestones, newAmountSen - job.acceptedBidAmountSen);
  }
  const committed = committedSen(milestones);
  if (newAmountSen <= committed) {
    return "The new price must be more than the RM " +
        `${(committed / 100).toFixed(2)} already committed to funded or ` +
        "completed milestones.";
  }
  return null;
}

/** Change to the requestor's locked commitment for a price change. */
const escrowLockDelta = (oldSen, newSen) => newSen - oldSen;

/**
 * Whether releasing milestone [releasingId] completes the job: every other
 * milestone is terminal AND the plan covers the agreed price. The second check
 * matters after a price change (or a rejected amendment) deletes the unfunded
 * tail - releasing the last funded milestone must not complete the job while
 * part of the price is still unplanned, or that remainder would stay locked in
 * the requestor's `escrowLockedSen` forever. [milestones] is an array of
 * `{id, status, amountSen}`.
 */
function completesJob(job, milestones, releasingId) {
  const allDone = milestones.every(
      (m) => m.id === releasingId || isTerminal(m.status));
  const planned = milestones.reduce((sum, m) => sum + (m.amountSen || 0), 0);
  return allDone && planned === job.acceptedBidAmountSen;
}

exports.MAX_PRICE_CHANGES = MAX_PRICE_CHANGES;
exports.committedSen = committedSen;
exports.validatePriceChange = validatePriceChange;
exports.escrowLockDelta = escrowLockDelta;
exports.completesJob = completesJob;
