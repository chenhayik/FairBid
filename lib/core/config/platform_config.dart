/// Platform-wide tunables that the plan (§3.2.3, §3.4.3) treats as a future
/// "platform configuration document". Kept in one place so the bid-ranking and
/// Trust Score code share a single source of truth and tests can pin the maths.
class PlatformConfig {
  const PlatformConfig._();

  /// "Best Value" composite weights. Price and trust each contribute a
  /// normalised 0–1 score; the weights (summing to 1) balance them.
  static const double priceWeight = 0.6;
  static const double trustWeight = 0.4;

  /// Per-top-up cap (RM 10,000) for the demo wallet, enforced by the
  /// `topUpWallet` Cloud Function (which keeps its own copy in sync).
  static const int maxTopUpSen = 1000000;

  /// Most milestones one plan may hold, enforced by the `proposeMilestonePlan`
  /// Cloud Function (which keeps its own copy in sync).
  static const int maxMilestones = 20;

  /// Bayesian Trust Score priors: a new provider starts as if they already had
  /// [trustPriorWeight] reviews averaging [trustPriorMean] stars, so a single
  /// review moves the score only gently away from the platform baseline.
  static const double trustPriorMean = 3.5;
  static const int trustPriorWeight = 10;

  /// The Bayesian Trust Score (0–1000) for a user with the given aggregate
  /// review data. With no reviews this is the prior baseline (700); each review
  /// pulls it toward that reviewer's rating. See plan §3.4.3.
  ///
  /// Since Trust Score v2 this is no longer the headline score — it survives
  /// as the ancestor of [TrustBreakdown.reviewScore], one of four weighted
  /// sub-scores blended by [trustBreakdownFor].
  static int trustScoreFor({required int ratingSum, required int ratingCount}) {
    final weighted = (trustPriorWeight * trustPriorMean + ratingSum) /
        (trustPriorWeight + ratingCount);
    return (weighted / 5 * 1000).round().clamp(0, 1000);
  }

  // -------------------------------------------------------------------------
  // Trust Score v2 — a multi-signal composite. The authoritative computation
  // runs in Cloud Functions (functions/index.js `computeTrust`, kept in sync
  // with this file via test/fixtures/trust_vectors.json); this Dart mirror
  // exists for tests and documentation. Weights are integer percents so both
  // languages share exact integer arithmetic (no float drift at .5 rounding).
  // -------------------------------------------------------------------------

  /// Sub-score weights (percent, summing to 100).
  static const int reviewWeightPct = 45;
  static const int trackRecordWeightPct = 25;
  static const int verificationWeightPct = 20;
  static const int profileWeightPct = 10;

  /// Track record: +[trackRecordPerJob] per completed job, capped at
  /// [trackRecordJobCap] jobs; −[disputeLostPenalty] per dispute lost.
  static const int trackRecordPerJob = 10;
  static const int trackRecordJobCap = 10;
  static const int disputeLostPenalty = 20;

  /// Verification sub-score while an application awaits admin review.
  static const int verificationPendingScore = 40;

  /// The score stays hidden ("New Provider") until the user is admin-approved
  /// AND has this many completed jobs (Upwork/Fiverr-style earned visibility).
  static const int minJobsForVisibleScore = 3;

  /// Computes the full v2 trust breakdown. Mirrors `computeTrust` in
  /// functions/index.js — change both together and extend the shared vectors
  /// in test/fixtures/trust_vectors.json.
  static TrustBreakdown trustBreakdownFor({
    required int ratingSum,
    required int ratingCount,
    required String verificationStatus,
    required int jobsCompleted,
    required int disputesLost,
    required bool hasDisplayName,
    required bool hasPhone,
    required bool hasBio,
    required bool hasPhoto,
    required bool hasLocation,
  }) {
    final weighted = (trustPriorWeight * trustPriorMean + ratingSum) /
        (trustPriorWeight + ratingCount);
    final reviewScore = (weighted / 5 * 100).round().clamp(0, 100);

    final cappedJobs =
        jobsCompleted > trackRecordJobCap ? trackRecordJobCap : jobsCompleted;
    final trackRecordScore = (trackRecordPerJob * cappedJobs -
            disputeLostPenalty * disputesLost)
        .clamp(0, 100);

    final verificationScore = switch (verificationStatus) {
      'approved' => 100,
      'pending' => verificationPendingScore,
      _ => 0,
    };

    final profileScore = 20 *
        [hasDisplayName, hasPhone, hasBio, hasPhoto, hasLocation]
            .where((f) => f)
            .length;

    // Integer-exact: weights are percents, sub-scores 0–100, so the weighted
    // sum is composite*10 and only ever needs a .5-up division.
    final composite = ((reviewWeightPct * reviewScore +
                trackRecordWeightPct * trackRecordScore +
                verificationWeightPct * verificationScore +
                profileWeightPct * profileScore) /
            10)
        .round()
        .clamp(0, 1000);

    return TrustBreakdown(
      reviewScore: reviewScore,
      trackRecordScore: trackRecordScore,
      verificationScore: verificationScore,
      profileScore: profileScore,
      composite: composite,
      scoreVisible: verificationStatus == 'approved' &&
          jobsCompleted >= minJobsForVisibleScore,
    );
  }
}

/// The four v2 trust sub-scores (0–100 each), their weighted composite
/// (0–1000, stored as `trustScore`), and whether the score has been earned
/// enough to display. Server-computed; the client only ever reads it.
class TrustBreakdown {
  const TrustBreakdown({
    required this.reviewScore,
    required this.trackRecordScore,
    required this.verificationScore,
    required this.profileScore,
    required this.composite,
    required this.scoreVisible,
  });

  final int reviewScore;
  final int trackRecordScore;
  final int verificationScore;
  final int profileScore;
  final int composite;
  final bool scoreVisible;

  /// Parses the `trust` map stored on users/{uid}, or a conservative default
  /// (hidden, all zeros) when the server hasn't computed one yet.
  factory TrustBreakdown.fromMap(Map<String, dynamic>? m) => TrustBreakdown(
        reviewScore: (m?['reviewScore'] as num?)?.toInt() ?? 0,
        trackRecordScore: (m?['trackRecordScore'] as num?)?.toInt() ?? 0,
        verificationScore: (m?['verificationScore'] as num?)?.toInt() ?? 0,
        profileScore: (m?['profileScore'] as num?)?.toInt() ?? 0,
        composite: (m?['composite'] as num?)?.toInt() ?? 0,
        scoreVisible: m?['scoreVisible'] as bool? ?? false,
      );
}
