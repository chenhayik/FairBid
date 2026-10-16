/// What:   Dispute lifecycle state.
/// Input:  The `status` field of `disputes/{id}` via DisputeStatus.fromStorage().
/// Output: Open until an admin rules (resolved) or the raiser withdraws (withdrawn).
enum DisputeStatus {
  open,
  resolved,
  withdrawn;

  String get storage => name;

  static DisputeStatus fromStorage(String? value) =>
      values.asNameMap()[value] ?? DisputeStatus.open;
}

/// What:   The admin's ruling on a dispute.
/// Input:  Chosen in DisputeDetailScreen; sent to DisputeRepository.resolveDispute().
/// Output: `release` pays the escrow to the provider; `refund` returns it to the requestor.
enum DisputeResolution {
  release,
  refund;

  String get storage => name;
}

/// What:   One dispute over a funded or delivered milestone.
/// Input:  `disputes/{disputeId}` via Dispute.fromMap (dispute_repository.dart).
/// Output: Read-only model; the dispute Cloud Functions own every write.
class Dispute {
  const Dispute({
    required this.id,
    required this.jobId,
    required this.jobTitle,
    required this.milestoneId,
    required this.milestoneDescription,
    required this.amountSen,
    required this.raisedByRole,
    required this.providerId,
    required this.statement,
    this.evidenceUrls = const [],
    this.status = DisputeStatus.open,
    this.createdAt,
  });

  final String id;
  final String jobId;
  final String jobTitle;
  final String milestoneId;
  final String milestoneDescription;

  /// Escrowed amount in dispute, in sen.
  final int amountSen;

  /// `'requestor'` or `'provider'`.
  final String raisedByRole;

  final String providerId;

  final String statement;

  /// Photo evidence download URLs.
  final List<String> evidenceUrls;

  final DisputeStatus status;
  final DateTime? createdAt;

  /// The job's chat thread id (`{jobId}_{providerId}`).
  String get conversationId => '${jobId}_$providerId';

  String get raisedByLabel =>
      raisedByRole == 'provider' ? 'Provider' : 'Client';

  factory Dispute.fromMap(String id, Map<String, dynamic> m) => Dispute(
        id: id,
        jobId: m['jobId'] as String? ?? '',
        jobTitle: m['jobTitle'] as String? ?? '',
        milestoneId: m['milestoneId'] as String? ?? '',
        milestoneDescription: m['milestoneDescription'] as String? ?? '',
        amountSen: (m['amountSen'] as num?)?.toInt() ?? 0,
        raisedByRole: m['raisedByRole'] as String? ?? 'requestor',
        providerId: m['providerId'] as String? ?? '',
        statement: m['statement'] as String? ?? '',
        evidenceUrls:
            (m['evidenceUrls'] as List?)?.whereType<String>().toList() ??
                const [],
        status: DisputeStatus.fromStorage(m['status'] as String?),
        createdAt: m['createdAt'] as DateTime?,
      );
}
