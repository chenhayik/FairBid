/// What:   Lifecycle of a bid.
/// Input:  Stored `status` string via [fromStorage]; unknown values read as pending.
/// Output: pending, accepted, rejected or withdrawn, with a display [label].
enum BidStatus {
  pending,
  accepted,
  rejected,
  withdrawn;

  String get storage => name;

  String get label => switch (this) {
        BidStatus.pending => 'Pending',
        BidStatus.accepted => 'Accepted',
        BidStatus.rejected => 'Rejected',
        BidStatus.withdrawn => 'Withdrawn',
      };

  static BidStatus fromStorage(String? value) =>
      values.asNameMap()[value] ?? BidStatus.pending;
}

/// What:   A provider's offer on a job (`jobs/{jobId}/bids/{providerId}`).
/// Input:  Firestore data via FirestoreBidRepository (bid_repository.dart).
/// Output: Immutable model; the uid doc id gives one bid per provider per job.
class Bid {
  const Bid({
    required this.jobId,
    required this.providerId,
    required this.providerName,
    this.providerPhotoUrl,
    this.providerTrustScore = 0,
    this.providerScoreVisible = true,
    required this.amountSen,
    required this.estimatedDuration,
    this.message = '',
    this.status = BidStatus.pending,
    this.createdAt,
  });

  /// What:   Copy of the bid with the provider's current score.
  /// Input:  [trustScore] and [scoreVisible] from the provider's profile.
  /// Output: New Bid; the bid-time snapshot is stale for ranking.
  Bid withTrust({required int trustScore, required bool scoreVisible}) => Bid(
        jobId: jobId,
        providerId: providerId,
        providerName: providerName,
        providerPhotoUrl: providerPhotoUrl,
        providerTrustScore: trustScore,
        providerScoreVisible: scoreVisible,
        amountSen: amountSen,
        estimatedDuration: estimatedDuration,
        message: message,
        status: status,
        createdAt: createdAt,
      );

  /// From the doc path, not a stored field.
  final String jobId;
  final String providerId;
  final String providerName;

  /// Photo at bid time, denormalised so the requestor sees a face without extra reads.
  final String? providerPhotoUrl;

  /// Trust Score (0-1000) at bid time.
  final int providerTrustScore;

  /// False shows "New provider" instead of the number; the score still feeds Best Value.
  final bool providerScoreVisible;

  final int amountSen;

  /// Human label, e.g. 'Less than 1 week'.
  final String estimatedDuration;
  final String message;
  final BidStatus status;
  final DateTime? createdAt;

  /// What:   Fields the client writes.
  /// Output: Map without `status` and `createdAt`; the repository sets those.
  Map<String, dynamic> toMap() => {
        'providerId': providerId,
        'providerName': providerName,
        if (providerPhotoUrl != null) 'providerPhotoUrl': providerPhotoUrl,
        'providerTrustScore': providerTrustScore,
        'providerScoreVisible': providerScoreVisible,
        'amountSen': amountSen,
        'estimatedDuration': estimatedDuration,
        'message': message,
      };

  factory Bid.fromMap(String jobId, String providerId, Map<String, dynamic> m) =>
      Bid(
        jobId: jobId,
        providerId: providerId,
        providerName: m['providerName'] as String? ?? 'Provider',
        providerPhotoUrl: m['providerPhotoUrl'] as String?,
        providerTrustScore: (m['providerTrustScore'] as num?)?.toInt() ?? 0,
        // Older bids default to visible so established providers aren't labelled "New".
        providerScoreVisible: m['providerScoreVisible'] as bool? ?? true,
        amountSen: (m['amountSen'] as num?)?.toInt() ?? 0,
        estimatedDuration: m['estimatedDuration'] as String? ?? '',
        message: m['message'] as String? ?? '',
        status: BidStatus.fromStorage(m['status'] as String?),
        createdAt: m['createdAt'] as DateTime?,
      );
}
