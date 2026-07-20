/// Lifecycle of a dispute: open until an admin rules on it.
enum DisputeStatus {
  open,
  resolved;

  String get storage => name;

  String get label => switch (this) {
        DisputeStatus.open => 'Open',
        DisputeStatus.resolved => 'Resolved',
      };

  static DisputeStatus fromStorage(String? value) =>
      value == 'resolved' ? DisputeStatus.resolved : DisputeStatus.open;
}

/// The admin's ruling: release the escrowed amount to the provider, or refund
/// it to the requestor.
enum DisputeResolution {
  release,
  refund;

  String get storage => name;

  String get label => switch (this) {
        DisputeResolution.release => 'Released to provider',
        DisputeResolution.refund => 'Refunded to client',
      };

  static DisputeResolution? fromStorage(String? value) => switch (value) {
        'release' => DisputeResolution.release,
        'refund' => DisputeResolution.refund,
        _ => null,
      };
}

/// One dispute over a funded/delivered milestone, stored at
/// `disputes/{disputeId}`. Read-only on the client — the `raiseDispute` and
/// `resolveDispute` Cloud Functions own every write, so there is no `toMap()`
/// (same pattern as `LedgerEntry`).
class Dispute {
  const Dispute({
    required this.id,
    required this.jobId,
    required this.jobTitle,
    required this.milestoneId,
    required this.milestoneDescription,
    required this.amountSen,
    required this.raisedByUid,
    required this.raisedByRole,
    required this.requestorId,
    required this.providerId,
    required this.statement,
    this.evidenceUrls = const [],
    this.status = DisputeStatus.open,
    this.resolution,
    this.rulingNote,
    this.createdAt,
    this.resolvedAt,
  });

  final String id;
  final String jobId;
  final String jobTitle;
  final String milestoneId;
  final String milestoneDescription;

  /// The escrowed amount being disputed, in sen.
  final int amountSen;

  final String raisedByUid;

  /// `'requestor'` or `'provider'` — who opened the dispute.
  final String raisedByRole;

  final String requestorId;
  final String providerId;

  /// The raiser's account of the problem.
  final String statement;

  /// Optional photo evidence (Cloud Storage download URLs).
  final List<String> evidenceUrls;

  final DisputeStatus status;
  final DisputeResolution? resolution;

  /// The admin's note explaining the ruling.
  final String? rulingNote;

  final DateTime? createdAt;
  final DateTime? resolvedAt;

  /// The job's chat thread (`{jobId}_{providerId}`), reviewed by the admin.
  String get conversationId => '${jobId}_$providerId';

  /// UI label for who raised it.
  String get raisedByLabel =>
      raisedByRole == 'provider' ? 'Provider' : 'Client';

  /// Builds a [Dispute] from its doc id and (already Timestamp-normalised)
  /// data map.
  factory Dispute.fromMap(String id, Map<String, dynamic> m) => Dispute(
        id: id,
        jobId: m['jobId'] as String? ?? '',
        jobTitle: m['jobTitle'] as String? ?? '',
        milestoneId: m['milestoneId'] as String? ?? '',
        milestoneDescription: m['milestoneDescription'] as String? ?? '',
        amountSen: (m['amountSen'] as num?)?.toInt() ?? 0,
        raisedByUid: m['raisedByUid'] as String? ?? '',
        raisedByRole: m['raisedByRole'] as String? ?? 'requestor',
        requestorId: m['requestorId'] as String? ?? '',
        providerId: m['providerId'] as String? ?? '',
        statement: m['statement'] as String? ?? '',
        evidenceUrls:
            (m['evidenceUrls'] as List?)?.whereType<String>().toList() ??
                const [],
        status: DisputeStatus.fromStorage(m['status'] as String?),
        resolution: DisputeResolution.fromStorage(m['resolution'] as String?),
        rulingNote: m['rulingNote'] as String?,
        createdAt: m['createdAt'] as DateTime?,
        resolvedAt: m['resolvedAt'] as DateTime?,
      );
}
