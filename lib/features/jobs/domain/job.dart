import '../../../core/util/money.dart';

/// Lifecycle of a job.
enum JobStatus {
  open,
  inProgress,
  completed,
  cancelled;

  String get storage => switch (this) {
        JobStatus.open => 'open',
        JobStatus.inProgress => 'in_progress',
        JobStatus.completed => 'completed',
        JobStatus.cancelled => 'cancelled',
      };

  String get label => switch (this) {
        JobStatus.open => 'Open',
        JobStatus.inProgress => 'In Progress',
        JobStatus.completed => 'Completed',
        JobStatus.cancelled => 'Cancelled',
      };

  static JobStatus fromStorage(String? value) => switch (value) {
        'in_progress' => JobStatus.inProgress,
        'completed' => JobStatus.completed,
        'cancelled' => JobStatus.cancelled,
        _ => JobStatus.open,
      };
}

/// A map-picked location: coordinates plus a human-readable label. [address]
/// is the composed `Region.label` for locations picked with the structured
/// picker, or a raw legacy string for older jobs that predate it - either way
/// it's always safe to display as-is. [districtCode]/[districtName]/[town]
/// are null on that legacy data.
class JobLocation {
  const JobLocation({
    required this.lat,
    required this.lng,
    required this.address,
    this.districtCode,
    this.districtName,
    this.town,
  });

  final double lat;
  final double lng;
  final String address;
  final String? districtCode;
  final String? districtName;
  final String? town;

  Map<String, dynamic> toMap() => {
        'lat': lat,
        'lng': lng,
        'address': address,
        'districtCode': districtCode,
        'districtName': districtName,
        'town': town,
      };

  static JobLocation fromMap(Map<String, dynamic>? m) => JobLocation(
        lat: (m?['lat'] as num?)?.toDouble() ?? 0,
        lng: (m?['lng'] as num?)?.toDouble() ?? 0,
        address: m?['address'] as String? ?? '',
        districtCode: m?['districtCode'] as String?,
        districtName: m?['districtName'] as String?,
        town: m?['town'] as String?,
      );
}

/// Optional budget: a fixed amount, a range, or an hourly rate. All in sen.
class JobBudget {
  const JobBudget({this.minSen, this.maxSen, this.hourly = false});

  final int? minSen;
  final int? maxSen;
  final bool hourly;

  bool get isEmpty => minSen == null && maxSen == null;

  /// Display string, e.g. `RM 100 – RM 250` or `RM 50/hr`.
  String? get label =>
      formatBudget(minSen: minSen, maxSen: maxSen, hourly: hourly);

  Map<String, dynamic> toMap() =>
      {'minSen': minSen, 'maxSen': maxSen, 'hourly': hourly};

  static JobBudget fromMap(Map<String, dynamic>? m) => JobBudget(
        minSen: (m?['minSen'] as num?)?.toInt(),
        maxSen: (m?['maxSen'] as num?)?.toInt(),
        hourly: m?['hourly'] as bool? ?? false,
      );
}

/// A job posted by a requestor. Framework-agnostic - the repository handles the
/// Firestore ↔ [Job] mapping (incl. Timestamp conversion).
class Job {
  const Job({
    required this.id,
    required this.requestorId,
    required this.requestorName,
    this.requestorPhotoUrl,
    required this.title,
    required this.description,
    required this.category,
    required this.location,
    this.budget,
    this.photoUrls = const [],
    this.videoUrl,
    this.status = JobStatus.open,
    this.bidCount = 0,
    this.createdAt,
    this.deadline,
    this.acceptedProviderId,
    this.acceptedProviderName,
    this.acceptedBidAmountSen,
    this.cancellationRequestedBy,
    this.cancellationReason,
    this.cancellationRequestedAt,
    this.cancelledAt,
    this.cancelledBy,
    this.planRejectionNote,
    this.bundleId,
    this.bundleOrder,
    this.lotId,
    this.startsAfterJobId,
    this.gapDays,
    this.bundleTaskCount,
  });

  final String id;
  final String requestorId;
  final String requestorName;

  /// Snapshot of the requestor's `profilePhotoUrl` at posting time,
  /// denormalised so providers see a face without loading the requestor's
  /// profile - mirrors how [requestorName] is already denormalised. Null if
  /// the requestor had no photo when they posted. A future Cloud Function
  /// could refresh this snapshot if the requestor later changes their photo.
  final String? requestorPhotoUrl;
  final String title;
  final String description;
  final String category;
  final JobLocation location;
  final JobBudget? budget;
  final List<String> photoUrls;

