import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fairbid/core/app.dart';
import 'package:fairbid/core/config/platform_config.dart';
import 'package:fairbid/core/location/geo.dart';
import 'package:fairbid/core/util/money.dart';
import 'package:fairbid/core/widgets/app_widgets.dart';
import 'package:fairbid/features/admin/data/moderation_repository.dart';
import 'package:fairbid/features/admin/data/stats_repository.dart';
import 'package:fairbid/features/admin/data/verification_repository.dart';
import 'package:fairbid/features/admin/domain/flagged_review.dart';
import 'package:fairbid/features/admin/domain/pending_verification.dart';
import 'package:fairbid/features/admin/domain/platform_stats.dart';
import 'package:fairbid/features/auth/data/auth_exception.dart';
import 'package:fairbid/features/auth/data/auth_repository.dart';
import 'package:fairbid/features/auth/domain/app_user.dart';
import 'package:fairbid/features/auth/domain/user_role.dart';
import 'package:fairbid/features/auth/presentation/validators.dart';
import 'package:fairbid/features/disputes/data/dispute_repository.dart';
import 'package:fairbid/features/disputes/domain/dispute.dart';
import 'package:fairbid/features/jobs/data/assist_repository.dart';
import 'package:fairbid/features/jobs/data/bid_repository.dart';
import 'package:fairbid/features/jobs/data/job_repository.dart';
import 'package:fairbid/features/jobs/data/milestone_repository.dart';
import 'package:fairbid/features/jobs/domain/bid.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/jobs/domain/milestone.dart';
import 'package:fairbid/features/jobs/presentation/widgets/bid_card.dart';
import 'package:fairbid/features/messages/data/chat_repository.dart';
import 'package:fairbid/features/messages/domain/conversation.dart';
import 'package:fairbid/features/messages/domain/message.dart';
import 'package:fairbid/features/notifications/data/notification_repository.dart';
import 'package:fairbid/features/notifications/data/push_service.dart';
import 'package:fairbid/features/notifications/domain/app_notification.dart';
import 'package:fairbid/features/onboarding/data/document_storage_repository.dart';
import 'package:fairbid/features/onboarding/data/onboarding_repository.dart';
import 'package:fairbid/features/onboarding/data/requestor_onboarding_repository.dart';
import 'package:fairbid/features/onboarding/domain/onboarding_data.dart';
import 'package:fairbid/features/onboarding/domain/requestor_onboarding_data.dart';
import 'package:fairbid/features/profile/data/review_repository.dart';
import 'package:fairbid/features/profile/domain/review.dart';
import 'package:fairbid/features/profile/presentation/edit_profile_screen.dart';
import 'package:fairbid/features/wallet/data/wallet_repository.dart';
import 'package:fairbid/features/wallet/domain/ledger_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';

/// In-memory [AuthRepository] used to drive the UI in tests without Firebase.
///
/// Set [failWith] to simulate an auth error on the next action.
class FakeAuthRepository implements AuthRepository {
  final _controller = StreamController<AppUser?>.broadcast();
  AppUser? _current;
  AuthException? failWith;

  /// Mirror what Firestore would hold; flipped by the fake onboarding repos.
  /// Default to an already-onboarded user (existing account logging in);
  /// requestor-registration tests set [onboardingComplete] to false.
  String verificationStatus = 'none';
  bool onboardingComplete = true;
  double? baseLat;
  double? baseLng;
  String displayName = 'Test User';
  String? phone;
  String? location;
  String? bio;
  String? providerType;
  String? payoutBankName;
  String? payoutAccountLast4;
  int walletBalanceSen = 0;
  int ratingCount = 0;
  int ratingSum = 0;
  int jobsCompleted = 0;
  int disputesLost = 0;

  @override
  Stream<AppUser?> authStateChanges() async* {
    yield _current; // initial state so the app leaves the splash screen
    yield* _controller.stream;
  }

  AppUser _build(UserRole role) {
    // Mirror the recomputeTrustOnUserWrite Cloud Function: the breakdown is
    // always derived from the raw fields, so tests seed inputs, not scores.
    final trust = PlatformConfig.trustBreakdownFor(
      ratingSum: ratingSum,
      ratingCount: ratingCount,
      verificationStatus: verificationStatus,
      jobsCompleted: jobsCompleted,
      disputesLost: disputesLost,
      hasDisplayName: displayName.isNotEmpty,
      hasPhone: (phone ?? '').isNotEmpty,
      hasBio: (bio ?? '').isNotEmpty,
      hasPhoto: false,
      hasLocation: (location ?? '').isNotEmpty,
    );
    return AppUser(
      uid: 'uid-1',
      email: 'test@fairbid.app',
      displayName: displayName,
      role: role,
      verificationStatus: verificationStatus,
      onboardingComplete: onboardingComplete,
      baseLat: baseLat,
      baseLng: baseLng,
      phone: phone,
      location: location,
      bio: bio,
      providerType: providerType,
      payoutBankName: payoutBankName,
      payoutAccountLast4: payoutAccountLast4,
      walletBalanceSen: walletBalanceSen,
      ratingCount: ratingCount,
      ratingSum: ratingSum,
      jobsCompleted: jobsCompleted,
      disputesLost: disputesLost,
      trustScore: trust.composite,
      trustBreakdown: trust,
    );
  }

  @override
  Future<AppUser?> currentUser() async =>
      _current == null ? null : _build(_current!.role);

  /// Boots the app already signed-in as [role] (admins have no register flow,
  /// so tests seed them the way the Firebase console would).
  void seedSignedIn(UserRole role) => _current = _build(role);

  void _signIn(UserRole role) {
    if (failWith != null) throw failWith!;
    _current = _build(role);
    _controller.add(_current);
  }

  @override
  Future<void> updateBaseLocation({
    required String uid,
    required double lat,
    required double lng,
    required String address,
  }) async {
    baseLat = lat;
    baseLng = lng;
  }

  @override
  Future<void> updateProfile({
    required String uid,
    required String displayName,
    required String? phone,
    required String? location,
    required String? bio,
  }) async {
    this.displayName = displayName;
    this.phone = phone;
    this.location = location;
    this.bio = bio;
  }

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async =>
      _signIn(UserRole.requestor);

  @override
  Future<void> registerWithEmail({
    required String email,
    required String password,
    required String displayName,
    required UserRole role,
  }) async =>
      _signIn(role);

  @override
  Future<void> signInWithGoogle({required UserRole roleIfNew}) async =>
      _signIn(roleIfNew);

  @override
  Future<void> signOut() async {
    _current = null;
    _controller.add(null);
  }

  @override
  Future<void> deleteAccount({String? password}) async {
    if (failWith != null) throw failWith!;
    _current = null;
    _controller.add(null);
  }
}

/// In-memory [OnboardingRepository]; submission flips the fake auth repo's
/// verification status, mimicking the Firestore write.
class FakeOnboardingRepository implements OnboardingRepository {
  FakeOnboardingRepository(this.auth);

  final FakeAuthRepository auth;
  OnboardingData? saved;

  @override
  Future<OnboardingData> load(String uid) async => saved ?? OnboardingData();

  @override
  Future<void> save(String uid, OnboardingData data) async => saved = data;

  @override
  Future<void> submitForReview(String uid, OnboardingData data) async {
    saved = data;
    auth.verificationStatus = 'pending';
  }
}

/// In-memory [RequestorOnboardingRepository]; completing flips the fake auth
/// repo's `onboardingComplete`, mimicking the Firestore write.
class FakeRequestorOnboardingRepository
    implements RequestorOnboardingRepository {
  FakeRequestorOnboardingRepository(this.auth);

  final FakeAuthRepository auth;
  RequestorOnboardingData? saved;

  @override
  Future<RequestorOnboardingData> load(String uid) async =>
      saved ?? RequestorOnboardingData();

  @override
  Future<void> save(String uid, RequestorOnboardingData data) async =>
      saved = data;

  @override
  Future<void> complete(String uid, RequestorOnboardingData data) async {
    saved = data;
    auth.onboardingComplete = true;
  }
}

/// In-memory [DocumentStorageRepository]; never touches real Firebase Storage
/// or the platform image picker, since no test currently exercises uploads.
class FakeDocumentStorageRepository implements DocumentStorageRepository {
  @override
  Future<String> uploadVerificationImage({
    required String uid,
    required String purpose,
    required XFile file,
  }) async =>
      'https://fake.storage/$uid/$purpose';

  @override
  Future<String> uploadJobPhoto({
    required String uid,
    required XFile file,
  }) async =>
      'https://fake.storage/jobs/$uid';

  @override
  Future<String> uploadDisputeEvidence({
    required String uid,
    required XFile file,
  }) async =>
      'https://fake.storage/disputes/$uid';

  @override
  Future<void> deleteByUrl(String url) async {}
}

/// In-memory [JobRepository] seeded with [jobs].
class FakeJobRepository implements JobRepository {
  FakeJobRepository([List<Job> jobs = const []]) : _jobs = [...jobs];

  final List<Job> _jobs;

  @override
  Future<String> create(Job job) async {
    _jobs.add(job);
    return 'job-${_jobs.length}';
  }

  @override
  Stream<List<Job>> watchOpenJobs({String? category}) async* {
    yield _jobs
        .where((j) =>
            j.status == JobStatus.open &&
            (category == null || j.category == category))
        .toList();
  }

  @override
  Stream<List<Job>> watchMyJobs(String requestorId) async* {
    yield _jobs.where((j) => j.requestorId == requestorId).toList();
  }

  @override
  Stream<List<Job>> watchAssignedJobs(String providerId) async* {
    yield _jobs.where((j) => j.acceptedProviderId == providerId).toList();
  }

  @override
  Future<Job?> getById(String id) async =>
      _jobs.cast<Job?>().firstWhere((j) => j!.id == id, orElse: () => null);

  @override
  Future<void> cancelOpenJob(String id) async {
    final i = _jobs.indexWhere((j) => j.id == id);
    if (i != -1) _jobs[i] = _rebuild(_jobs[i], status: JobStatus.cancelled);
  }

  @override
  Future<void> requestCancellation(String jobId, {String? reason}) async {
    final i = _jobs.indexWhere((j) => j.id == jobId);
    if (i == -1) return;
    _jobs[i] = _rebuild(_jobs[i],
        cancellationRequestedBy: 'requestor', cancellationReason: reason);
  }

  @override
  Future<void> respondToCancellation(String jobId,
      {required bool accept}) async {
    final i = _jobs.indexWhere((j) => j.id == jobId);
    if (i == -1) return;
    _jobs[i] = _rebuild(_jobs[i],
        status: accept ? JobStatus.cancelled : null,
        clearCancellationRequest: true);
  }

  @override
  Future<void> adminCancelJob(String jobId, {String? reason}) async {
    final i = _jobs.indexWhere((j) => j.id == jobId);
    if (i != -1) _jobs[i] = _rebuild(_jobs[i], status: JobStatus.cancelled);
  }

  /// Mimics the `releaseMilestone` Cloud Function's completion write when the
  /// last milestone releases (called by [FakeMilestoneRepository]).
  void complete(String id) {
    final i = _jobs.indexWhere((j) => j.id == id);
    if (i == -1) return;
    _jobs[i] = _rebuild(_jobs[i], status: JobStatus.completed);
  }

