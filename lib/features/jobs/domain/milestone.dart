/// Escrow stage lifecycle. New stages start `funded`; `proposed`, `pending` and
/// `resolved` are legacy values kept so old documents still decode.
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

  String get storage => name;

  /// Money has finished moving: paid out, or the legacy `resolved` alias.
  bool get isTerminal => this == released || this == resolved || this == refunded;

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

  static MilestoneStatus fromStorage(String? value) =>
      values.asNameMap()[value] ?? MilestoneStatus.proposed;
}

/// What:   One escrow stage of a job (`jobs/{jobId}/milestones/{id}`).
/// Input:  Firestore data via FirestoreMilestoneRepository (milestone_repository.dart).
/// Output: Immutable model; created funded at award, the provider delivers, the requestor releases.
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
    this.disputedBy,
    this.createdAt,
  });

  /// Empty until written.
  final String id;

  /// From the doc path, not a stored field.
  final String jobId;

  /// Denormalised so Earnings can query a provider's stages across jobs.
  final String providerId;

  final String description;
  final int amountSen;

  /// 0-based position; stages can share a timestamp, so this keeps order stable.
  final int order;

  final MilestoneStatus status;

  /// Optional note from the provider, set when they mark it delivered.
  final String? submissionNote;

  /// Admin note on older refunds that sent the stage back for rework.
  final String? reworkNote;

  /// Uid of whoever raised the open dispute, so only they can withdraw it.
  final String? disputedBy;

  final DateTime? createdAt;

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
        disputedBy: m['disputedBy'] as String?,
        createdAt: m['createdAt'] as DateTime?,
      );
}

/// What:   The stage that is dominant right now (shared by the tracker and the bottom bar).
/// Input:  A job's [milestones] in order.
/// Output: The disputed stage if any, else the first non-terminal one, else null.
Milestone? currentStage(List<Milestone> milestones) =>
    milestones.where((m) => m.status == MilestoneStatus.disputed).firstOrNull ??
    milestones.where((m) => !m.status.isTerminal).firstOrNull;
