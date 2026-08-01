/// Lifecycle of a bid on a job.
enum BidStatus {
  pending,
  accepted,
  rejected,
  withdrawn;

  String get storage => switch (this) {
        BidStatus.pending => 'pending',
        BidStatus.accepted => 'accepted',
        BidStatus.rejected => 'rejected',
        BidStatus.withdrawn => 'withdrawn',
      };

  String get label => switch (this) {
        BidStatus.pending => 'Pending',
        BidStatus.accepted => 'Accepted',
        BidStatus.rejected => 'Rejected',
        BidStatus.withdrawn => 'Withdrawn',
      };

  static BidStatus fromStorage(String? value) => switch (value) {
        'accepted' => BidStatus.accepted,
        'rejected' => BidStatus.rejected,
        'withdrawn' => BidStatus.withdrawn,
        _ => BidStatus.pending,
      };
}

/// A provider's offer on a job. Stored at `jobs/{jobId}/bids/{providerId}` —
/// the provider's uid as the doc id enforces one bid per provider per job.
/// Framework-agnostic; the repository handles Firestore ↔ [Bid] mapping.
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

  /// The parent job's id (the doc's path, not a stored field).
  final String jobId;
  final String providerId;
  final String providerName;

  /// Snapshot of the provider's `profilePhotoUrl` at bid time, denormalised
  /// so the requestor sees a face without loading each provider's profile —
  /// mirrors how [providerName]/[providerTrustScore] are already denormalised.
  /// Null if the provider had no photo when they bid. A future Cloud Function
  /// could refresh this snapshot if the provider later changes their photo.
  final String? providerPhotoUrl;

  /// Snapshot of the provider's Trust Score (0–1000) at bid time, denormalised
  /// so the requestor can sort bids without loading each provider profile.
  final int providerTrustScore;

  /// Snapshot of whether the provider had earned a visible score at bid time.
  /// When false the card shows a "New provider" state instead of the number
  /// (the score still feeds Best Value ranking either way).
  final bool providerScoreVisible;

  final int amountSen;

  /// Human label, e.g. 'Less than 1 week'.
  final String estimatedDuration;
  final String message;
  final BidStatus status;
  final DateTime? createdAt;

  /// Fields written to Firestore. `status`/`createdAt` for a new bid are set
  /// by the repository, so they are omitted here.
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

  /// Builds a [Bid] from its job id, doc id and (already
  /// Timestamp-normalised) data map.
  factory Bid.fromMap(String jobId, String providerId, Map<String, dynamic> m) =>
      Bid(
        jobId: jobId,
        providerId: providerId,
        providerName: m['providerName'] as String? ?? 'Provider',
        providerPhotoUrl: m['providerPhotoUrl'] as String?,
        providerTrustScore: (m['providerTrustScore'] as num?)?.toInt() ?? 0,
        // Legacy bids (pre-v2) default to visible so established providers
        // aren't mislabelled "New".
        providerScoreVisible: m['providerScoreVisible'] as bool? ?? true,
        amountSen: (m['amountSen'] as num?)?.toInt() ?? 0,
        estimatedDuration: m['estimatedDuration'] as String? ?? '',
        message: m['message'] as String? ?? '',
        status: BidStatus.fromStorage(m['status'] as String?),
        createdAt: m['createdAt'] as DateTime?,
      );
}