  /// Mimics the accept batch: assigns the winner and flips the job's status.
  void assign(Bid bid) {
    final i = _jobs.indexWhere((j) => j.id == bid.jobId);
    _jobs[i] = _rebuild(
      _jobs[i],
      status: JobStatus.inProgress,
      acceptedProviderId: bid.providerId,
      acceptedProviderName: bid.providerName,
      acceptedBidAmountSen: bid.amountSen,
    );
  }

  /// Rebuilds [j] with overrides — the fake's stand-in for a Firestore update,
  /// since [Job] is immutable and has no copyWith.
  Job _rebuild(
    Job j, {
    JobStatus? status,
    String? acceptedProviderId,
    String? acceptedProviderName,
    int? acceptedBidAmountSen,
    String? cancellationRequestedBy,
    String? cancellationReason,
    bool clearCancellationRequest = false,
  }) =>
      Job(
        id: j.id,
        requestorId: j.requestorId,
        requestorName: j.requestorName,
        title: j.title,
        description: j.description,
        category: j.category,
        location: j.location,
        budget: j.budget,
        photoUrls: j.photoUrls,
        status: status ?? j.status,
        bidCount: j.bidCount,
        createdAt: j.createdAt,
        deadline: j.deadline,
        acceptedProviderId: acceptedProviderId ?? j.acceptedProviderId,
        acceptedProviderName: acceptedProviderName ?? j.acceptedProviderName,
        acceptedBidAmountSen: acceptedBidAmountSen ?? j.acceptedBidAmountSen,
        cancellationRequestedBy: clearCancellationRequest
            ? null
            : (cancellationRequestedBy ?? j.cancellationRequestedBy),
        cancellationReason: clearCancellationRequest
            ? null
            : (cancellationReason ?? j.cancellationReason),
      );
}

/// In-memory [BidRepository]. Streams re-emit whenever a bid changes so the
/// detail screen updates live, like Firestore snapshots would.
class FakeBidRepository implements BidRepository {
  FakeBidRepository(this.jobs, [List<Bid> bids = const []])
      : _bids = [...bids];

  final FakeJobRepository jobs;
  final List<Bid> _bids;
  final _changes = StreamController<void>.broadcast();

  void _notify() => _changes.add(null);

  Bid _withStatus(Bid b, BidStatus status) => Bid(
        jobId: b.jobId,
        providerId: b.providerId,
        providerName: b.providerName,
        providerTrustScore: b.providerTrustScore,
        amountSen: b.amountSen,
        estimatedDuration: b.estimatedDuration,
        message: b.message,
        status: status,
        createdAt: b.createdAt,
      );

  @override
  Future<void> submitBid(Bid bid) async {
    _bids.removeWhere(
        (b) => b.jobId == bid.jobId && b.providerId == bid.providerId);
    _bids.add(bid);
    _notify();
  }

  @override
  Future<void> withdrawBid(String jobId, String providerId) async {
    _bids.removeWhere(
        (b) => b.jobId == jobId && b.providerId == providerId);
    _notify();
  }

  @override
  Stream<List<Bid>> watchBids(String jobId) async* {
    yield _bids.where((b) => b.jobId == jobId).toList();
    await for (final _ in _changes.stream) {
      yield _bids.where((b) => b.jobId == jobId).toList();
    }
  }

  @override
  Stream<List<Bid>> watchMyBids(String providerId) async* {
    yield _bids.where((b) => b.providerId == providerId).toList();
    await for (final _ in _changes.stream) {
      yield _bids.where((b) => b.providerId == providerId).toList();
    }
  }

  @override
  Stream<Bid?> watchMyBid(String jobId, String providerId) async* {
    Bid? mine() => _bids
        .cast<Bid?>()
        .firstWhere((b) => b!.jobId == jobId && b.providerId == providerId,
            orElse: () => null);
    yield mine();
    await for (final _ in _changes.stream) {
      yield mine();
    }
  }

  @override
  Future<void> acceptBid(Bid bid) async {
    for (var i = 0; i < _bids.length; i++) {
      final b = _bids[i];
      if (b.jobId != bid.jobId || b.status != BidStatus.pending) continue;
      _bids[i] = _withStatus(
          b,
          b.providerId == bid.providerId
              ? BidStatus.accepted
              : BidStatus.rejected);
    }
    jobs.assign(bid);
    _notify();
  }
}

/// In-memory [MilestoneRepository]. Fund/release mimic the Cloud Functions'
/// status flips — and, on the last release, completing the job via the fake
/// job repo. No wallet money moves in widget tests.
class FakeMilestoneRepository implements MilestoneRepository {
  FakeMilestoneRepository(this.jobs, [List<Milestone> seed = const []])
      : _milestones = [...seed];

  final FakeJobRepository jobs;
  final List<Milestone> _milestones;
  final _changes = StreamController<void>.broadcast();

  void _notify() => _changes.add(null);

  Milestone _withStatus(Milestone m, MilestoneStatus status,
          {String? note, String? reworkNote, int? reworkCount}) =>
      Milestone(
        id: m.id,
        jobId: m.jobId,
        providerId: m.providerId,
        description: m.description,
        amountSen: m.amountSen,
        order: m.order,
        status: status,
        submissionNote: note ?? m.submissionNote,
        reworkNote: reworkNote ?? m.reworkNote,
        reworkCount: reworkCount ?? m.reworkCount,
        createdAt: m.createdAt,
      );

  void _update(String milestoneId, Milestone Function(Milestone) change) {
    final i = _milestones.indexWhere((m) => m.id == milestoneId);
    if (i == -1) return;
    _milestones[i] = change(_milestones[i]);
    _notify();
  }

  @override
  Future<void> proposeMilestones(
      String jobId, List<Milestone> milestones) async {
    // Mimics the `proposeMilestonePlan` Cloud Function: replaces any un-locked
    // plan and writes each milestone `proposed` (awaiting client approval).
    _milestones.removeWhere((m) =>
        m.jobId == jobId &&
        (m.status == MilestoneStatus.proposed ||
            m.status == MilestoneStatus.pending));
    for (final (i, m) in milestones.indexed) {
      _milestones.add(Milestone(
        id: 'm$i',
        jobId: jobId,
        providerId: m.providerId,
        description: m.description,
        amountSen: m.amountSen,
        order: i,
        status: MilestoneStatus.proposed,
        createdAt: DateTime.now(),
      ));
    }
    _notify();
  }

  @override
  Future<void> approveMilestonePlan(String jobId) async {
    for (var i = 0; i < _milestones.length; i++) {
      final m = _milestones[i];
      if (m.jobId == jobId && m.status == MilestoneStatus.proposed) {
        _milestones[i] = _withStatus(m, MilestoneStatus.pending);
      }
    }
    _notify();
  }

  @override
  Future<void> rejectMilestonePlan(String jobId, {String? note}) async {
    _milestones.removeWhere(
        (m) => m.jobId == jobId && m.status == MilestoneStatus.proposed);
    _notify();
  }

  /// Mimics a dispute ruling of `release`: pays out and closes the milestone,
  /// completing the job when it was the last un-released one.
  void resolveRelease(String jobId, String milestoneId) {
    _update(milestoneId, (m) => _withStatus(m, MilestoneStatus.released));
    _maybeComplete(jobId);
  }

  /// Mimics a dispute ruling of `refund`: reopens the milestone for rework and
  /// leaves the job in progress (the issue-#1 fix).
  void resolveRefund(String jobId, String milestoneId, {String? note}) {
    _update(
        milestoneId,
        (m) => _withStatus(m, MilestoneStatus.pending,
            reworkNote: note, reworkCount: m.reworkCount + 1));
  }

  @override
  Stream<List<Milestone>> watchMilestones(String jobId) async* {
    List<Milestone> mine() =>
        _milestones.where((m) => m.jobId == jobId).toList()
          ..sort((a, b) => a.order.compareTo(b.order));
    yield mine();
    await for (final _ in _changes.stream) {
      yield mine();
    }
  }

  @override
  Stream<List<Milestone>> watchProviderMilestones(String providerId) async* {
    List<Milestone> mine() =>
        _milestones.where((m) => m.providerId == providerId).toList();
    yield mine();
    await for (final _ in _changes.stream) {
      yield mine();
    }
  }

  @override
  Future<void> submitMilestone(String jobId, String milestoneId,
      {String? note}) async {
    _update(milestoneId,
        (m) => _withStatus(m, MilestoneStatus.submitted, note: note));
  }

  @override
  Future<void> fundMilestone(String jobId, String milestoneId) async {
    // Only a client-approved (pending) milestone is fundable, mirroring the
    // Cloud Function's precondition.
    final m = _milestones.cast<Milestone?>().firstWhere(
        (m) => m!.id == milestoneId,
        orElse: () => null);
    if (m == null || m.status != MilestoneStatus.pending) return;
    _update(milestoneId, (m) => _withStatus(m, MilestoneStatus.funded));
  }

  @override
  Future<void> releaseMilestone(String jobId, String milestoneId) async {
    _update(milestoneId, (m) => _withStatus(m, MilestoneStatus.released));
    _maybeComplete(jobId);
  }

  /// Completes the job when every milestone is terminal — `released`, or a
  /// legacy `resolved`, matching the production `isTerminal`.
  void _maybeComplete(String jobId) {
    final allTerminal = _milestones.where((m) => m.jobId == jobId).every((m) =>
        m.status == MilestoneStatus.released ||
        m.status == MilestoneStatus.resolved);
    if (allTerminal) jobs.complete(jobId);
  }
}

/// In-memory [WalletRepository]; records the amounts of top-up/withdraw calls
/// so tests can assert them. The ledger stays empty.
class FakeWalletRepository implements WalletRepository {
  final topUps = <int>[];
  final withdrawals = <int>[];

  @override
  Future<void> topUp(int amountSen) async => topUps.add(amountSen);

  @override
  Future<void> withdraw(int amountSen) async => withdrawals.add(amountSen);

  @override
  Stream<List<LedgerEntry>> watchMyTransactions(String uid) async* {
    yield const [];
  }
}

/// In-memory [DisputeRepository]. Raising a dispute mimics the Cloud
/// Function: it freezes the milestone (via [milestones]) and opens a dispute;
/// resolving records the ruling and closes it.
class FakeDisputeRepository implements DisputeRepository {
  FakeDisputeRepository([List<Dispute> seed = const []]) : _open = [...seed];

  /// Linked by [buildApp] so a raised dispute flips the milestone's status,
  /// like the real transaction does.
  FakeMilestoneRepository? milestones;

  final List<Dispute> _open;
  final _changes = StreamController<void>.broadcast();

  final raised = <({String jobId, String milestoneId, String statement})>[];
  final resolutions = <String, DisputeResolution>{};
  String? lastRulingNote;

  @override
  Future<void> raiseDispute({
    required String jobId,
    required String milestoneId,
    required String statement,
    List<String> evidenceUrls = const [],
  }) async {
    raised.add(
        (jobId: jobId, milestoneId: milestoneId, statement: statement));
    milestones?._update(
        milestoneId,
        (m) =>
            milestones!._withStatus(m, MilestoneStatus.disputed));
    _open.add(Dispute(
      id: 'disp-${_open.length + 1}',
      jobId: jobId,
      jobTitle: 'Job $jobId',
      milestoneId: milestoneId,
      milestoneDescription: 'Milestone $milestoneId',
      amountSen: 0,
      raisedByUid: 'uid-1',
      raisedByRole: 'requestor',
      requestorId: 'uid-1',
      providerId: 'prov-1',
      statement: statement,
      evidenceUrls: evidenceUrls,
      createdAt: DateTime.now(),
    ));
    _changes.add(null);
  }

