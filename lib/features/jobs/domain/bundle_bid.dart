/// What:   Package bid lifecycle.
/// Input:  Stored `status` string via [fromStorage]; unknown values read as pending.
/// Output: Like BidStatus plus partlyAccepted (some tasks won, the rest rejected) and closed (bundle cancelled while pending).
enum BundleBidStatus {
  pending,
  accepted,
  partlyAccepted,
  rejected,
  withdrawn,

  /// The bundle was cancelled while this bid was still pending.
  closed;

  String get storage => switch (this) {
    BundleBidStatus.pending => 'pending',
    BundleBidStatus.accepted => 'accepted',
    BundleBidStatus.partlyAccepted => 'partly_accepted',
    BundleBidStatus.rejected => 'rejected',
    BundleBidStatus.withdrawn => 'withdrawn',
    BundleBidStatus.closed => 'closed',
  };

  String get label => switch (this) {
    BundleBidStatus.pending => 'Pending',
    BundleBidStatus.accepted => 'Accepted',
    BundleBidStatus.partlyAccepted => 'Partly accepted',
    BundleBidStatus.rejected => 'Rejected',
    BundleBidStatus.withdrawn => 'Withdrawn',
    BundleBidStatus.closed => 'Closed',
  };

  static BundleBidStatus fromStorage(String? value) => switch (value) {
    'accepted' => BundleBidStatus.accepted,
    'partly_accepted' => BundleBidStatus.partlyAccepted,
    'rejected' => BundleBidStatus.rejected,
    'withdrawn' => BundleBidStatus.withdrawn,
    'closed' => BundleBidStatus.closed,
    _ => BundleBidStatus.pending,
  };
}

/// What:   A provider's package bid on a bundle (`bundles/{bundleId}/bundleBids/{providerId}`).
/// Input:  Firestore data via FirestoreBundleBidRepository (bundle_bid_repository.dart).
/// Output: Immutable model; the uid doc id gives one bid per provider per bundle.
/// Notes:  No toMap(): the `submitBundleBid` callable writes it (rules deny client writes).
class BundleBid {
  const BundleBid({
    required this.bundleId,
    required this.providerId,
    required this.providerName,
    this.providerPhotoUrl,
    this.providerTrustScore = 0,
    this.providerScoreVisible = true,
    required this.taskPrices,
    this.bundlePriceSen,
    required this.estimatedDuration,
    this.message = '',
    this.status = BundleBidStatus.pending,
    this.bundleTitle = 'Bundle',
    this.createdAt,
    this.updatedAt,
  });

  /// What:   Copy of the bid with the provider's current score.
  /// Input:  [trustScore] and [scoreVisible] from the provider's profile.
  /// Output: New BundleBid; the bid-time snapshot is stale for ranking.
  BundleBid withTrust({required int trustScore, required bool scoreVisible}) =>
      BundleBid(
        bundleId: bundleId,
        providerId: providerId,
        providerName: providerName,
        providerPhotoUrl: providerPhotoUrl,
        providerTrustScore: trustScore,
        providerScoreVisible: scoreVisible,
        taskPrices: taskPrices,
        bundlePriceSen: bundlePriceSen,
        estimatedDuration: estimatedDuration,
        message: message,
        status: status,
        bundleTitle: bundleTitle,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );

  /// From the doc path, not a stored field.
  final String bundleId;
  final String providerId;
  final String providerName;

  /// Photo at bid time (denormalised, as on Bid).
  final String? providerPhotoUrl;

  /// Trust Score (0-1000) at bid time.
  final int providerTrustScore;

  /// False shows "New provider" instead of the score.
  final bool providerScoreVisible;

  /// Price per picked task by job id ("price if you get only this task"); may be a subset.
  final Map<String, int> taskPrices;

  /// Optional lower total, charged only if the provider wins every task in the bid.
  final int? bundlePriceSen;

  /// Human label, e.g. 'Less than 1 week'.
  final String estimatedDuration;
  final String message;
  final BundleBidStatus status;

  /// Bundle title at bid time, so Pending Bids needs no second read.
  final String bundleTitle;
  final DateTime? createdAt;

  /// Moves on every submit or edit; [createdAt] stays fixed.
  final DateTime? updatedAt;

  /// What:   How many tasks this bid covers.
  int get taskCount => taskPrices.length;

  /// What:   Sum of the task prices.
  /// Notes:  Charged if the award splits this bid or no bundle price was offered.
  int get taskTotalSen =>
      taskPrices.values.fold(0, (sum, price) => sum + price);

  /// What:   What the provider charges if they win every task.
  /// Output: The bundle price, else [taskTotalSen].
  int get quotedTotalSen => bundlePriceSen ?? taskTotalSen;

  /// What:   Whether this bid prices the task [jobId].
  bool coversTask(String jobId) => taskPrices.containsKey(jobId);

  /// What:   Price offered for one task.
  /// Output: Sen, or null if not covered.
  int? priceFor(String jobId) => taskPrices[jobId];

  factory BundleBid.fromMap(
    String bundleId,
    String providerId,
    Map<String, dynamic> m,
  ) {
    final rawPrices = m['taskPrices'] as Map<String, dynamic>? ?? const {};
    final taskPrices = <String, int>{
      for (final entry in rawPrices.entries)
        if (entry.value is num) entry.key: (entry.value as num).toInt(),
    };
    return BundleBid(
      bundleId: bundleId,
      providerId: providerId,
      providerName: m['providerName'] as String? ?? 'Provider',
      providerPhotoUrl: m['providerPhotoUrl'] as String?,
      providerTrustScore: (m['providerTrustScore'] as num?)?.toInt() ?? 0,
      providerScoreVisible: m['providerScoreVisible'] as bool? ?? true,
      taskPrices: taskPrices,
      bundlePriceSen: (m['bundlePriceSen'] as num?)?.toInt(),
      estimatedDuration: m['estimatedDuration'] as String? ?? '',
      message: m['message'] as String? ?? '',
      status: BundleBidStatus.fromStorage(m['status'] as String?),
      bundleTitle: m['bundleTitle'] as String? ?? 'Bundle',
      createdAt: m['createdAt'] as DateTime?,
      updatedAt: m['updatedAt'] as DateTime?,
    );
  }
}
