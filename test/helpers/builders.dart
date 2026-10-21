import 'package:fairbid/features/jobs/domain/appointment.dart';
import 'package:fairbid/features/jobs/domain/bid.dart';
import 'package:fairbid/features/jobs/domain/bundle.dart';
import 'package:fairbid/features/jobs/domain/bundle_award.dart';
import 'package:fairbid/features/jobs/domain/bundle_bid.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/jobs/domain/milestone.dart';
import 'package:fairbid/features/jobs/domain/price_change_request.dart';

/// What:   A job posted by `uid-1`, open by default.
/// Input:  Any field to override; pass [status] and the accepted-provider fields for an awarded job.
/// Output: A Job at Bangsar, KL with a RM100-250 budget.
Job sampleJob({
  String id = 'job-1',
  String requestorId = 'uid-1',
  String requestorName = 'Test User',
  String title = 'Fix leaking sink',
  String category = 'Plumbing',
  double lat = 3.14,
  double lng = 101.7,
  JobStatus status = JobStatus.open,
  String? acceptedProviderId,
  String? acceptedProviderName,
  int? acceptedBidAmountSen,
  DateTime? deadline,
  int bidCount = 0,
  String? bundleId,
  int? bundleOrder,
  int? bundleTaskCount,
  DateTime? releasedAt,
  int? originalBidAmountSen,
}) => Job(
  id: id,
  requestorId: requestorId,
  requestorName: requestorName,
  title: title,
  description: 'Kitchen sink is leaking under the cabinet.',
  category: category,
  location: JobLocation(lat: lat, lng: lng, address: 'Bangsar, KL'),
  budget: const JobBudget(minSen: 10000, maxSen: 25000),
  createdAt: DateTime.now(),
  status: status,
  acceptedProviderId: acceptedProviderId,
  acceptedProviderName: acceptedProviderName,
  acceptedBidAmountSen: acceptedBidAmountSen,
  originalBidAmountSen: originalBidAmountSen,
  deadline: deadline,
  bidCount: bidCount,
  bundleId: bundleId,
  bundleOrder: bundleOrder,
  bundleTaskCount: bundleTaskCount,
  releasedAt: releasedAt,
);

/// What:   A pending bid on [jobId] from an established provider (visible score).
/// Input:  Any field to override; `scoreVisible: false` gives the "New provider" case.
/// Output: A Bid of RM150 unless [amountSen] says otherwise.
Bid sampleBid({
  String jobId = 'job-1',
  String providerId = 'prov-1',
  String providerName = 'Pro Fixer',
  int trustScore = 800,
  bool scoreVisible = true,
  int amountSen = 15000,
}) => Bid(
  jobId: jobId,
  providerId: providerId,
  providerName: providerName,
  providerTrustScore: trustScore,
  providerScoreVisible: scoreVisible,
  amountSen: amountSen,
  estimatedDuration: 'Less than 1 week',
  message: 'I can fix this quickly with quality parts.',
  createdAt: DateTime.now(),
);

/// What:   An open bundle owned by `uid-1`.
/// Input:  [taskIds] naming its tasks; any other field to override.
/// Output: A Bundle in Penang.
Bundle sampleBundle({
  String id = 'bundle-1',
  String requestorId = 'uid-1',
  String title = 'Bathroom refresh',
  List<String> taskIds = const ['job-1', 'job-2'],
  DateTime? deadline,
  BundleStatus status = BundleStatus.open,
}) => Bundle(
  id: id,
  requestorId: requestorId,
  requestorName: 'Test User',
  title: title,
  description: 'Small bathroom, about 4 square metres.',
  location: const JobLocation(lat: 3.14, lng: 101.7, address: 'Penang'),
  taskIds: taskIds,
  createdAt: DateTime.now(),
  deadline: deadline,
  status: status,
);