  @override
  Future<void> resolveDispute({
    required String disputeId,
    required DisputeResolution resolution,
    required String rulingNote,
  }) async {
    resolutions[disputeId] = resolution;
    lastRulingNote = rulingNote;
    // Mirror the Cloud Function's milestone effect: release closes it,
    // refund reopens it for rework (job stays in progress).
    final d = _open.cast<Dispute?>().firstWhere((d) => d!.id == disputeId,
        orElse: () => null);
    if (d != null && milestones != null) {
      if (resolution == DisputeResolution.release) {
        milestones!.resolveRelease(d.jobId, d.milestoneId);
      } else {
        milestones!.resolveRefund(d.jobId, d.milestoneId, note: rulingNote);
      }
    }
    _open.removeWhere((d) => d.id == disputeId);
    _changes.add(null);
  }

  @override
  Stream<List<Dispute>> watchOpenDisputes() async* {
    yield List.of(_open);
    await for (final _ in _changes.stream) {
      yield List.of(_open);
    }
  }
}

/// In-memory [VerificationRepository]; seeded with pending applicants. Records
/// decisions so tests can assert an approve/reject removed the item.
class FakeVerificationRepository implements VerificationRepository {
  FakeVerificationRepository([List<PendingVerification> pending = const []])
      : _pending = [...pending];

  final List<PendingVerification> _pending;
  final _changes = StreamController<void>.broadcast();

  final decisions = <String, bool>{};
  String? lastReason;

  @override
  Stream<List<PendingVerification>> watchPending() async* {
    yield List.of(_pending);
    await for (final _ in _changes.stream) {
      yield List.of(_pending);
    }
  }

  @override
  Future<List<VerificationDocument>> loadIdentityDocuments(String uid) async =>
      const [
        VerificationDocument(
            label: 'Identity Document', url: 'https://fake.storage/id.jpg'),
      ];

  @override
  Future<void> decide({
    required String uid,
    required bool approved,
    String? reason,
  }) async {
    decisions[uid] = approved;
    lastReason = reason;
    _pending.removeWhere((p) => p.uid == uid);
    _changes.add(null);
  }
}

/// In-memory [ReviewRepository]; seeded with a fixed list of reviews. Records
/// left reviews and the aggregates the Cloud Function producer would maintain
/// (dedupe + ratingSum/ratingCount); the review sub-score mirrors what the
/// server-side trust recompute derives from those aggregates.
class FakeReviewRepository implements ReviewRepository {
  FakeReviewRepository([List<Review> reviews = const []])
      : _reviews = [...reviews];

  final List<Review> _reviews;
  final _ids = <String>{};

  final left = <Review>[];
  final ratingSums = <String, int>{};
  final ratingCounts = <String, int>{};
  final reviewScores = <String, int>{};

  @override
  Stream<List<Review>> watchReviews(String userId) async* {
    yield _reviews;
  }

  @override
  Future<void> leaveReview({
    required String revieweeId,
    required Review review,
  }) async {
    final id = '$revieweeId/${review.jobId}_${review.reviewerId}';
    if (!_ids.add(id)) throw const ReviewAlreadyExistsException();
    final sum = (ratingSums[revieweeId] ?? 0) + review.rating;
    final count = (ratingCounts[revieweeId] ?? 0) + 1;
    ratingSums[revieweeId] = sum;
    ratingCounts[revieweeId] = count;
    reviewScores[revieweeId] = PlatformConfig.trustBreakdownFor(
      ratingSum: sum,
      ratingCount: count,
      verificationStatus: 'approved',
      jobsCompleted: 0,
      disputesLost: 0,
      hasDisplayName: false,
      hasPhone: false,
      hasBio: false,
      hasPhoto: false,
      hasLocation: false,
    ).reviewScore;
    left.add(review);
  }

  /// Reported reviews, recorded as (revieweeId, reviewId, reason).
  final flags = <(String, String, String)>[];

  @override
  Future<void> flagReview({
    required String revieweeId,
    required String reviewId,
    required String reason,
    required String flaggedByUid,
  }) async {
    flags.add((revieweeId, reviewId, reason));
  }
}

/// In-memory [ModerationRepository]; seeded with flagged reviews. Records
/// rulings so tests can assert hide/keep cleared the queue.
class FakeModerationRepository implements ModerationRepository {
  FakeModerationRepository([List<FlaggedReview> seed = const []])
      : _flagged = [...seed];

  final List<FlaggedReview> _flagged;
  final _changes = StreamController<void>.broadcast();

  /// reviewId → hide.
  final rulings = <String, bool>{};

  @override
  Stream<List<FlaggedReview>> watchFlaggedReviews() async* {
    yield List.of(_flagged);
    await for (final _ in _changes.stream) {
      yield List.of(_flagged);
    }
  }

  @override
  Future<void> moderateReview({
    required String revieweeId,
    required String reviewId,
    required bool hide,
  }) async {
    rulings[reviewId] = hide;
    _flagged.removeWhere((f) => f.review.id == reviewId);
    _changes.add(null);
  }
}

/// In-memory [NotificationRepository]; seeded with notifications. Tracks
/// token registration so tests can assert the sign-in/out lifecycle.
class FakeNotificationRepository implements NotificationRepository {
  FakeNotificationRepository([List<AppNotification> seed = const []])
      : _items = [...seed];

  final List<AppNotification> _items;
  final _changes = StreamController<void>.broadcast();

  /// Uids whose token is currently registered on this "device".
  final registeredTokens = <String>{};

  @override
  Stream<List<AppNotification>> watchMine(String uid) async* {
    yield List.of(_items);
    await for (final _ in _changes.stream) {
      yield List.of(_items);
    }
  }

  @override
  Stream<int> watchUnreadCount(String uid) =>
      watchMine(uid).map((items) => items.where((n) => !n.read).length);

  @override
  Future<void> markRead(String uid, String notificationId) async {
    final i = _items.indexWhere((n) => n.id == notificationId);
    if (i == -1) return;
    final n = _items[i];
    _items[i] = AppNotification(
      id: n.id,
      type: n.type,
      title: n.title,
      body: n.body,
      route: n.route,
      read: true,
      createdAt: n.createdAt,
    );
    _changes.add(null);
  }

  @override
  Future<void> markAllRead(String uid) async {
    for (var i = 0; i < _items.length; i++) {
      final n = _items[i];
      _items[i] = AppNotification(
        id: n.id,
        type: n.type,
        title: n.title,
        body: n.body,
        route: n.route,
        read: true,
        createdAt: n.createdAt,
      );
    }
    _changes.add(null);
  }

  @override
  Future<void> registerToken(String uid) async => registeredTokens.add(uid);

  @override
  Future<void> removeToken(String uid) async => registeredTokens.remove(uid);
}

/// [AssistRepository] returning canned suggestions (or, by default, null —
/// proving the post-job form works with the assist entirely unavailable).
class FakeAssistRepository implements AssistRepository {
  FakeAssistRepository({this.description, this.priceRange});

  final String? description;
  final ({int minSen, int maxSen})? priceRange;

  @override
  Future<String?> suggestDescription({
    required String category,
    required String roughText,
  }) async =>
      description;

  @override
  Future<({int minSen, int maxSen})?> suggestPriceRange({
    required String category,
    required String description,
  }) async =>
      priceRange;
}

/// No-op [PushService] — tests exercise the in-app surfaces only.
class FakePushService implements PushService {
  int permissionRequests = 0;

  @override
  Future<void> init({
    required void Function(String route) onOpenRoute,
    required void Function() onTokenRefresh,
  }) async {}

  @override
  Future<void> requestPermission() async {
    permissionRequests++;
  }
}

/// In-memory [StatsRepository] returning fixed numbers.
class FakeStatsRepository implements StatsRepository {
  FakeStatsRepository([PlatformStats? stats])
      : _stats = stats ??
            const PlatformStats(
              requestors: 11,
              providers: 12,
              openJobs: 13,
              inProgressJobs: 14,
              completedJobs: 15,
              pendingVerifications: 16,
              openDisputes: 17,
              releasedVolumeSen: 1234500,
            );

  final PlatformStats _stats;

  /// How many times the Trust Score backfill was requested.
  int recomputeCalls = 0;

  @override
  Future<PlatformStats> load() async => _stats;

  @override
  Future<int> recomputeTrustScores() async {
    recomputeCalls++;
    return _stats.totalUsers;
  }
}

/// In-memory [ChatRepository]. Streams re-emit whenever anything changes so
/// the conversation list, thread and unread badge update live.
class FakeChatRepository implements ChatRepository {
  FakeChatRepository([List<Conversation> seed = const []])
      : _conversations = [...seed];

  final List<Conversation> _conversations;
  final _messages = <String, List<Message>>{};
  final _changes = StreamController<void>.broadcast();

  void _notify() => _changes.add(null);

  Conversation? _byId(String id) => _conversations
      .cast<Conversation?>()
      .firstWhere((c) => c!.id == id, orElse: () => null);

  /// Rebuilds a conversation with overrides — the fake's stand-in for a
  /// Firestore update, since [Conversation] is immutable.
  Conversation _rebuild(
    Conversation c, {
    String? lastMessageText,
    String? lastMessageSenderId,
    DateTime? lastMessageAt,
    Map<String, int>? unreadCounts,
  }) =>
      Conversation(
        id: c.id,
        jobId: c.jobId,
        jobTitle: c.jobTitle,
        requestorId: c.requestorId,
        requestorName: c.requestorName,
        providerId: c.providerId,
        providerName: c.providerName,
        lastMessageText: lastMessageText ?? c.lastMessageText,
        lastMessageSenderId: lastMessageSenderId ?? c.lastMessageSenderId,
        lastMessageAt: lastMessageAt ?? c.lastMessageAt,
        unreadCounts: unreadCounts ?? c.unreadCounts,
      );

  @override
  Future<String> openConversation(Job job) async {
    final id = '${job.id}_${job.acceptedProviderId}';
    if (_byId(id) == null) {
      _conversations.add(Conversation(
        id: id,
        jobId: job.id,
        jobTitle: job.title,
        requestorId: job.requestorId,
        requestorName: job.requestorName,
        providerId: job.acceptedProviderId!,
        providerName: job.acceptedProviderName ?? 'Provider',
        lastMessageAt: DateTime.now(),
      ));
      _notify();
    }
    return id;
  }

  @override
  Stream<List<Conversation>> watchConversations(String uid) async* {
    List<Conversation> mine() =>
        _conversations.where((c) => c.participantIds.contains(uid)).toList();
    yield mine();
    await for (final _ in _changes.stream) {
      yield mine();
    }
  }

  @override
  Stream<Conversation?> watchConversation(String conversationId) async* {
    yield _byId(conversationId);
    await for (final _ in _changes.stream) {
      yield _byId(conversationId);
    }
  }

  @override
  Stream<List<Message>> watchMessages(String conversationId) async* {
    List<Message> newestFirst() =>
        (_messages[conversationId] ?? const []).reversed.toList();
    yield newestFirst();
    await for (final _ in _changes.stream) {
      yield newestFirst();
    }
  }

