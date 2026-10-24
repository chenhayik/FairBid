// Trust Score v2 math - a multi-signal composite of four 0–100 sub-scores:
// reviews (Bayesian), track record (jobs completed − disputes lost),
// verification status and profile completeness. Dependency-free so
// check_vectors.js (npm test) can run it with bare node.
//
// Must stay in sync with PlatformConfig.trustBreakdownFor
// (lib/core/config/platform_config.dart); test/fixtures/trust_vectors.json
// pins both implementations (run `npm test` here / `flutter test` there).

// Bayesian review-score priors.
const TRUST_PRIOR_MEAN = 3.5;
const TRUST_PRIOR_WEIGHT = 10;

// Integer-percent weights (sum 100) - integer math keeps JS and Dart exact.
const REVIEW_WEIGHT_PCT = 45;
const TRACK_RECORD_WEIGHT_PCT = 25;
const VERIFICATION_WEIGHT_PCT = 20;
const PROFILE_WEIGHT_PCT = 10;

const TRACK_RECORD_PER_JOB = 10;
const TRACK_RECORD_JOB_CAP = 10;
const DISPUTE_LOST_PENALTY = 10;
const VERIFICATION_PENDING_SCORE = 40;

// The score stays hidden ("New Provider") until admin-approved AND this many
// completed jobs.
const MIN_JOBS_FOR_VISIBLE_SCORE = 3;

/**
 * What:   Range limiter.
 * Input:  [value] and the bounds [lo] and [hi].
 * Output: [value] held between [lo] and [hi].
 */
const clamp = (value, lo, hi) => Math.min(hi, Math.max(lo, value));

/**
 * What:   Trust Score breakdown.
 * Input:  A `users/{uid}` document's data and privateData from its 'private/payout' doc for phone number.
 * Output: {reviewScore, trackRecordScore, verificationScore, profileScore,
 *         composite, scoreVisible}.
 */
function computeTrust(user, privateData = {}) {
  const ratingSum = user.ratingSum || 0;
  const ratingCount = user.ratingCount || 0;
  const weighted =
      (TRUST_PRIOR_WEIGHT * TRUST_PRIOR_MEAN + ratingSum) /
      (TRUST_PRIOR_WEIGHT + ratingCount);
  const reviewScore = clamp(Math.round((weighted / 5) * 100), 0, 100);

  const jobsCompleted = user.jobsCompleted || 0;
  const disputesLost = user.disputesLost || 0;
  const trackRecordScore = clamp(
      TRACK_RECORD_PER_JOB * Math.min(jobsCompleted, TRACK_RECORD_JOB_CAP) -
      DISPUTE_LOST_PENALTY * disputesLost,
      0, 100);

  const verificationScore = user.verificationStatus === "approved" ? 100 :
      user.verificationStatus === "pending" ? VERIFICATION_PENDING_SCORE : 0;

  const has = (value) => typeof value === "string" && value !== "";
  const profileScore = 20 * [
    has(user.displayName), has(privateData.phone)|| has(user.phone), has(user.bio),
    has(user.profilePhotoUrl), has(user.location),
  ].filter(Boolean).length;

  const composite = clamp(Math.round(
      (REVIEW_WEIGHT_PCT * reviewScore +
       TRACK_RECORD_WEIGHT_PCT * trackRecordScore +
       VERIFICATION_WEIGHT_PCT * verificationScore +
       PROFILE_WEIGHT_PCT * profileScore) / 10), 0, 1000);

  return {
    reviewScore,
    trackRecordScore,
    verificationScore,
    profileScore,
    composite,
    scoreVisible: user.verificationStatus === "approved" &&
        jobsCompleted >= MIN_JOBS_FOR_VISIBLE_SCORE,
  };
}

module.exports = {computeTrust};