  /// One optional attached video (see `document_storage_repository.dart`'s
  /// `uploadJobVideo`); null when the requestor didn't add one.
  final String? videoUrl;
  final JobStatus status;
  final int bidCount;
  final DateTime? createdAt;
  final DateTime? deadline;

  /// Winner details, set when the requestor accepts a bid (null while open).
  final String? acceptedProviderId;
  final String? acceptedProviderName;
  final int? acceptedBidAmountSen;

  /// Pending mid-flight cancellation request. Either party may request; the
  /// counterparty accepts to finalise (the `requestJobCancellation` /
  /// `respondToJobCancellation` Cloud Functions). `'requestor'` or
  /// `'provider'`; null when no request is outstanding.
  final String? cancellationRequestedBy;
  final String? cancellationReason;
  final DateTime? cancellationRequestedAt;

  /// Set when the job is actually cancelled - the audit trail a bare status
  /// flip never had. `cancelledBy` is a uid, or `'admin'` for an admin
  /// override.
  final DateTime? cancelledAt;
  final String? cancelledBy;

  /// Whether a mid-flight cancellation is awaiting the counterparty's decision.
  bool get hasPendingCancellation => cancellationRequestedBy != null;

  /// The requestor's note when they sent a proposed milestone plan back for
  /// changes; null once the provider re-proposes.
  final String? planRejectionNote;

  final String? bundleId;

  /// The order of tasks within a bundle
  final int? bundleOrder;

  /// To identify and properly award the group of tasks to the correct
  /// provider
  final String? lotId;

  /// The id of the task (job) that must be completed before this one starts
  final String? startsAfterJobId;

  /// The given time in between tasks
  final int? gapDays;

  /// How many tasks the whole bundle has, denormalised onto every task by
  /// `createBundle` so the feed card can say "Part of a 4-task bundle"
  /// without a second read of the bundle document. Server-owned, so it is
  /// never written back in [toMap].
  final int? bundleTaskCount;

  bool get isBundleTask => bundleId != null;

  /// Fields written to Firestore. `createdAt`/`bidCount`/`status` for a new job
  /// are set by the repository, so they are omitted here.
  Map<String, dynamic> toMap() => {
        'requestorId': requestorId,
        'requestorName': requestorName,
        if (requestorPhotoUrl != null) 'requestorPhotoUrl': requestorPhotoUrl,
        'title': title,
        'description': description,
        'category': category,
        'location': location.toMap(),
        'budget': budget?.toMap(),
        'photoUrls': photoUrls,
        if (videoUrl != null) 'videoUrl': videoUrl,
        if (deadline != null) 'deadline': deadline,
      };

  /// Builds a [Job] from a document id and its (already Timestamp-normalised)
  /// data map.
  factory Job.fromMap(String id, Map<String, dynamic> m) => Job(
        id: id,
        requestorId: m['requestorId'] as String? ?? '',
        requestorName: m['requestorName'] as String? ?? 'Requestor',
        requestorPhotoUrl: m['requestorPhotoUrl'] as String?,
        title: m['title'] as String? ?? '',
        description: m['description'] as String? ?? '',
        category: m['category'] as String? ?? 'Other',
        location: JobLocation.fromMap(m['location'] as Map<String, dynamic>?),
        budget: m['budget'] == null
            ? null
            : JobBudget.fromMap(m['budget'] as Map<String, dynamic>?),
        photoUrls:
            (m['photoUrls'] as List?)?.whereType<String>().toList() ?? const [],
        videoUrl: m['videoUrl'] as String?,
        status: JobStatus.fromStorage(m['status'] as String?),
        bidCount: (m['bidCount'] as num?)?.toInt() ?? 0,
        createdAt: m['createdAt'] as DateTime?,
        deadline: m['deadline'] as DateTime?,
        acceptedProviderId: m['acceptedProviderId'] as String?,
        acceptedProviderName: m['acceptedProviderName'] as String?,
        acceptedBidAmountSen: (m['acceptedBidAmountSen'] as num?)?.toInt(),
        cancellationRequestedBy: m['cancellationRequestedBy'] as String?,
        cancellationReason: m['cancellationReason'] as String?,
        cancellationRequestedAt: m['cancellationRequestedAt'] as DateTime?,
        cancelledAt: m['cancelledAt'] as DateTime?,
        cancelledBy: m['cancelledBy'] as String?,
        planRejectionNote: m['planRejectionNote'] as String?,
        bundleId: m['bundleId'] as String?,
        bundleOrder: (m['bundleOrder'] as num?)?.toInt(),
        lotId: m['lotId'] as String?,
        startsAfterJobId:m['startsAfterJobId'] as String?,
        gapDays: (m['gapDays']as num?)?.toInt(),
        bundleTaskCount: (m['bundleTaskCount'] as num?)?.toInt(),
      );
}