  @override
  Future<void> sendMessage({
    required Conversation conversation,
    required String senderId,
    required String text,
  }) async {
    final list = _messages.putIfAbsent(conversation.id, () => []);
    list.add(Message(
      id: 'm-${list.length + 1}',
      senderId: senderId,
      text: text.trim(),
      createdAt: DateTime.now(),
    ));
    final i = _conversations.indexWhere((c) => c.id == conversation.id);
    if (i != -1) {
      final c = _conversations[i];
      final recipient =
          c.participantIds.firstWhere((id) => id != senderId, orElse: () => '');
      _conversations[i] = _rebuild(
        c,
        lastMessageText: text.trim(),
        lastMessageSenderId: senderId,
        lastMessageAt: DateTime.now(),
        unreadCounts: {
          ...c.unreadCounts,
          if (recipient.isNotEmpty) recipient: c.unreadFor(recipient) + 1,
        },
      );
    }
    _notify();
  }

  @override
  Future<void> markRead(String conversationId, String uid) async {
    final i = _conversations.indexWhere((c) => c.id == conversationId);
    if (i == -1) return;
    final c = _conversations[i];
    _conversations[i] =
        _rebuild(c, unreadCounts: {...c.unreadCounts, uid: 0});
    _notify();
  }

  @override
  Stream<int> watchTotalUnread(String uid) async* {
    int total() => _conversations
        .where((c) => c.participantIds.contains(uid))
        .fold(0, (sum, c) => sum + c.unreadFor(uid));
    yield total();
    await for (final _ in _changes.stream) {
      yield total();
    }
  }
}

/// Builds a sample job for tests (open by default; pass [status] and the
/// accepted-provider fields to seed an in-progress or completed job).
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
}) =>
    Job(
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
    );

