import '../../../core/util/money.dart';
import 'appointment.dart';
import 'price_change_request.dart';

/// What:   Lifecycle of a job.
/// Input:  Stored `status` string via [fromStorage]; unknown values read as open.
/// Output: open, inProgress, completed or cancelled, with a display [label].
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

/// What:   A job's map-picked location.
/// Input:  Job doc field `location`.
/// Output: Coordinates and a display [address]; [districtCode]/[districtName]/[town] are null on old jobs.
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

/// What:   Optional budget: a fixed amount, a range or an hourly rate, in sen.
/// Input:  Job doc field `budget`.
/// Output: [label] for display.
class JobBudget {
  const JobBudget({this.minSen, this.maxSen, this.hourly = false});

  final int? minSen;
  final int? maxSen;
  final bool hourly;

  /// What:   Display text for the budget.
  /// Output: e.g. `RM 100 – RM 250` or `RM 50/hr`; null when no bound is set.
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

/// What:   A job posted by a requestor (one doc in `jobs`).
/// Input:  Firestore data via JobRepository._fromDoc (job_repository.dart).
/// Output: Immutable model; toMap() writes only client-owned fields.
/// Notes:  Server-owned fields are set by Cloud Functions, never written back.
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
    this.cancelledBy,
    this.bundleId,
    this.bundleOrder,
    this.bundleTaskCount,
    this.releasedAt,
    this.schedulingRequired = false,
    this.appointment,
    this.appointmentProposal,
    this.onTheWayAt,
    this.etaMinutes,
    this.arrivedAt,
  });

  final String id;
  final String requestorId;
  final String requestorName;

  /// The requestor's photo at posting time; null if none.
  final String? requestorPhotoUrl;
  final String title;
  final String description;
  final String category;
  final JobLocation location;
  final JobBudget? budget;
  final List<String> photoUrls;

  /// A video on older jobs; new jobs can't add one. Null if none.
  final String? videoUrl;
  final JobStatus status;
  final int bidCount;
  final DateTime? createdAt;
  final DateTime? deadline;

  /// Winner details; null while open.
  final String? acceptedProviderId;
  final String? acceptedProviderName;
  final int? acceptedBidAmountSen;

  /// The price first agreed at accept; null on old jobs until it changes.
  final int? originalBidAmountSen;

  /// Number of accepted price changes (capped server-side).
  final int priceChangeCount;

  /// Pending mutual price-change proposal, or null.
  final PriceChangeRequest? priceChangeRequest;

  /// What:   Whether a price change is awaiting the counterparty's decision.
  bool get hasPendingPriceChange => priceChangeRequest != null;

  /// Pending cancellation request: `'requestor'` or `'provider'`, else null.
  /// The other party accepts to finish it.
  final String? cancellationRequestedBy;
  final String? cancellationReason;

  /// Set when the job is cancelled: a uid, `'admin'`, or `'dispute'`.
  final String? cancelledBy;

  /// What:   Whether a mid-flight cancellation is awaiting the counterparty's decision.
  bool get hasPendingCancellation => cancellationRequestedBy != null;

  final String? bundleId;

  /// Position of the task within its bundle.
  final int? bundleOrder;

  /// Bundle size, copied onto each task for the feed card.
  final int? bundleTaskCount;

  /// Set when this task was left unawarded; it then takes ordinary bids.
  final DateTime? releasedAt;

  /// The provider can't deliver until a visit time is agreed; absent on older jobs.
  final bool schedulingRequired;

  /// The agreed visit time, or null until both sides confirm one.
  final Appointment? appointment;

  /// A pending proposal of visit times, or null.
  final AppointmentProposal? appointmentProposal;

  /// Visit day: when the provider said on the way, their ETA (15/30/45/60) and arrival.
  final DateTime? onTheWayAt;
  final int? etaMinutes;
  final DateTime? arrivedAt;

  /// What:   Whether delivery is waiting on an agreed visit time.
  /// Input:  [schedulingRequired] and [appointment].
  /// Output: True until the visit time is confirmed.
  bool get needsAppointment => schedulingRequired && appointment == null;

  /// What:   Whether the job is a task of a bundle.
  bool get isBundleTask => bundleId != null;

  /// What:   Whether the task is still part of its bundle.
  /// Notes:  Not yet released; award and cancel happen for the whole bundle.
  bool get isLiveBundleTask => bundleId != null && releasedAt == null;

  /// What:   Whether the task is open for package bids.
  /// Output: True for a live bundle task that is still open; false once the bundle is awarded.
  bool get isBiddingAsBundle => isLiveBundleTask && status == JobStatus.open;

  /// What:   Fields the client writes.
  /// Output: Map without `createdAt`, `bidCount` and `status`; the repository adds those.
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
        cancelledBy: m['cancelledBy'] as String?,
        bundleId: m['bundleId'] as String?,
        bundleOrder: (m['bundleOrder'] as num?)?.toInt(),
        bundleTaskCount: (m['bundleTaskCount'] as num?)?.toInt(),
        releasedAt: m['releasedAt'] as DateTime?,
        schedulingRequired: m['schedulingRequired'] as bool? ?? false,
        appointment:
            Appointment.fromMap(m['appointment'] as Map<String, dynamic>?),
        appointmentProposal: AppointmentProposal.fromMap(
            m['appointmentProposal'] as Map<String, dynamic>?),
        onTheWayAt: m['onTheWayAt'] as DateTime?,
        etaMinutes: (m['etaMinutes'] as num?)?.toInt(),
        arrivedAt: m['arrivedAt'] as DateTime?,
      );
}
