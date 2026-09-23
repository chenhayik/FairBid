/// Lifecycle of a provider's package bid on a bundle. Mirrors `BidStatus`
/// (see `bid.dart`) with one extra state: `awardBundle` may accept some of a
/// bid's tasks and reject the rest when the bid isn't all-or-nothing, which
/// a plain accepted/rejected pair can't represent.
enum BundleBidStatus {
  pending,
  accepted,
  partlyAccepted,
  rejected,
  withdrawn;

  String get storage => switch (this) {
        BundleBidStatus.pending => 'pending',
        BundleBidStatus.accepted => 'accepted',
        BundleBidStatus.partlyAccepted => 'partly_accepted',
        BundleBidStatus.rejected => 'rejected',
        BundleBidStatus.withdrawn => 'withdrawn',
      };

  String get label => switch (this) {
        BundleBidStatus.pending => 'Pending',
        BundleBidStatus.accepted => 'Accepted',
        BundleBidStatus.partlyAccepted => 'Partly accepted',
        BundleBidStatus.rejected => 'Rejected',
        BundleBidStatus.withdrawn => 'Withdrawn',
      };

  static BundleBidStatus fromStorage(String? value) => switch (value) {
        'accepted' => BundleBidStatus.accepted,
        'partly_accepted' => BundleBidStatus.partlyAccepted,
        'rejected' => BundleBidStatus.rejected,
        'withdrawn' => BundleBidStatus.withdrawn,
        _ => BundleBidStatus.pending,
      };
}

/// A provider's package bid on a bundle. Stored at
/// `bundles/{bundleId}/bundleBids/{providerId}` - the provider's uid as the
/// doc id enforces one bid per provider per bundle, exactly like `Bid` on a
/// single job (see `bid.dart`). Framework-agnostic; the repository handles
/// Firestore ↔ [BundleBid] mapping.
///
/// Has no `toMap()`: unlike a plain job bid, the client never writes this
/// document directly. `firestore.rules` denies every client write to
/// `bundleBids`, so the write goes through the `submitBundleBid` Cloud
/// Function, which also stamps the provider's name/photo/Trust Score itself -
/// the map's prices need server-side validation a rule can't express, since
/// the rules language cannot walk a map's entries.
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
    this.allOrNothing = false,
    required this.estimatedDuration,
    this.message = '',
    this.status = BundleBidStatus.pending,
    this.createdAt,
  });

  /// The parent bundle's id (the doc's path, not a stored field).
  final String bundleId;
  final String providerId;
  final String providerName;

  /// Snapshot of the provider's `profilePhotoUrl` at bid time - see
  /// `Bid.providerPhotoUrl` for why this is denormalised rather than read
  /// live from the profile.
  final String? providerPhotoUrl;

  /// Snapshot of the provider's Trust Score (0–1000) at bid time.
  final int providerTrustScore;

  /// Snapshot of whether the provider had earned a visible score at bid time.
  final bool providerScoreVisible;

  /// The provider's price for each task they picked, keyed by job id -
  /// "price if you get only this task". A subset of the bundle's task ids:
  /// providers may bid on any subset, so this is never assumed to cover
  /// every task in the bundle.
  final Map<String, int> taskPrices;

  /// Optional lower total charged instead of the sum of [taskPrices], but
  /// only if the provider wins every task in this bid. Null when the
  /// provider didn't offer one.
  final int? bundlePriceSen;

  /// When true, the requestor may award all of this bid's tasks or none of
  /// them - never a subset.
  final bool allOrNothing;

  /// Human label, e.g. 'Less than 1 week'.
  final String estimatedDuration;
  final String message;
  final BundleBidStatus status;
  final DateTime? createdAt;

  /// How many tasks this bid covers.
  int get taskCount => taskPrices.length;

  /// Sum of the individual task prices - what the provider charges if the
  /// award splits this bid across its tasks (or it never offered a bundle
  /// price at all).
  int get taskTotalSen =>
      taskPrices.values.fold(0, (sum, price) => sum + price);

  /// What the provider charges if they win every task in this bid: the
  /// bundle price when offered, otherwise the sum of the task prices.
  int get quotedTotalSen => bundlePriceSen ?? taskTotalSen;

  /// Whether this bid includes a price for [jobId].
  bool coversTask(String jobId) => taskPrices.containsKey(jobId);

  /// The price offered for [jobId], or null when this bid doesn't cover it.
  int? priceFor(String jobId) => taskPrices[jobId];

  /// Builds a [BundleBid] from its bundle id, doc id (the provider's uid)
  /// and (already Timestamp-normalised) data map.
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
      allOrNothing: m['allOrNothing'] as bool? ?? false,
      estimatedDuration: m['estimatedDuration'] as String? ?? '',
      message: m['message'] as String? ?? '',
      status: BundleBidStatus.fromStorage(m['status'] as String?),
      createdAt: m['createdAt'] as DateTime?,
    );
  }
}
