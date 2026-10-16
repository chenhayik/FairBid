import 'job.dart';

/// What:   Lifecycle of a bundle.
/// Input:  Stored `status` string via [fromStorage]; unknown values read as open.
/// Output: open, awarded, cancelled or expired, with a display [label].
enum BundleStatus {
  open,
  awarded,
  cancelled,
  expired;

  String get label => switch (this) {
    BundleStatus.open => 'Open',
    BundleStatus.awarded => 'Awarded',
    BundleStatus.cancelled => 'Cancelled',
    BundleStatus.expired => 'Expired',
  };

  static BundleStatus fromStorage(String? value) =>
      values.asNameMap()[value] ?? BundleStatus.open;
}

/// What:   A bundled posting of several tasks (one doc in `bundles`).
/// Input:  Firestore data via FirestoreBundleRepository (bundle_repository.dart).
/// Output: Immutable model; tasks are jobs that carry its `bundleId`.
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

  final DateTime? createdAt;
  final DateTime? deadline;

  int get taskCount => taskIds.length;

  /// What:   Whether providers can still bid on the bundle.
  /// Output: True while status is open and the deadline (if any) hasn't passed.
  bool get biddingOpen =>
      status == BundleStatus.open &&
      (deadline == null || DateTime.now().isBefore(deadline!));

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
    createdAt: m['createdAt'] as DateTime?,
    deadline: m['deadline'] as DateTime?,
  );
}

/// What:   One task of a bundle being created.
/// Input:  Post-a-Job form fields.
/// Output: [toMap] for the `createBundle` callable.
class BundleTaskDraft {
  const BundleTaskDraft({
    required this.title,
    required this.description,
    required this.category,
    this.budget,
    this.photoIndexes = const [],
  });

  final String title;
  final String description;
  final String category;
  final JobBudget? budget;

  /// Positions in the bundle's photo list that belong to this task.
  final List<int> photoIndexes;

  Map<String, dynamic> toMap() => {
    'title': title,
    'description': description,
    'category': category,
    if (budget?.minSen != null) 'budgetMinSen': budget?.minSen,
    if (budget?.maxSen != null) 'budgetMaxSen': budget?.maxSen,
    if (budget?.hourly == true) 'hourly': true,
    if (photoIndexes.isNotEmpty) 'photoIndexes': photoIndexes,
  };
}
