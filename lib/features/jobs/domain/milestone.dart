/// Lifecycle of an escrow milestone. Jobs are funded at award, so new stages
/// start `funded`. `proposed`, `pending` and `resolved` are legacy statuses of
/// the removed plan flow, kept only so old documents still decode and display.
enum MilestoneStatus {
  proposed,
  pending,
  funded,
  submitted,
  released,
  disputed,
  resolved,

  /// Money went back to the client after a dispute ended the job.
  refunded;

  String get storage => switch (this) {
    MilestoneStatus.proposed => 'proposed',
    MilestoneStatus.pending => 'pending',
    MilestoneStatus.funded => 'funded',
    MilestoneStatus.submitted => 'submitted',
    MilestoneStatus.released => 'released',
    MilestoneStatus.disputed => 'disputed',
    MilestoneStatus.resolved => 'resolved',
    MilestoneStatus.refunded => 'refunded',
  };

  String get label => switch (this) {
    MilestoneStatus.proposed => 'Awaiting client approval',
    MilestoneStatus.pending => 'Not funded yet',
    MilestoneStatus.funded => 'In escrow',
    MilestoneStatus.submitted => 'Delivered, awaiting release',
    MilestoneStatus.released => 'Paid out',
    MilestoneStatus.disputed => 'Disputed, on hold',
    MilestoneStatus.resolved => 'Resolved',
    MilestoneStatus.refunded => 'Refunded to client',
  };

  static MilestoneStatus fromStorage(String? value) => switch (value) {
    'proposed' => MilestoneStatus.proposed,
    'pending' => MilestoneStatus.pending,
    'funded' => MilestoneStatus.funded,
    'submitted' => MilestoneStatus.submitted,
    'released' => MilestoneStatus.released,
    'disputed' => MilestoneStatus.disputed,
    'resolved' => MilestoneStatus.resolved,
    'refunded' => MilestoneStatus.refunded,
    _ => MilestoneStatus.proposed,
  };
}

/// One escrow milestone of a job, stored at `jobs/{jobId}/milestones/{id}`.
/// Created funded at award; the provider delivers and the requestor releases
/// them (via Cloud Functions - see MilestoneRepository). Framework-agnostic - the
/// repository handles the Firestore ↔ [Milestone] mapping.
class Milestone {
  const Milestone({
    required this.id,
    required this.jobId,
    required this.providerId,
    required this.description,
    required this.amountSen,
    this.order = 0,
    this.status = MilestoneStatus.proposed,
    this.submissionNote,
    this.reworkNote,
    this.reworkCount = 0,
    this.disputedBy,
    this.createdAt,
  });

  /// The document's id (its path, not a stored field). Empty for a milestone
  /// that has not been written yet.
  final String id;

  /// The parent job's id (the doc's path, not a stored field).
  final String jobId;

  /// The accepted provider, denormalised so the Earnings screen can query the
  /// provider's milestones across jobs with one collection-group query (same
  /// pattern as a bid's `providerId`).
  final String providerId;

  final String description;
  final int amountSen;

  /// Position among the job's stages (0-based) - they can share a server
  /// timestamp, so this keeps their order stable.
  final int order;

  final MilestoneStatus status;

  /// Optional note from the provider, set when they mark it delivered.
  final String? submissionNote;

  /// The admin's ruling note, copied here when a dispute is refunded and this
  /// milestone is reopened for rework, so the provider sees why.
  final String? reworkNote;

  /// How many times this milestone has been sent back for rework via a
  /// refunded dispute. 0 for a milestone that has never been disputed.
  final int reworkCount;

  /// Uid of whoever raised the open dispute, so only they can withdraw it.
  final String? disputedBy;

  final DateTime? createdAt;

  /// Fields written to Firestore. `status`/`createdAt` for a new milestone are
  /// set by the repository, so they are omitted here.
  Map<String, dynamic> toMap() => {
    'providerId': providerId,
    'description': description,
    'amountSen': amountSen,
    'order': order,
  };

  /// Builds a [Milestone] from its job id, doc id and (already
  /// Timestamp-normalised) data map.
  factory Milestone.fromMap(String jobId, String id, Map<String, dynamic> m) =>
      Milestone(
        id: id,
        jobId: jobId,
        providerId: m['providerId'] as String? ?? '',
        description: m['description'] as String? ?? '',
        amountSen: (m['amountSen'] as num?)?.toInt() ?? 0,
        order: (m['order'] as num?)?.toInt() ?? 0,
        status: MilestoneStatus.fromStorage(m['status'] as String?),
        submissionNote: m['submissionNote'] as String?,
        reworkNote: m['reworkNote'] as String?,
        reworkCount: (m['reworkCount'] as num?)?.toInt() ?? 0,
        disputedBy: m['disputedBy'] as String?,
        createdAt: m['createdAt'] as DateTime?,
      );
}
