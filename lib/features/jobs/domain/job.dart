import '../../../core/util/money.dart';
import 'price_change_request.dart';

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
        JobStatus.inProgress => 'In progress',
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

/// A map-picked location: coordinates plus a readable label. [address] is safe
/// to show as is; [districtCode]/[districtName]/[town] are null on old jobs.
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

/// Optional budget: a fixed amount, a range or an hourly rate, in sen.
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

/// A job posted by a requestor. The repository maps it to and from Firestore.
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
    this.originalBidAmountSen,
    this.priceChangeCount = 0,
    this.priceChangeRequest,
    this.cancellationRequestedBy,
    this.cancellationReason,
    this.cancellationRequestedAt,
    this.cancelledAt,
    this.cancelledBy,
    this.planRejectionNote,
    this.fundedAtAward = false,
    this.bundleId,
    this.bundleOrder,
    this.bundleTaskCount,
    this.releasedAt,
  });

  final String id;
  final String requestorId;
  final String requestorName;

  /// The requestor's `profilePhotoUrl` at posting time, so providers see a face
  /// without loading the profile. Null if they had no photo.
  final String? requestorPhotoUrl;
  final String title;
  final String description;
  final String category;
  final JobLocation location;
  final JobBudget? budget;
  final List<String> photoUrls;

  /// One optional attached video (see `uploadJobVideo`). Null if none.
  final String? videoUrl;
  final JobStatus status;
  final int bidCount;
  final DateTime? createdAt;
  final DateTime? deadline;

  /// Winner details, set when the requestor accepts a bid (null while open).
  final String? acceptedProviderId;
  final String? acceptedProviderName;
  final int? acceptedBidAmountSen;

  /// The price first agreed at accept time. Null on old jobs until it changes.
  final int? originalBidAmountSen;

  /// Number of accepted price changes (capped server-side).
  final int priceChangeCount;

  /// Pending mutual price-change proposal, or null.
  final PriceChangeRequest? priceChangeRequest;

  /// Whether a price change is awaiting the counterparty's decision.
  bool get hasPendingPriceChange => priceChangeRequest != null;

  /// Pending cancellation request: `'requestor'` or `'provider'`, else null.
  /// The other party accepts to finish it.
  final String? cancellationRequestedBy;
  final String? cancellationReason;
  final DateTime? cancellationRequestedAt;

  /// Set when the job is cancelled: a uid, `'admin'`, or `'dispute'`.
  final DateTime? cancelledAt;
  final String? cancelledBy;

  /// Whether a mid-flight cancellation is awaiting the counterparty's decision.
  bool get hasPendingCancellation => cancellationRequestedBy != null;

  /// The requestor's note when they sent a proposed milestone plan back for
  /// changes; null once the provider re-proposes.
  final String? planRejectionNote;

  /// True if the whole price went into escrow at accept time as one funded
  /// "Full job" stage. Server-owned, never written back in [toMap].
  final bool fundedAtAward;

  final String? bundleId;

  /// The order of tasks within a bundle
  final int? bundleOrder;

  /// How many tasks the bundle has, copied onto each task for the feed card.
  /// Server-owned, never written back in [toMap].
  final int? bundleTaskCount;

  /// Set by `awardBundle` when this task was left unawarded. It then takes
  /// ordinary per-job bids. Server-owned, never written back in [toMap].
  final DateTime? releasedAt;

  bool get isBundleTask => bundleId != null;

  /// Whether this task still bids as part of its bundle's package (not yet
  /// released). Award and cancel happen for the whole bundle.
  bool get isLiveBundleTask => bundleId != null && releasedAt == null;

  /// Whether this task is still being bid on as part of its bundle:
  /// [isLiveBundleTask] and still open. Turns false once the bundle is awarded.
  bool get isBiddingAsBundle => isLiveBundleTask && status == JobStatus.open;

  /// Fields written to Firestore. The repository sets `createdAt`, `bidCount`
  /// and `status` for a new job.
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

  /// Builds a [Job] from a document id and its data map.
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
        originalBidAmountSen: (m['originalBidAmountSen'] as num?)?.toInt(),
        priceChangeCount: (m['priceChangeCount'] as num?)?.toInt() ?? 0,
        priceChangeRequest: PriceChangeRequest.fromMap(
            m['priceChangeRequest'] as Map<String, dynamic>?),
        cancellationRequestedBy: m['cancellationRequestedBy'] as String?,
        cancellationReason: m['cancellationReason'] as String?,
        cancellationRequestedAt: m['cancellationRequestedAt'] as DateTime?,
        cancelledAt: m['cancelledAt'] as DateTime?,
        cancelledBy: m['cancelledBy'] as String?,
        planRejectionNote: m['planRejectionNote'] as String?,
        fundedAtAward: m['fundedAtAward'] as bool? ?? false,
        bundleId: m['bundleId'] as String?,
        bundleOrder: (m['bundleOrder'] as num?)?.toInt(),
        bundleTaskCount: (m['bundleTaskCount'] as num?)?.toInt(),
        releasedAt: m['releasedAt'] as DateTime?,
      );
}
