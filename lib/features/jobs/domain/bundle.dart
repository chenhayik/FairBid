import 'job.dart';

enum BundleStatus {
  open,
  awarded,
  cancelled,
  expired;

  String get storage => switch (this) {
    BundleStatus.open => 'open',
    BundleStatus.awarded => 'awarded',
    BundleStatus.cancelled => 'cancelled',
    BundleStatus.expired => 'expired',
  };

  String get label => switch (this) {
    BundleStatus.open => 'Open',
    BundleStatus.awarded => 'Awarded',
    BundleStatus.cancelled => 'Cancelled',
    BundleStatus.expired => 'Expired',
  };

  static BundleStatus fromStorage(String? value) => switch (value) {
    'awarded' => BundleStatus.awarded,
    'cancelled' => BundleStatus.cancelled,
    'expired' => BundleStatus.expired,
    _ => BundleStatus.open,
  };
}

class Bundle {
  const Bundle({
    required this.id,
    required this.requestorId,
    required this.requestorName,
    this.requestorPhotoUrl,
    required this.title,
    required this.description,
    required this.location,
    this.photoUrls = const [],
    this.status = BundleStatus.open,
    this.taskIds = const [],
    this.consolidationCapPct = 0,
    this.consolidationCapSen = 0,
    this.createdAt,
    this.deadline,
  });

  final String id;
  final String requestorId;
  final String requestorName;
  final String? requestorPhotoUrl;
  final String title;
  final String description;

  final JobLocation location;
  final List<String> photoUrls;
  final BundleStatus status;

  final List<String> taskIds;

  final int consolidationCapPct;
  final int consolidationCapSen;

  final DateTime? createdAt;
  final DateTime? deadline;

  int get taskCount => taskIds.length;

  bool get biddingOpen =>
      status == BundleStatus.open &&
      (deadline == null || DateTime.now().isBefore(deadline!));

  // Builds a Bundle from its document id and data map.
  factory Bundle.fromMap(String id, Map<String, dynamic> m) => Bundle(
    id: id,
    requestorId: m['requestorId'] as String? ?? '',
    requestorName: m['requestorName'] as String? ?? 'Requestor',
    requestorPhotoUrl: m['requestorPhotoUrl'] as String?,
    title: m['title'] as String? ?? '',
    description: m['description'] as String? ?? '',
    location: JobLocation.fromMap(m['location'] as Map<String, dynamic>?),
    photoUrls:
        (m['photoUrls'] as List?)?.whereType<String>().toList() ?? const [],
    status: BundleStatus.fromStorage(m['status'] as String?),
    taskIds: (m['taskIds'] as List?)?.whereType<String>().toList() ?? const [],
    consolidationCapPct: (m['consolidationCapPct'] as num?)?.toInt() ?? 0,
    consolidationCapSen: (m['consolidationCapSen'] as num?)?.toInt() ?? 0,
    createdAt: m['createdAt'] as DateTime?,
    deadline: m['deadline'] as DateTime?,
  );
}

class BundleTaskDraft {
  const BundleTaskDraft({
    required this.title,
    required this.description,
    required this.category,
    this.budget,
    this.lotId,
    this.startsAfterIndex,
    this.gapDays,
  });

  final String title;
  final String description;
  final String category;
  final JobBudget? budget;

  // Tasks sharing a lotId are bid on and awarded together.
  final String? lotId;

  // Which earlier task this one follows; null if it can start anytime.
  final int? startsAfterIndex;

  // Days to wait after that earlier task completes before this one starts.
  final int? gapDays;

  Map<String, dynamic> toMap() => {
    'title': title,
    'description': description,
    'category': category,
    if (budget?.minSen != null) 'budgetMinSen': budget?.minSen,
    if (budget?.maxSen != null) 'budgetMaxSen': budget?.maxSen,
    if (budget?.hourly == true) 'hourly': true,
    if (lotId != null) 'lotId': lotId,
    if (startsAfterIndex != null) 'startsAfterIndex': startsAfterIndex,
    if (gapDays != null) 'gapDays': gapDays,
  };
}
