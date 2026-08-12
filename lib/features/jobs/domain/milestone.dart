/// Lifecycle of an escrow milestone. A plan starts at `proposed` (the provider
/// splits the accepted bid) and only becomes fundable once the requestor
/// approves it, moving every milestone to `pending`. `resolved` is legacy: a
/// refunded dispute used to land here, but now returns the milestone to
/// `pending` for rework (see the `resolveDispute`/`isTerminal` Cloud
/// Functions); it is kept only so pre-existing documents still decode.
enum MilestoneStatus {
  proposed,
  pending,
  funded,
  submitted,
  released,
  disputed,
  resolved;

  String get storage => switch (this) {
    MilestoneStatus.proposed => 'proposed',
    MilestoneStatus.pending => 'pending',
    MilestoneStatus.funded => 'funded',
    MilestoneStatus.submitted => 'submitted',
    MilestoneStatus.released => 'released',
    MilestoneStatus.disputed => 'disputed',
    MilestoneStatus.resolved => 'resolved',
  };

  String get label => switch (this) {
    MilestoneStatus.proposed => 'Awaiting Client Approval',
    MilestoneStatus.pending => 'Not funded yet',
    MilestoneStatus.funded => 'In escrow',
    MilestoneStatus.submitted => 'Delivered, awaiting release',
    MilestoneStatus.released => 'Paid out',
    MilestoneStatus.disputed => 'Disputed, on hold',
    MilestoneStatus.resolved => 'Resolved',
  };

  static MilestoneStatus fromStorage(String? value) => switch (value) {
    'proposed' => MilestoneStatus.proposed,
    'pending' => MilestoneStatus.pending,
    'funded' => MilestoneStatus.funded,
    'submitted' => MilestoneStatus.submitted,
    'released' => MilestoneStatus.released,
    'disputed' => MilestoneStatus.disputed,
    'resolved' => MilestoneStatus.resolved,
    _ => MilestoneStatus.proposed,
  };
}

/// One escrow milestone of a job, stored at `jobs/{jobId}/milestones/{id}`.
/// The accepted provider proposes them; the requestor funds and releases them
/// (via Cloud Functions - see MilestoneRepository). Framework-agnostic - the
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

  /// Position in the proposed plan (0-based) - milestones in one plan share a
  /// server timestamp, so this keeps their order stable.
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
        createdAt: m['createdAt'] as DateTime?,
      );
}