/// What:   An awarded, in-progress job seen by its owner (`uid-1`) or its provider.
/// Input:  [owner] picks the viewer's side; the rest override one field each.
/// Output: A Job with provider `prov-1` (or `uid-1` when the viewer is the provider).
Job testJob({
  required bool owner,
  String id = 'job-1',
  String title = 'Fix leaking sink',
  String description = 'The kitchen sink leaks.',
  JobStatus status = JobStatus.inProgress,
  JobBudget? budget,
  List<String> photoUrls = const [],
  String? bundleId,
  String? providerId,
  int? originalBidAmountSen,
  int priceChangeCount = 0,
  PriceChangeRequest? priceChangeRequest,
  bool schedulingRequired = false,
  Appointment? appointment,
  AppointmentProposal? appointmentProposal,
  DateTime? onTheWayAt,
  int? etaMinutes,
  DateTime? arrivedAt,
}) => Job(
  id: id,
  requestorId: owner ? 'uid-1' : 'req-9',
  requestorName: 'Rita Client',
  title: title,
  description: description,
  category: 'Plumbing',
  location: const JobLocation(lat: 3.14, lng: 101.7, address: 'Bangsar, KL'),
  budget: budget,
  photoUrls: photoUrls,
  createdAt: DateTime.now(),
  status: status,
  acceptedProviderId: providerId ?? (owner ? 'prov-1' : 'uid-1'),
  acceptedProviderName: 'Pro Fixer',
  acceptedBidAmountSen: 15000,
  originalBidAmountSen: originalBidAmountSen,
  priceChangeCount: priceChangeCount,
  priceChangeRequest: priceChangeRequest,
  bundleId: bundleId,
  schedulingRequired: schedulingRequired,
  appointment: appointment,
  appointmentProposal: appointmentProposal,
  onTheWayAt: onTheWayAt,
  etaMinutes: etaMinutes,
  arrivedAt: arrivedAt,
);

/// What:   A single RM150 milestone on `job-1`.
/// Input:  [status]; [owner] false means the viewer is the provider (`uid-1`), else it is `prov-1`.
/// Output: A Milestone with order 0.
Milestone sampleMilestone({
  MilestoneStatus status = MilestoneStatus.funded,
  String id = 'ms-1',
  bool owner = true,
  String description = 'Full repair',
}) => Milestone(
  id: id,
  jobId: 'job-1',
  providerId: owner ? 'prov-1' : 'uid-1',
  description: description,
  amountSen: 15000,
  order: 0,
  status: status,
  createdAt: DateTime.now(),
);

/// What:   A package bid on bundle `b1`, from Aida Renovation by default.
/// Input:  Any field to override; [taskPrices] defaults to job-1 RM375 and job-2 RM520.
/// Output: A pending BundleBid.
BundleBid sampleBundleBid({
  String bundleId = 'b1',
  String providerId = 'prov-1',
  String providerName = 'Aida Renovation',
  Map<String, int> taskPrices = const {'job-1': 37500, 'job-2': 52000},
  int? bundlePriceSen,
  String estimatedDuration = '1 week',
  String message = '',
  BundleBidStatus status = BundleBidStatus.pending,
  String bundleTitle = 'Bundle',
  DateTime? createdAt,
  DateTime? updatedAt,
}) => BundleBid(
  bundleId: bundleId,
  providerId: providerId,
  providerName: providerName,
  taskPrices: taskPrices,
  bundlePriceSen: bundlePriceSen,
  estimatedDuration: estimatedDuration,
  message: message,
  status: status,
  bundleTitle: bundleTitle,
  createdAt: createdAt ?? DateTime.now(),
  updatedAt: updatedAt,
);

/// What:   A bundle award option; by default Aida Renovation wins job-1 for RM375.
/// Input:  Any field to override; [awards] replaces the default winner list.
/// Output: A BundleAwardOption keyed `bestValue`.
BundleAwardOption sampleOption({
  String key = 'bestValue',
  String label = 'Best Value',
  int totalSen = 37500,
  int providerCount = 1,
  int premiumSen = 0,
  int weightedTrust = 700,
  bool trustVisible = false,
  List<String> uncoveredTaskIds = const [],
  List<BundleAwardItem> awards = const [
    BundleAwardItem(
      providerId: 'prov-1',
      providerName: 'Aida Renovation',
      taskAmountsSen: {'job-1': 37500},
    ),
  ],
}) => BundleAwardOption(
  key: key,
  label: label,
  totalSen: totalSen,
  providerCount: providerCount,
  premiumSen: premiumSen,
  weightedTrust: weightedTrust,
  trustVisible: trustVisible,
  uncoveredTaskIds: uncoveredTaskIds,
  awards: awards,
);
