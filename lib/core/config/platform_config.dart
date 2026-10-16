/// What:   Platform-wide tunables (bid ranking, Trust Score, caps) in one place.
/// Input:  Compile-time constants; some mirror Cloud Functions values noted per field.
/// Output: Constants plus the Dart mirror [trustBreakdownFor] that tests pin.
class PlatformConfig {
  const PlatformConfig._();

  /// Whether the wallet shows the demo top-up; off unless built with `--dart-define=FAIRBID_DEMO_TOPUP=true`.
  /// Not `kDebugMode`: debug builds still hit the real project, whose `topUpWallet` gate is emulator-only.
  /// This only hides the button; the server gate is the real control.
  static const bool demoTopUpEnabled =
      bool.fromEnvironment('FAIRBID_DEMO_TOPUP');

  /// "Best Value" weights (sum 1) for the normalised price and trust scores.
  static const double priceWeight = 0.6;
  static const double trustWeight = 0.4;

  /// Ranking score for a provider whose Trust Score is hidden ("New"), so hidden scores never decide a rank.
  static const int neutralTrustScore = 700;

  /// Highest bid or bundle bid total (RM 50,000); no wallet can fund more.
  static const int maxBidSen = maxWalletBalanceSen;

  /// Per-top-up cap (RM 10,000); `topUpWallet` keeps its own copy.
  static const int maxTopUpSen = 1000000;

  /// Wallet balance cap (RM 50,000); `topUpWallet` keeps its own copy.
  static const int maxWalletBalanceSen = 5000000;

  /// Max tasks in a bundle; `createBundle` keeps its own copy.
  static const int maxBundleTasks = 6;

  /// The fewest-providers bundle option beats the cheapest only if it costs at most
  /// [consolidationCapPct]% and [consolidationCapSen] (RM 500) more (the smaller limit wins). `createBundle` keeps its own copy.
  static const int consolidationCapPct = 5;
  static const int consolidationCapSen = 50000; // RM 500

  /// Bayesian priors: a new provider starts as if they had [trustPriorWeight] reviews averaging [trustPriorMean] stars.
  static const double trustPriorMean = 3.5;
  static const int trustPriorWeight = 10;

  // Trust Score v2. The authoritative computation is `computeTrust` in Cloud Functions (kept in sync via
  // test/fixtures/trust_vectors.json); this is a mirror. Integer percents keep both languages exact at .5 rounding.

  /// Sub-score weights (percent, sum 100).
  static const int reviewWeightPct = 45;
  static const int trackRecordWeightPct = 25;
  static const int verificationWeightPct = 20;
  static const int profileWeightPct = 10;

  /// Track record: +[trackRecordPerJob] per completed job up to [trackRecordJobCap]; -[disputeLostPenalty] per dispute lost.
  static const int trackRecordPerJob = 10;
  static const int trackRecordJobCap = 10;
  static const int disputeLostPenalty = 10;

  /// Verification sub-score while awaiting admin review.
  static const int verificationPendingScore = 40;

  /// The score stays "New" until admin-approved and this many jobs are completed.
  static const int minJobsForVisibleScore = 3;

  /// What:   Full v2 trust breakdown for one user.
  /// Input:  Rating sum/count, verification status, job and dispute counts and profile-completeness flags from the user doc.
  /// Output: TrustBreakdown (sub-scores 0-100, composite 0-1000, visibility).
  /// How:    Reviews use a Bayesian average; track record is per-job points (capped) minus lost-dispute penalty;
  ///         composite is the weighted sum of the four sub-scores.
  /// Notes:  Mirrors `computeTrust` in functions; change both and the shared vectors.
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

    // Integer-exact: the weighted sum is composite*10, needing only a .5-up division.
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

/// What:   The four v2 trust sub-scores (0-100), their composite (0-1000, stored as `trustScore`) and visibility.
/// Input:  The `trust` map on `users/{uid}`, server-computed.
/// Output: Read-only values; the client never computes them.
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

  /// Parses the map; a missing one gives hidden zeros.
  factory TrustBreakdown.fromMap(Map<String, dynamic>? m) => TrustBreakdown(
        reviewScore: (m?['reviewScore'] as num?)?.toInt() ?? 0,
        trackRecordScore: (m?['trackRecordScore'] as num?)?.toInt() ?? 0,
        verificationScore: (m?['verificationScore'] as num?)?.toInt() ?? 0,
        profileScore: (m?['profileScore'] as num?)?.toInt() ?? 0,
        composite: (m?['composite'] as num?)?.toInt() ?? 0,
        scoreVisible: m?['scoreVisible'] as bool? ?? false,
      );
}