/// Builds a sample pending bid on [jobId] for tests. Defaults to an
/// established provider (visible score); pass `scoreVisible: false` for the
/// "New provider" case.
Bid sampleBid({
  String jobId = 'job-1',
  String providerId = 'prov-1',
  String providerName = 'Pro Fixer',
  int trustScore = 800,
  bool scoreVisible = true,
  int amountSen = 15000,
}) =>
    Bid(
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

Widget buildApp(FakeAuthRepository auth,
    {List<Job> jobs = const [],
    List<Bid> bids = const [],
    List<Review> reviews = const [],
    List<Milestone> milestones = const [],
    FakeReviewRepository? review,
    FakeVerificationRepository? verification,
    FakeChatRepository? chat,
    FakeDisputeRepository? dispute,
    FakeModerationRepository? moderation,
    FakeStatsRepository? stats,
    FakeNotificationRepository? notifications,
    FakeAssistRepository? assist}) {
  final jobRepo = FakeJobRepository(jobs);
  final milestoneRepo = FakeMilestoneRepository(jobRepo, milestones);
  final disputeRepo = dispute ?? FakeDisputeRepository();
  disputeRepo.milestones ??= milestoneRepo;
  return FairBidApp(
    authRepository: auth,
    onboardingRepository: FakeOnboardingRepository(auth),
    requestorOnboardingRepository: FakeRequestorOnboardingRepository(auth),
    documentStorageRepository: FakeDocumentStorageRepository(),
    jobRepository: jobRepo,
    bidRepository: FakeBidRepository(jobRepo, bids),
    reviewRepository: review ?? FakeReviewRepository(reviews),
    verificationRepository: verification ?? FakeVerificationRepository(),
    chatRepository: chat ?? FakeChatRepository(),
    milestoneRepository: milestoneRepo,
    walletRepository: FakeWalletRepository(),
    disputeRepository: disputeRepo,
    moderationRepository: moderation ?? FakeModerationRepository(),
    statsRepository: stats ?? FakeStatsRepository(),
    notificationRepository: notifications ?? FakeNotificationRepository(),
    pushService: FakePushService(),
    assistRepository: assist ?? FakeAssistRepository(),
  );
}

Future<void> fillField(WidgetTester tester, String label, String text) async {
  // Field labels are external; find the TextFormField below the label text.
  final direct = find.widgetWithText(TextFormField, label);
  final field =
      direct.evaluate().isEmpty ? _fieldBelowLabel(tester, label) : direct;
  await tester.ensureVisible(field); // scroll into view on tall forms
  await tester.pumpAndSettle();
  await tester.enterText(field, text);
}

Finder _fieldBelowLabel(WidgetTester tester, String label) {
  // Fields render label + TextFormField inside one AppTextField column.
  final column = find.ancestor(
    of: find.text(label),
    matching: find.byType(Column),
  );
  return find
      .descendant(of: column.first, matching: find.byType(TextFormField))
      .first;
}

void main() {
  group('Validators', () {
    test('email rejects malformed and accepts valid', () {
      expect(Validators.email(''), isNotNull);
      expect(Validators.email('not-an-email'), isNotNull);
      expect(Validators.email('a@b.com'), isNull);
    });

    test('password requires 8+ characters (per design mock)', () {
      expect(Validators.password('1234567'), isNotNull);
      expect(Validators.password('12345678'), isNull);
    });

    test('confirmPassword must match', () {
      expect(Validators.confirmPassword('abc', 'xyz'), isNotNull);
      expect(Validators.confirmPassword('abc', 'abc'), isNull);
    });
  });

  group('Login', () {
    testWidgets('shows the expected fields and tabs', (tester) async {
      await tester.pumpWidget(buildApp(FakeAuthRepository()));
      await tester.pumpAndSettle();

      expect(find.text('Welcome to FairBid'), findsOneWidget);
      expect(find.text('Log In'), findsWidgets); // tab + button
      expect(find.text('Sign Up'), findsOneWidget);
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(find.text('Continue with Google'), findsOneWidget);
    });

    testWidgets('typed input text has a visible colour', (tester) async {
      await tester.pumpWidget(buildApp(FakeAuthRepository()));
      await tester.pumpAndSettle();

      final editable =
          tester.widget<EditableText>(find.byType(EditableText).first);
      expect(editable.style.color, isNotNull);
      expect(editable.style.color, isNot(Colors.white));
    });

    testWidgets('empty submit shows validation errors', (tester) async {
      await tester.pumpWidget(buildApp(FakeAuthRepository()));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();

      expect(find.text('Email is required.'), findsOneWidget);
      expect(find.text('Password is required.'), findsOneWidget);
    });

    testWidgets('successful sign-in lands on home', (tester) async {
      await tester.pumpWidget(buildApp(FakeAuthRepository()));
      await tester.pumpAndSettle();

      await fillField(tester, 'Email', 'test@fairbid.app');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();

      // Lands on the app shell (requestor home).
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('Hello, Test'), findsOneWidget);
    });

    testWidgets('failed sign-in shows an error banner', (tester) async {
      final repo = FakeAuthRepository()
        ..failWith = const AuthException('Incorrect email or password.');
      await tester.pumpWidget(buildApp(repo));
      await tester.pumpAndSettle();

      await fillField(tester, 'Email', 'test@fairbid.app');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();

      expect(find.text('Incorrect email or password.'), findsOneWidget);
      expect(find.text('You are signed in'), findsNothing);
    });
  });

  group('Register', () {
    Future<void> openRegister(WidgetTester tester) async {
      await tester.tap(find.text('Sign Up'));
      await tester.pumpAndSettle();
      expect(find.text('Join FairBid'), findsOneWidget);
    }

    Future<void> fillRegisterForm(WidgetTester tester) async {
      await fillField(tester, 'FULL NAME', 'New User');
      await fillField(tester, 'EMAIL ADDRESS', 'new@fairbid.app');
      await fillField(tester, 'PASSWORD', 'secret123');
      await fillField(tester, 'CONFIRM PASSWORD', 'secret123');
      final checkbox = find.byType(Checkbox);
      await tester.ensureVisible(checkbox);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
    }

    Future<void> submit(WidgetTester tester) async {
      final button = find.widgetWithText(FilledButton, 'Sign Up');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    testWidgets('as requestor (Hire) is redirected into onboarding',
        (tester) async {
      // A brand-new requestor has not completed onboarding yet.
      await tester.pumpWidget(
          buildApp(FakeAuthRepository()..onboardingComplete = false));
      await tester.pumpAndSettle();
      await openRegister(tester);

      await tester.tap(find.text('Hire'));
      await tester.pumpAndSettle();
      await fillRegisterForm(tester);
      await submit(tester);

      // Requestor onboarding stage 1 (Account Type).
      expect(find.text('How will you hire?'), findsOneWidget);
      expect(find.text('Individual'), findsOneWidget);
      expect(find.text('Business'), findsOneWidget);
      expect(find.text('You are signed in'), findsNothing);
    });

    testWidgets('requestor completes onboarding and lands on home',
        (tester) async {
      await tester.pumpWidget(
          buildApp(FakeAuthRepository()..onboardingComplete = false));
      await tester.pumpAndSettle();
      await openRegister(tester);
      await tester.tap(find.text('Hire'));
      await tester.pumpAndSettle();
      await fillRegisterForm(tester);
      await submit(tester);

      // Stage 1 → pick Individual → Continue.
      await tester.tap(find.text('Individual'));
      await tester.pumpAndSettle();
      final stage1Continue = find.widgetWithText(FilledButton, 'Continue');
      await tester.ensureVisible(stage1Continue);
      await tester.tap(stage1Continue);
      await tester.pumpAndSettle();

      // Stage 2 → fill required details → Continue.
      await fillField(tester, 'Full Name', 'Jane Client');
      await fillField(tester, 'Phone Number', '0123456789');
      await fillField(tester, 'Default Location', 'Kuala Lumpur');
      final continueBtn = find.widgetWithText(FilledButton, 'Continue');
      await tester.ensureVisible(continueBtn);
      await tester.tap(continueBtn);
      await tester.pumpAndSettle();

      // Stage 3 → Skip verification → finish.
      final skip = find.widgetWithText(OutlinedButton, 'Skip for now');
      await tester.ensureVisible(skip);
      await tester.tap(skip);
      await tester.pumpAndSettle();

      // Onboarding complete → lands on the app shell.
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('as provider (Work) is redirected into onboarding',
        (tester) async {
      await tester.pumpWidget(buildApp(FakeAuthRepository()));
      await tester.pumpAndSettle();
      await openRegister(tester);

      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();
      await fillRegisterForm(tester);
      await submit(tester);

      // Provider with verificationStatus 'none' → onboarding stage 2.
      expect(find.text('Choose Provider Type'), findsOneWidget);
      expect(find.text('Individual / Freelancer'), findsOneWidget);
      expect(find.text('Registered Business'), findsOneWidget);
    });

    testWidgets('onboarding continue unlocks after picking a provider type',
        (tester) async {
      await tester.pumpWidget(buildApp(FakeAuthRepository()));
      await tester.pumpAndSettle();
      await openRegister(tester);
      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();
      await fillRegisterForm(tester);
      await submit(tester);

      // Continue starts disabled.
      final continueButton = find.widgetWithText(FilledButton, 'Continue');
      expect(
          tester.widget<FilledButton>(continueButton).onPressed, isNull);

      // Selecting a type enables it; tapping moves to identity verification.
      await tester.tap(find.text('Individual / Freelancer'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(continueButton);
      await tester.tap(continueButton);
      await tester.pumpAndSettle();

      expect(find.text('Verify your identity'), findsOneWidget);
    });
  });

  group('App shell', () {
    Future<void> login(WidgetTester tester) async {
      await fillField(tester, 'Email', 'test@fairbid.app');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the four bottom-nav tabs after sign-in',
        (tester) async {
      await tester.pumpWidget(buildApp(FakeAuthRepository()));
      await tester.pumpAndSettle();
      await login(tester);

      expect(find.byType(NavigationBar), findsOneWidget);
      for (final tab in ['Home', 'My Jobs', 'Messages', 'Profile']) {
        expect(find.text(tab), findsWidgets);
      }
    });

    testWidgets('profile tab shows the user name and logout', (tester) async {
      // Tall surface so the whole profile (incl. bottom "Log out") lays out.
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(buildApp(FakeAuthRepository()));
      await tester.pumpAndSettle();
      await login(tester);

      await tester.tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Profile'),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Test User'), findsWidgets);
      expect(find.widgetWithText(OutlinedButton, 'Log out'), findsOneWidget);
    });

    testWidgets('verified provider home shows stat cards', (tester) async {
      final repo = FakeAuthRepository()..verificationStatus = 'approved';
      await tester.pumpWidget(buildApp(repo));
      await tester.pumpAndSettle();
      await openRegisterAs(tester, 'Work');

      // Provider, approved → not gated → provider home with its stat cards.
      expect(find.byType(StatCard), findsWidgets);
    });
  });

  group('Profile models', () {
    test('AppUser exposes profile field defaults', () {
      const user = AppUser(
        uid: 'u',
        email: 'e@x.com',
        displayName: 'A',
        role: UserRole.provider,
      );
      expect(user.bio, isNull);
      expect(user.walletBalanceSen, 0);
      expect(user.ratingCount, 0);
      expect(user.ratingSum, 0);
      expect(user.averageRating, isNull);
    });

    test('AppUser.averageRating divides sum by count', () {
      const user = AppUser(
        uid: 'u',
        email: 'e@x.com',
        displayName: 'A',
        role: UserRole.provider,
        ratingCount: 4,
        ratingSum: 18,
      );
      expect(user.averageRating, 4.5);
    });

    test('Review round-trips through toMap/fromMap', () {
      const review = Review(
        id: 'r1',
        reviewerId: 'rev',
        reviewerName: 'Sarah Connor',
        rating: 5,
        comment: 'Great work.',
        jobId: 'job-1',
        jobTitle: 'Fix sink',
      );
      final parsed = Review.fromMap('r1', review.toMap());
      expect(parsed.reviewerName, 'Sarah Connor');
      expect(parsed.rating, 5);
      expect(parsed.comment, 'Great work.');
      expect(parsed.jobId, 'job-1');
      expect(parsed.jobTitle, 'Fix sink');
    });
  });

  group('Profile screen', () {
    Future<void> loginRequestor(WidgetTester tester) async {
      await fillField(tester, 'Email', 'test@fairbid.app');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();
    }

    Future<void> openProfileTab(WidgetTester tester) async {
      await tester.tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Profile'),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('shows Earnings & Payouts for a provider', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()..verificationStatus = 'approved';
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();
      await openRegisterAs(tester, 'Work');
      await openProfileTab(tester);

      expect(find.text('Earnings & Payouts'), findsOneWidget);
    });

    testWidgets('hides Earnings & Payouts for a requestor', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(buildApp(FakeAuthRepository()));
      await tester.pumpAndSettle();
      await loginRequestor(tester);
      await openProfileTab(tester);

      expect(find.text('Earnings & Payouts'), findsNothing);
    });

    testWidgets('edit profile updates the name and About', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(buildApp(FakeAuthRepository()));
      await tester.pumpAndSettle();
      await loginRequestor(tester);
      await openProfileTab(tester);

      await tester.tap(find.text('Edit').first);
      await tester.pumpAndSettle();

      final fields = find.descendant(
        of: find.byType(EditProfileScreen),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(fields.at(0), 'Brand New Name');
      await tester.enterText(fields.at(3), 'A fresh bio about my work.');
      final save = find.widgetWithText(FilledButton, 'Save');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(find.text('Brand New Name'), findsWidgets);
      expect(find.text('A fresh bio about my work.'), findsOneWidget);
    });

    testWidgets('reviews section shows the empty state with no reviews',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(buildApp(FakeAuthRepository()));
      await tester.pumpAndSettle();
      await loginRequestor(tester);
      await openProfileTab(tester);

      expect(find.text('No reviews yet'), findsOneWidget);
    });

    testWidgets('reviews section renders a seeded review', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final review = Review(
        id: 'r1',
        reviewerId: 'someone',
        reviewerName: 'Sarah Connor',
        rating: 5,
        comment: 'Communications were clear.',
        createdAt: DateTime.now(),
      );
      await tester
          .pumpWidget(buildApp(FakeAuthRepository(), reviews: [review]));
      await tester.pumpAndSettle();
      await loginRequestor(tester);
      await openProfileTab(tester);

      expect(find.text('Sarah Connor'), findsOneWidget);
      expect(find.text('"Communications were clear."'), findsOneWidget);
    });

    testWidgets('Trust Score card shows the New Provider state until earned',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // Approved but only 1 completed job → below the visibility gate.
      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..jobsCompleted = 1;
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();
      await openRegisterAs(tester, 'Work');
      await openProfileTab(tester);

      expect(find.text('New Provider'), findsOneWidget);
      // The four real sub-bars replace the old decorative ones.
      expect(find.text('Track Record'), findsOneWidget);
      expect(find.text('Verification'), findsOneWidget);
      expect(find.textContaining('/100'), findsNothing); // no headline number
    });

    testWidgets('Trust Score card shows the number once earned',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..jobsCompleted = 5
        ..ratingSum = 90
        ..ratingCount = 20;
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();
      await openRegisterAs(tester, 'Work');
      await openProfileTab(tester);

      expect(find.text('New Provider'), findsNothing);
      expect(find.textContaining('/100'), findsOneWidget);
    });

    testWidgets('earnings screen shows the balance and Withdraw',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..walletBalanceSen = 85000;
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();
      await openRegisterAs(tester, 'Work');
      await openProfileTab(tester);

      await tester.tap(find.text('Earnings & Payouts'));
      await tester.pumpAndSettle();

      expect(find.text('RM 850.00'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Withdraw'), findsOneWidget);
    });

    testWidgets('delete account cancel keeps the user signed in',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(buildApp(FakeAuthRepository()));
      await tester.pumpAndSettle();
      await loginRequestor(tester);
      await openProfileTab(tester);

      await tester.tap(find.text('Delete Account'));
      await tester.pumpAndSettle();
      expect(find.text('Delete account?'), findsOneWidget);
      expect(find.text('Confirm your password'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Delete account?'), findsNothing);
      expect(find.text('Delete Account'), findsOneWidget);
    });

    testWidgets(
        'delete account confirmed with password signs the user out',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(buildApp(FakeAuthRepository()));
      await tester.pumpAndSettle();
      await loginRequestor(tester);
      await openProfileTab(tester);

      await tester.tap(find.text('Delete Account'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Confirm your password'),
          'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      // Signed out -> router redirects back to the login screen.
      expect(find.text('Delete account?'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Log In'), findsOneWidget);
    });

    testWidgets('delete account failure shows an error and stays signed in',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository();
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();
      await loginRequestor(tester);
      await openProfileTab(tester);

      auth.failWith = const AuthException('Incorrect password.');
      await tester.tap(find.text('Delete Account'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'Confirm your password'), 'wrong');
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Incorrect password.'), findsOneWidget);
      expect(find.text('Delete Account'), findsOneWidget);
    });
  });

  group('Money & distance', () {
    test('formatRm formats sen as RM', () {
      expect(formatRm(0), 'RM 0.00');
      expect(formatRm(12550), 'RM 125.50');
      expect(formatRm(100000), 'RM 1,000.00');
    });

    test('formatBudget handles fixed, range and hourly', () {
      expect(formatBudget(), isNull);
      expect(formatBudget(minSen: 10000), 'RM 100.00');
      expect(formatBudget(minSen: 10000, maxSen: 25000),
          'RM 100.00 – RM 250.00');
      expect(formatBudget(minSen: 5000, hourly: true), 'RM 50.00/hr');
    });

    test('parseRmToSen parses money text', () {
      expect(parseRmToSen(''), isNull);
      expect(parseRmToSen('125.50'), 12550);
      expect(parseRmToSen('1,000'), 100000);
    });

    test('distanceKm ~0 for same point, positive otherwise', () {
      const kl = LatLng(3.139, 101.6869);
      expect(distanceKm(kl, kl), lessThan(0.001));
      expect(distanceKm(kl, const LatLng(3.2, 101.75)), greaterThan(1));
    });
  });

  group('Jobs', () {
    test('Job round-trips through toMap/fromMap', () {
      final job = sampleJob();
      final map = {
        ...job.toMap(),
        'status': 'open',
        'bidCount': 3,
        'createdAt': null,
      };
      final parsed = Job.fromMap('job-1', map);
      expect(parsed.title, 'Fix leaking sink');
      expect(parsed.category, 'Plumbing');
      expect(parsed.location.address, 'Bangsar, KL');
      expect(parsed.budget?.minSen, 10000);
      expect(parsed.bidCount, 3);
    });

    Future<void> login(WidgetTester tester) async {
      await fillField(tester, 'Email', 'a@b.com');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();
    }

    testWidgets('requestor home lists their posted jobs', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester
          .pumpWidget(buildApp(FakeAuthRepository(), jobs: [sampleJob()]));
      await tester.pumpAndSettle();
      await login(tester);

      expect(find.text('Fix leaking sink'), findsWidgets);
    });

    testWidgets('provider home shows nearby jobs with a base location',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..baseLat = 3.139
        ..baseLng = 101.6869;
      await tester.pumpWidget(buildApp(auth, jobs: [sampleJob()]));
      await tester.pumpAndSettle();
      await openRegisterAs(tester, 'Work');

      expect(find.text('Fix leaking sink'), findsWidgets);
    });
  });

  group('Bidding', () {
    test('Bid round-trips through toMap/fromMap', () {
      final bid = sampleBid();
      final map = {...bid.toMap(), 'status': 'pending', 'createdAt': null};
      final parsed = Bid.fromMap('job-1', 'prov-1', map);
      expect(parsed.providerName, 'Pro Fixer');
      expect(parsed.providerTrustScore, 800);
      expect(parsed.amountSen, 15000);
      expect(parsed.estimatedDuration, 'Less than 1 week');
      expect(parsed.status, BidStatus.pending);
    });

    /// Registers as a provider and opens the seeded job's detail screen.
    Future<void> openJobAsProvider(WidgetTester tester) async {
      await openRegisterAs(tester, 'Work');
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();
      expect(find.text('Job Details'), findsOneWidget);
    }

    testWidgets('approved provider submits a bid (with form validation)',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..baseLat = 3.139
        ..baseLng = 101.6869;
      // Someone else's job, so the provider section (not bids) is shown.
      await tester.pumpWidget(
          buildApp(auth, jobs: [sampleJob(requestorId: 'req-9')]));
      await tester.pumpAndSettle();
      await openJobAsProvider(tester);

      // Open the sheet and submit empty → validation errors.
      await tester.tap(find.widgetWithText(FilledButton, 'Submit a bid'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Submit Bid'));
      await tester.pumpAndSettle();
      expect(find.text('Enter your bid amount.'), findsOneWidget);
      expect(find.text('Pick a duration.'), findsOneWidget);
      expect(find.text('Message is required.'), findsOneWidget);

      // Fill the form and submit.
      await fillField(tester, 'Your Bid (RM)', '150');
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Less than 1 week').last);
      await tester.pumpAndSettle();
      await fillField(tester, 'Proposal Message', 'I can start tomorrow.');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Submit Bid'));
      await tester.pumpAndSettle();

      // Sheet closed; the detail now shows the live bid with Withdraw.
      expect(find.text('Your bid'), findsOneWidget);
      expect(find.text('RM 150.00'), findsOneWidget);
      expect(
          find.widgetWithText(OutlinedButton, 'Withdraw bid'), findsOneWidget);

      // Withdrawing (after confirming the dialog) returns to the submit state.
      await tester.tap(find.widgetWithText(OutlinedButton, 'Withdraw bid'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Withdraw'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Submit a bid'), findsOneWidget);
    });

    testWidgets('pending provider sees the locked state', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()
        ..verificationStatus = 'pending'
        ..baseLat = 3.139
        ..baseLng = 101.6869;
      await tester.pumpWidget(
          buildApp(auth, jobs: [sampleJob(requestorId: 'req-9')]));
      await tester.pumpAndSettle();
      await openJobAsProvider(tester);

      expect(find.text('Bidding locked'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Submit a bid'), findsNothing);
    });

    testWidgets('requestor sees a bid and accepting flips the job to '
        'in progress', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(buildApp(FakeAuthRepository(),
          jobs: [sampleJob()], bids: [sampleBid()]));
      await tester.pumpAndSettle();
      await fillField(tester, 'Email', 'a@b.com');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();

      // Open own job → the bid list shows the provider's offer.
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();
      expect(find.text('Pro Fixer'), findsOneWidget);
      expect(find.text('RM 150.00'), findsOneWidget);

      // Accept → confirm in the dialog.
      await tester.ensureVisible(
          find.widgetWithText(FilledButton, 'Accept Bid'));
      await tester.tap(find.widgetWithText(FilledButton, 'Accept Bid'));
      await tester.pumpAndSettle();
      expect(find.text('Accept this bid?'), findsOneWidget);
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Accept Bid'),
      ));
      await tester.pumpAndSettle();

      // The job is now in progress with the winner shown.
      expect(find.text('In Progress'), findsOneWidget);
      expect(find.text('Assigned Provider'), findsOneWidget);
      expect(find.text('Pro Fixer'), findsOneWidget);
    });
  });

  group('Trust Score', () {
    test('Bayesian review score starts at the prior and moves with reviews',
        () {
      // No reviews → the platform prior (3.5/5 → 700).
      expect(PlatformConfig.trustScoreFor(ratingSum: 0, ratingCount: 0), 700);
      // One 5★ on a fresh provider is smoothed toward the prior, not 1000.
      expect(PlatformConfig.trustScoreFor(ratingSum: 5, ratingCount: 1), 727);
      // A long run of 5★ approaches but never exceeds the cap.
      final many =
          PlatformConfig.trustScoreFor(ratingSum: 500, ratingCount: 100);
      expect(many, greaterThan(900));
      expect(many, lessThanOrEqualTo(1000));
    });

    // The shared vectors that also pin functions/index.js (`npm test`): if the
    // Dart and JS formulas ever drift, one of the two suites fails.
    final vectors = (jsonDecode(
                File('test/fixtures/trust_vectors.json').readAsStringSync())
            as Map<String, dynamic>)['vectors'] as List;
    for (final raw in vectors) {
      final v = raw as Map<String, dynamic>;
      test('v2 breakdown vector: ${v['name']}', () {
        final b = PlatformConfig.trustBreakdownFor(
          ratingSum: v['ratingSum'] as int,
          ratingCount: v['ratingCount'] as int,
          verificationStatus: v['verificationStatus'] as String,
          jobsCompleted: v['jobsCompleted'] as int,
          disputesLost: v['disputesLost'] as int,
          hasDisplayName: v['hasDisplayName'] as bool,
          hasPhone: v['hasPhone'] as bool,
          hasBio: v['hasBio'] as bool,
          hasPhoto: v['hasPhoto'] as bool,
          hasLocation: v['hasLocation'] as bool,
        );
        final e = v['expected'] as Map<String, dynamic>;
        expect(b.reviewScore, e['reviewScore']);
        expect(b.trackRecordScore, e['trackRecordScore']);
        expect(b.verificationScore, e['verificationScore']);
        expect(b.profileScore, e['profileScore']);
        expect(b.composite, e['composite']);
        expect(b.scoreVisible, e['scoreVisible']);
      });
    }

    test('score stays hidden until approved AND enough completed jobs', () {
      TrustBreakdown at(String status, int jobs) =>
          PlatformConfig.trustBreakdownFor(
            ratingSum: 0,
            ratingCount: 0,
            verificationStatus: status,
            jobsCompleted: jobs,
            disputesLost: 0,
            hasDisplayName: true,
            hasPhone: true,
            hasBio: true,
            hasPhoto: true,
            hasLocation: true,
          );
      expect(at('approved', 2).scoreVisible, isFalse); // below the job gate
      expect(at('approved', 3).scoreVisible, isTrue); // boundary unlocks
      expect(at('pending', 5).scoreVisible, isFalse); // not yet verified
    });
  });

  group('Best Value ranking', () {
    // Cheapest vs a pricier but far more trusted bid. Composites (§3.2.3):
    //   Cheap Charlie: 0.6*(100/100) + 0.4*0.30 = 0.72
    //   Trusty Tina:   0.6*(100/120) + 0.4*0.95 = 0.88  → Best Value
    List<Bid> valueBids() => [
          sampleBid(
              providerId: 'p-cheap',
              providerName: 'Cheap Charlie',
              amountSen: 10000,
              trustScore: 300),
          sampleBid(
              providerId: 'p-trust',
              providerName: 'Trusty Tina',
              amountSen: 12000,
              trustScore: 950),
        ];

    Future<void> openOwnJob(WidgetTester tester) async {
      await fillField(tester, 'Email', 'a@b.com');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();
    }

    testWidgets('defaults to composite order and badges the top bid',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(buildApp(FakeAuthRepository(),
          jobs: [sampleJob()], bids: valueBids()));
      await tester.pumpAndSettle();
      await openOwnJob(tester);

      // Three sort options are offered.
      expect(find.text('Best'), findsOneWidget);
      expect(find.text('Price'), findsOneWidget);
      expect(find.text('Trust'), findsOneWidget);

      // Exactly one badge, on the composite winner, which sorts first.
      expect(find.text('BEST VALUE'), findsOneWidget);
      final firstCard = find.byType(BidCard).first;
      expect(
          find.descendant(of: firstCard, matching: find.text('Trusty Tina')),
          findsOneWidget);
      expect(
          find.descendant(of: firstCard, matching: find.text('BEST VALUE')),
          findsOneWidget);
    });

    testWidgets('re-sorting by Price reorders but keeps the badge fixed',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(buildApp(FakeAuthRepository(),
          jobs: [sampleJob()], bids: valueBids()));
      await tester.pumpAndSettle();
      await openOwnJob(tester);

      await tester.tap(find.text('Price'));
      await tester.pumpAndSettle();

      // Cheapest sorts first now, but the badge stays on the value winner.
      expect(
          find.descendant(
              of: find.byType(BidCard).first,
              matching: find.text('Cheap Charlie')),
          findsOneWidget);
      expect(find.text('BEST VALUE'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(BidCard).last,
              matching: find.text('BEST VALUE')),
          findsOneWidget);
    });

    testWidgets('a bid from a new provider shows a New badge, not a score',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(buildApp(FakeAuthRepository(),
          jobs: [sampleJob()],
          bids: [sampleBid(scoreVisible: false)]));
      await tester.pumpAndSettle();
      await openOwnJob(tester);

      expect(find.text('New provider — no score yet'), findsOneWidget);
      expect(find.textContaining('Trust Score'), findsNothing);
      // Still rankable / acceptable — the internal score just isn't surfaced.
      expect(find.widgetWithText(FilledButton, 'Accept Bid'), findsOneWidget);
    });
  });

  group('Reviews', () {
    Future<void> loginRequestor(WidgetTester tester) async {
      await fillField(tester, 'Email', 'a@b.com');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();
    }

    Future<void> giveStarsAndSubmit(WidgetTester tester, int stars) async {
      await tester.tap(find.byIcon(Icons.star_border_rounded).at(stars - 1));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Submit Review'));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'releasing the last milestone completes the job and the requestor '
        'reviews the provider', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final review = FakeReviewRepository();
      final job = sampleJob(
        status: JobStatus.inProgress,
        acceptedProviderId: 'prov-1',
        acceptedProviderName: 'Pro Fixer',
        acceptedBidAmountSen: 15000,
      );
      // The provider already delivered the (only) milestone.
      final milestone = Milestone(
        id: 'ms-1',
        jobId: 'job-1',
        providerId: 'prov-1',
        description: 'Full repair',
        amountSen: 15000,
        status: MilestoneStatus.submitted,
        createdAt: DateTime.now(),
      );
      await tester.pumpWidget(buildApp(FakeAuthRepository(),
          jobs: [job], milestones: [milestone], review: review));
      await tester.pumpAndSettle();
      await loginRequestor(tester);

      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();
      expect(find.text('Assigned Provider'), findsOneWidget);
      expect(find.text('1. Full repair'), findsOneWidget);

      // Release the delivered milestone (with confirmation) — the last one,
      // so the job completes.
      final releaseBtn = find.widgetWithText(FilledButton, 'Release Payment');
      await tester.ensureVisible(releaseBtn);
      await tester.tap(releaseBtn);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Release'),
      ));
      await tester.pumpAndSettle();

      // Completed → review the provider with 5★.
      final reviewBtn = find.widgetWithText(FilledButton, 'Review Pro Fixer');
      await tester.ensureVisible(reviewBtn);
      await tester.tap(reviewBtn);
      await tester.pumpAndSettle();
      expect(find.text('Leave a Review'), findsOneWidget);
      await giveStarsAndSubmit(tester, 5);

      // The provider's aggregates and Bayesian review score were recomputed.
      expect(review.ratingCounts['prov-1'], 1);
      expect(review.reviewScores['prov-1'], 73); // (10·3.5+5)/11 /5 ·100
      expect(find.text('Review submitted'), findsOneWidget);
    });

    testWidgets('accepted provider reviews the requestor on a completed job',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final review = FakeReviewRepository();
      final job = sampleJob(
        requestorId: 'req-9',
        requestorName: 'Rita Client',
        status: JobStatus.completed,
        acceptedProviderId: 'uid-1',
        acceptedProviderName: 'New User',
        acceptedBidAmountSen: 15000,
      );
      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..baseLat = 3.139
        ..baseLng = 101.6869;
      await tester.pumpWidget(buildApp(auth, jobs: [job], review: review));
      await tester.pumpAndSettle();
      await openRegisterAs(tester, 'Work');

      // The provider reaches their won job via the My Jobs tab.
      await tester.tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('My Jobs'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();

      final reviewBtn = find.widgetWithText(FilledButton, 'Review Rita Client');
      await tester.ensureVisible(reviewBtn);
      await tester.tap(reviewBtn);
      await tester.pumpAndSettle();
      await giveStarsAndSubmit(tester, 4);

      expect(review.left.single.reviewerId, 'uid-1');
      expect(review.ratingCounts['req-9'], 1);
      expect(review.reviewScores['req-9'], 71); // (10·3.5+4)/11 /5 ·100
    });

    testWidgets('a second review on the same job is rejected', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final review = FakeReviewRepository();
      // The requestor already reviewed the provider on this job.
      await review.leaveReview(
        revieweeId: 'prov-1',
        review: const Review(
          id: '',
          reviewerId: 'uid-1',
          reviewerName: 'Test User',
          rating: 5,
          jobId: 'job-1',
        ),
      );
      final job = sampleJob(
        status: JobStatus.completed,
        acceptedProviderId: 'prov-1',
        acceptedProviderName: 'Pro Fixer',
        acceptedBidAmountSen: 15000,
      );
      await tester
          .pumpWidget(buildApp(FakeAuthRepository(), jobs: [job], review: review));
      await tester.pumpAndSettle();
      await loginRequestor(tester);

      // Completed jobs are hidden from Active Jobs, so open it via My Jobs.
      await tester.tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('My Jobs'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();

      final reviewBtn = find.widgetWithText(FilledButton, 'Review Pro Fixer');
      await tester.ensureVisible(reviewBtn);
      await tester.tap(reviewBtn);
      await tester.pumpAndSettle();
      await giveStarsAndSubmit(tester, 5);

      expect(
          find.text('You have already reviewed this job.'), findsOneWidget);
    });
  });

  group('Chat', () {
    Conversation sampleConversation() => Conversation(
          id: 'job-1_prov-1',
          jobId: 'job-1',
          jobTitle: 'Fix leaking sink',
          requestorId: 'uid-1',
          requestorName: 'Test User',
          providerId: 'prov-1',
          providerName: 'Pro Fixer',
          lastMessageAt: DateTime.now(),
        );

    Future<void> login(WidgetTester tester) async {
      await fillField(tester, 'Email', 'a@b.com');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();
    }

    test('Conversation helpers resolve the other party and unread count', () {
      final c = Conversation.fromMap('job-1_prov-1', {
        ...sampleConversation().toMap(),
        'lastMessageText': 'Hello!',
        'unreadCount': {'uid-1': 3},
      });
      expect(c.participantIds, ['uid-1', 'prov-1']);
      expect(c.otherPartyName('uid-1'), 'Pro Fixer');
      expect(c.otherPartyName('prov-1'), 'Test User');
      expect(c.unreadFor('uid-1'), 3);
      expect(c.unreadFor('prov-1'), 0);
      expect(c.lastMessageText, 'Hello!');
    });

    testWidgets(
        'unread badge shows, opening the thread clears it, and a reply '
        'sends', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final chat = FakeChatRepository([sampleConversation()]);
      // An incoming message from the provider → 1 unread for the requestor.
      await chat.sendMessage(
          conversation: sampleConversation(),
          senderId: 'prov-1',
          text: 'Hello! I can come by tomorrow.');

      await tester.pumpWidget(buildApp(FakeAuthRepository(), chat: chat));
      await tester.pumpAndSettle();
      await login(tester);

      // The Messages tab shows the unread badge.
      expect(
          find.descendant(
              of: find.byType(NavigationBar), matching: find.text('1')),
          findsOneWidget);

      // The conversation list shows the counterparty, job and preview.
      await tester.tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Messages'),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Pro Fixer'), findsOneWidget);
      expect(find.text('Fix leaking sink'), findsOneWidget);
      expect(find.text('Hello! I can come by tomorrow.'), findsOneWidget);

      // Open the thread → the message renders and unread clears.
      await tester.tap(find.text('Pro Fixer'));
      await tester.pumpAndSettle();
      expect(find.text('Hello! I can come by tomorrow.'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(NavigationBar), matching: find.text('1')),
          findsNothing);

      // Send a reply.
      await tester.enterText(find.byType(TextField), 'Great, see you then!');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Great, see you then!'), findsOneWidget);
    });

    testWidgets('requestor opens the chat from the assigned-provider card',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final chat = FakeChatRepository();
      final job = sampleJob(
        status: JobStatus.inProgress,
        acceptedProviderId: 'prov-1',
        acceptedProviderName: 'Pro Fixer',
        acceptedBidAmountSen: 15000,
      );
      await tester.pumpWidget(
          buildApp(FakeAuthRepository(), jobs: [job], chat: chat));
      await tester.pumpAndSettle();
      await login(tester);

      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();
      expect(find.text('Assigned Provider'), findsOneWidget);

      // The message button lazily creates the conversation and opens it.
      await tester.tap(find.byIcon(Icons.chat_bubble_outline));
      await tester.pumpAndSettle();
      expect(find.text('Start the conversation'), findsOneWidget);
      expect(find.text('Pro Fixer'), findsOneWidget); // thread app bar
    });
  });

  group('Admin verification queue', () {
    PendingVerification samplePending({
      String uid = 'prov-9',
      String name = 'Alex Rivera',
      UserRole role = UserRole.provider,
    }) =>
        PendingVerification(
          uid: uid,
          displayName: name,
          role: role,
          email: 'alex@fairbid.app',
          providerType: 'individual',
          submittedAt: DateTime.now().subtract(const Duration(hours: 2)),
          phone: '0123456789',
          location: 'Kuala Lumpur',
          category: 'Plumbing',
          skills: const ['Pipe fitting', 'Leak repair'],
          // Identity docs now come from the private-only loadIdentityDocuments;
          // the public `documents` list holds certificates/portfolio only.
          documents: const [],
        );

    testWidgets('admin lands on the queue and sees pending applicants',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      await tester.pumpWidget(buildApp(auth,
          verification: FakeVerificationRepository([samplePending()])));
      await tester.pumpAndSettle();

      expect(find.text('Verification Queue'), findsOneWidget);
      expect(find.text('Alex Rivera'), findsOneWidget);
      // The "Pending Review" stat reflects the queue length.
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('empty queue shows the all-caught-up state', (tester) async {
      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();

      expect(find.text('All caught up'), findsOneWidget);
    });

    testWidgets('approving an applicant records the decision and clears it',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      final verification = FakeVerificationRepository([samplePending()]);
      await tester.pumpWidget(buildApp(auth, verification: verification));
      await tester.pumpAndSettle();

      // Open the applicant's review screen.
      await tester.tap(find.text('Alex Rivera'));
      await tester.pumpAndSettle();
      expect(find.text('Verify Provider'), findsOneWidget);
      expect(find.text('Applicant Details'), findsOneWidget);
      expect(find.text('Identity Document'), findsOneWidget);

      // Approve → confirm in the dialog.
      await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
      await tester.pumpAndSettle();
      expect(find.text('Approve verification?'), findsOneWidget);
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Approve'),
      ));
      await tester.pumpAndSettle();

      // Decision recorded; back on the queue, now empty.
      expect(verification.decisions['prov-9'], isTrue);
      expect(find.text('All caught up'), findsOneWidget);
    });

    testWidgets('admin profile shows admin info, not marketplace fields',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      await tester.pumpWidget(buildApp(auth,
          verification: FakeVerificationRepository([samplePending()])));
      await tester.pumpAndSettle();

      await tester.tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Profile'),
      ));
      await tester.pumpAndSettle();

      // Admin-appropriate content.
      expect(find.text('Administrator'), findsOneWidget);
      expect(find.text('Administrator Access'), findsOneWidget);
      // StatCard uppercases its label.
      expect(find.text('PENDING VERIFICATIONS'), findsOneWidget);
      // Marketplace-participant content is hidden for admins.
      expect(find.text('Trust Score'), findsNothing);
      expect(find.text('Earnings & Payouts'), findsNothing);
      expect(find.textContaining('Reviews ('), findsNothing);
    });

    testWidgets('rejecting captures the reason', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      final verification = FakeVerificationRepository([samplePending()]);
      await tester.pumpWidget(buildApp(auth, verification: verification));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Alex Rivera'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Reject'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Blurry document.');
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Reject'),
      ));
      await tester.pumpAndSettle();

      expect(verification.decisions['prov-9'], isFalse);
      expect(verification.lastReason, 'Blurry document.');
    });
  });

  group('Verification privacy', () {
    test('provider toMap excludes identity photo URLs (they go private)', () {
      final data = OnboardingData()
        ..idDocumentUrl = 'https://x/id.jpg'
        ..selfieUrl = 'https://x/selfie.jpg';
      final map = data.toMap();
      expect(map.containsKey('idDocumentUrl'), isFalse);
      expect(map.containsKey('selfieUrl'), isFalse);
      expect(data.privateMap()['idDocumentUrl'], 'https://x/id.jpg');
      expect(data.privateMap()['selfieUrl'], 'https://x/selfie.jpg');
    });

    test('requestor toMap excludes the ID/SSM document URL', () {
      final data = RequestorOnboardingData()
        ..clientDocumentUrl = 'https://x/doc.jpg';
      expect(data.toMap().containsKey('clientDocumentUrl'), isFalse);
      expect(data.privateMap()['clientDocumentUrl'], 'https://x/doc.jpg');
    });
  });

  group('Disputes', () {
    test('Dispute builds from a Firestore-shaped map', () {
      final dispute = Dispute.fromMap('d1', {
        'jobId': 'job-1',
        'jobTitle': 'Fix leaking sink',
        'milestoneId': 'ms-1',
        'milestoneDescription': 'Full repair',
        'amountSen': 15000,
        'raisedByUid': 'prov-1',
        'raisedByRole': 'provider',
        'requestorId': 'uid-1',
        'providerId': 'prov-1',
        'statement': 'Payment not released after delivery.',
        'evidenceUrls': ['https://x/1.jpg'],
        'status': 'open',
        'resolution': null,
      });
      expect(dispute.raisedByLabel, 'Provider');
      expect(dispute.conversationId, 'job-1_prov-1');
      expect(dispute.status, DisputeStatus.open);
      expect(dispute.resolution, isNull);
      expect(dispute.evidenceUrls, hasLength(1));
    });

    test('dispute ledger types parse from storage', () {
      expect(LedgerType.fromStorage('dispute_release'),
          LedgerType.disputeRelease);
      expect(
          LedgerType.fromStorage('dispute_refund'), LedgerType.disputeRefund);
    });

    Dispute sampleDispute({String id = 'disp-1'}) => Dispute(
          id: id,
          jobId: 'job-1',
          jobTitle: 'Fix leaking sink',
          milestoneId: 'ms-1',
          milestoneDescription: 'Full repair',
          amountSen: 15000,
          raisedByUid: 'uid-1',
          raisedByRole: 'requestor',
          requestorId: 'uid-1',
          providerId: 'prov-1',
          statement: 'The pipe still leaks after the repair.',
          createdAt: DateTime.now(),
        );

    testWidgets('requestor raises a dispute on a funded milestone',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final dispute = FakeDisputeRepository();
      final job = sampleJob(
        status: JobStatus.inProgress,
        acceptedProviderId: 'prov-1',
        acceptedProviderName: 'Pro Fixer',
        acceptedBidAmountSen: 15000,
      );
      final milestone = Milestone(
        id: 'ms-1',
        jobId: 'job-1',
        providerId: 'prov-1',
        description: 'Full repair',
        amountSen: 15000,
        status: MilestoneStatus.funded,
        createdAt: DateTime.now(),
      );
      await tester.pumpWidget(buildApp(FakeAuthRepository(),
          jobs: [job], milestones: [milestone], dispute: dispute));
      await tester.pumpAndSettle();
      await fillField(tester, 'Email', 'a@b.com');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();

      // Open own job → the funded milestone offers "Raise a dispute".
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();
      final disputeBtn = find.widgetWithText(TextButton, 'Raise a dispute');
      await tester.ensureVisible(disputeBtn);
      await tester.tap(disputeBtn);
      await tester.pumpAndSettle();
      expect(find.text('Raise a Dispute'), findsOneWidget);

      // Empty statement is rejected.
      await tester.tap(find.widgetWithText(FilledButton, 'Submit Dispute'));
      await tester.pumpAndSettle();
      expect(find.text('Describe the issue.'), findsOneWidget);

      // Statement in → submitted; milestone freezes to Disputed.
      await fillField(
          tester, 'What went wrong?', 'The pipe still leaks after repair.');
      await tester.tap(find.widgetWithText(FilledButton, 'Submit Dispute'));
      await tester.pumpAndSettle();

      expect(dispute.raised, hasLength(1));
      expect(dispute.raised.single.milestoneId, 'ms-1');
      expect(find.text('Disputed'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Raise a dispute'), findsNothing);
    });

    testWidgets('admin rules a dispute from the Disputes tab', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final dispute = FakeDisputeRepository([sampleDispute()]);
      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      await tester.pumpWidget(buildApp(auth, dispute: dispute));
      await tester.pumpAndSettle();

      // Admin home opens on Verifications; switch to the Disputes tab.
      await tester.tap(find.text('Disputes'));
      await tester.pumpAndSettle();
      expect(find.text('Disputes Resolution'), findsOneWidget);
      expect(find.text('Fix leaking sink'), findsOneWidget);

      // Open the dispute → statement and both rulings are shown.
      await tester.tap(find.text('Fix leaking sink'));
      await tester.pumpAndSettle();
      expect(find.text('Dispute Review'), findsOneWidget);
      expect(find.text('The pipe still leaks after the repair.'),
          findsOneWidget);

      // Release → the ruling note is required before confirming.
      await tester.tap(find.widgetWithText(FilledButton, 'Release'));
      await tester.pumpAndSettle();
      final confirm = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Release'),
      );
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.enterText(
          find.byType(TextField).last, 'Work matches the milestone scope.');
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pumpAndSettle();

      // Ruling recorded; the queue is empty again.
      expect(dispute.resolutions['disp-1'], DisputeResolution.release);
      expect(dispute.lastRulingNote, 'Work matches the milestone scope.');
      expect(find.text('No open disputes'), findsOneWidget);
    });
  });

  group('Review moderation & stats', () {
    test('Review parses moderation fields with safe defaults', () {
      final legacy = Review.fromMap('r1', {'rating': 4});
      expect(legacy.flagged, isFalse);
      expect(legacy.hidden, isFalse);
      expect(legacy.flagReason, isNull);

      final flagged = Review.fromMap('r2', {
        'rating': 1,
        'flagged': true,
        'flagReason': 'Never my client.',
        'hidden': true,
      });
      expect(flagged.flagged, isTrue);
      expect(flagged.hidden, isTrue);
      // Moderation state never travels back into a write.
      expect(flagged.toMap().containsKey('flagged'), isFalse);
      expect(flagged.toMap().containsKey('hidden'), isFalse);
    });

    testWidgets('owner reports a review from their profile', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final review = FakeReviewRepository([
        Review(
          id: 'r1',
          reviewerId: 'someone',
          reviewerName: 'Sarah Connor',
          rating: 1,
          comment: 'Terrible.',
          createdAt: DateTime.now(),
        ),
      ]);
      await tester.pumpWidget(buildApp(FakeAuthRepository(), review: review));
      await tester.pumpAndSettle();
      await fillField(tester, 'Email', 'a@b.com');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();

      await tester.tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Profile'),
      ));
      await tester.pumpAndSettle();

      // Report via the flag icon on the review.
      final flagIcon = find.byIcon(Icons.flag_outlined);
      await tester.ensureVisible(flagIcon);
      await tester.tap(flagIcon);
      await tester.pumpAndSettle();
      expect(find.text('Report this review?'), findsOneWidget);

      // The reason is required.
      final report = find.widgetWithText(FilledButton, 'Report');
      expect(tester.widget<FilledButton>(report).onPressed, isNull);
      await tester.enterText(
          find.byType(TextField).last, 'This reviewer was never my client.');
      await tester.pumpAndSettle();
      await tester.tap(report);
      await tester.pumpAndSettle();

      expect(review.flags, hasLength(1));
      expect(review.flags.single.$2, 'r1');
      expect(
          review.flags.single.$3, 'This reviewer was never my client.');
    });

    testWidgets('admin hides a flagged review from the Reviews tab',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final moderation = FakeModerationRepository([
        FlaggedReview(
          revieweeId: 'prov-1',
          review: Review(
            id: 'r1',
            reviewerId: 'someone',
            reviewerName: 'Sarah Connor',
            rating: 1,
            comment: 'Terrible.',
            flagged: true,
            flagReason: 'Never my client.',
            createdAt: DateTime.now(),
          ),
        ),
      ]);
      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      await tester.pumpWidget(buildApp(auth, moderation: moderation));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Reviews'));
      await tester.pumpAndSettle();
      expect(find.text('Review Moderation'), findsOneWidget);
      expect(find.text('Sarah Connor'), findsOneWidget);
      expect(find.text('Never my client.'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Hide'));
      await tester.pumpAndSettle();

      expect(moderation.rulings['r1'], isTrue);
      expect(find.text('Nothing to moderate'), findsOneWidget);
    });

    testWidgets('stats tab shows the aggregated platform numbers',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();

      // The scrollable TabBar puts 'Stats' past the right edge in the wide
      // Ahem test font — bring it on-screen first.
      await tester.ensureVisible(find.text('Stats'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stats'));
      await tester.pumpAndSettle();

      expect(find.text('Platform Statistics'), findsOneWidget);
      expect(find.text('RM 12,345.00'), findsOneWidget); // released volume
      expect(find.text('11'), findsOneWidget); // clients
      expect(find.text('12'), findsOneWidget); // providers
      expect(find.text('17'), findsOneWidget); // open disputes
      expect(find.text('23'), findsOneWidget); // total users
    });

    testWidgets('stats tab can trigger the Trust Score recompute',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      final stats = FakeStatsRepository();
      await tester.pumpWidget(buildApp(auth, stats: stats));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Stats'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stats'));
      await tester.pumpAndSettle();

      final btn =
          find.widgetWithText(OutlinedButton, 'Recompute Trust Scores');
      await tester.ensureVisible(btn);
      await tester.tap(btn);
      await tester.pumpAndSettle();

      expect(stats.recomputeCalls, 1);
      expect(find.textContaining('Trust Scores recomputed'), findsOneWidget);
    });
  });

  group('Milestone plan approval and dispute rework', () {
    Dispute disputeFor(String milestoneId) => Dispute(
          id: 'disp-1',
          jobId: 'job-1',
          jobTitle: 'Fix leaking sink',
          milestoneId: milestoneId,
          milestoneDescription: 'Full repair',
          amountSen: 15000,
          raisedByUid: 'uid-1',
          raisedByRole: 'requestor',
          requestorId: 'uid-1',
          providerId: 'prov-1',
          statement: 'The pipe still leaks after the repair.',
          createdAt: DateTime.now(),
        );

    FakeMilestoneRepository repoWithDisputedLastMilestone(
        FakeJobRepository jobs) {
      return FakeMilestoneRepository(jobs, [
        Milestone(
          id: 'ms-1',
          jobId: 'job-1',
          providerId: 'prov-1',
          description: 'Full repair',
          amountSen: 15000,
          status: MilestoneStatus.disputed,
          createdAt: DateTime.now(),
        ),
      ]);
    }

    FakeJobRepository inProgressJob() => FakeJobRepository([
          sampleJob(
            status: JobStatus.inProgress,
            acceptedProviderId: 'prov-1',
            acceptedProviderName: 'Pro Fixer',
            acceptedBidAmountSen: 15000,
          ),
        ]);

    test('refunding the last milestone reopens it, job stays in progress',
        () async {
      final jobs = inProgressJob();
      final milestones = repoWithDisputedLastMilestone(jobs);
      final disputes = FakeDisputeRepository([disputeFor('ms-1')])
        ..milestones = milestones;

      await disputes.resolveDispute(
        disputeId: 'disp-1',
        resolution: DisputeResolution.refund,
        rulingNote: 'Work was not delivered.',
      );

      final m = (await milestones.watchMilestones('job-1').first).single;
      expect(m.status, MilestoneStatus.pending); // reopened, not terminal
      expect(m.reworkCount, 1);
      expect(m.reworkNote, 'Work was not delivered.');
      final job = await jobs.getById('job-1');
      expect(job!.status, JobStatus.inProgress); // NOT completed
    });

    test('releasing the last disputed milestone completes the job', () async {
      final jobs = inProgressJob();
      final milestones = repoWithDisputedLastMilestone(jobs);
      final disputes = FakeDisputeRepository([disputeFor('ms-1')])
        ..milestones = milestones;

      await disputes.resolveDispute(
        disputeId: 'disp-1',
        resolution: DisputeResolution.release,
        rulingNote: 'Work matches scope.',
      );

      final m = (await milestones.watchMilestones('job-1').first).single;
      expect(m.status, MilestoneStatus.released);
      final job = await jobs.getById('job-1');
      expect(job!.status, JobStatus.completed);
    });

    test('a proposed plan is not fundable until the client approves it',
        () async {
      final jobs = inProgressJob();
      final milestones = FakeMilestoneRepository(jobs);
      await milestones.proposeMilestones('job-1', [
        Milestone(
          id: '',
          jobId: 'job-1',
          providerId: 'prov-1',
          description: 'All work',
          amountSen: 15000,
          order: 0,
        ),
      ]);

      var m = (await milestones.watchMilestones('job-1').first).single;
      expect(m.status, MilestoneStatus.proposed);

      // Funding a merely-proposed milestone is refused (a no-op in the fake).
      await milestones.fundMilestone('job-1', m.id);
      m = (await milestones.watchMilestones('job-1').first).single;
      expect(m.status, MilestoneStatus.proposed);

      // Approval makes it pending → fundable.
      await milestones.approveMilestonePlan('job-1');
      m = (await milestones.watchMilestones('job-1').first).single;
      expect(m.status, MilestoneStatus.pending);
      await milestones.fundMilestone('job-1', m.id);
      m = (await milestones.watchMilestones('job-1').first).single;
      expect(m.status, MilestoneStatus.funded);
    });
  });
}

/// Opens the register screen, picks [roleLabel] ('Hire' or 'Work'), fills the
/// form and submits. Used by shell tests that need a signed-in role.
Future<void> openRegisterAs(WidgetTester tester, String roleLabel) async {
  await tester.tap(find.text('Sign Up'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(roleLabel));
  await tester.pumpAndSettle();
  await fillField(tester, 'FULL NAME', 'New User');
  await fillField(tester, 'EMAIL ADDRESS', 'new@fairbid.app');
  await fillField(tester, 'PASSWORD', 'secret123');
  await fillField(tester, 'CONFIRM PASSWORD', 'secret123');
  final checkbox = find.byType(Checkbox);
  await tester.ensureVisible(checkbox);
  await tester.tap(checkbox);
  await tester.pumpAndSettle();
  final button = find.widgetWithText(FilledButton, 'Sign Up');
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}
