import 'dart:async';

import 'package:fairbid/core/config/platform_config.dart';
import 'package:fairbid/core/location/region.dart';
import 'package:fairbid/features/admin/data/moderation_repository.dart';
import 'package:fairbid/features/admin/data/stats_repository.dart';
import 'package:fairbid/features/admin/data/user_admin_repository.dart';
import 'package:fairbid/features/admin/data/verification_repository.dart';
import 'package:fairbid/features/admin/domain/flagged_review.dart';
import 'package:fairbid/features/admin/domain/managed_user.dart';
import 'package:fairbid/features/admin/domain/pending_verification.dart';
import 'package:fairbid/features/admin/domain/platform_stats.dart';
import 'package:fairbid/features/auth/data/auth_exception.dart';
import 'package:fairbid/features/auth/data/auth_repository.dart';
import 'package:fairbid/features/auth/domain/app_user.dart';
import 'package:fairbid/features/auth/domain/mfa.dart';
import 'package:fairbid/features/auth/domain/user_role.dart';
import 'package:fairbid/features/disputes/data/dispute_repository.dart';
import 'package:fairbid/features/disputes/domain/dispute.dart';
import 'package:fairbid/features/jobs/data/assist_repository.dart';
import 'package:fairbid/features/jobs/data/bid_repository.dart';
import 'package:fairbid/features/jobs/data/bundle_bid_repository.dart';
import 'package:fairbid/features/jobs/data/bundle_repository.dart';
import 'package:fairbid/features/jobs/data/job_repository.dart';
import 'package:fairbid/features/jobs/data/milestone_repository.dart';
import 'package:fairbid/features/jobs/domain/appointment.dart';
import 'package:fairbid/features/jobs/domain/bid.dart';
import 'package:fairbid/features/jobs/domain/bundle.dart';
import 'package:fairbid/features/jobs/domain/bundle_award.dart';
import 'package:fairbid/features/jobs/domain/bundle_bid.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/jobs/domain/job_event.dart';
import 'package:fairbid/features/jobs/domain/milestone.dart';
import 'package:fairbid/features/jobs/domain/service_address.dart';
import 'package:fairbid/features/messages/data/chat_repository.dart';
import 'package:fairbid/features/messages/domain/conversation.dart';
import 'package:fairbid/features/messages/domain/message.dart';
import 'package:fairbid/features/notifications/data/notification_repository.dart';
import 'package:fairbid/features/notifications/data/push_service.dart';
import 'package:fairbid/features/notifications/domain/app_notification.dart';
import 'package:fairbid/features/onboarding/data/document_storage_repository.dart';
import 'package:fairbid/features/onboarding/data/face_checker.dart';
import 'package:fairbid/features/onboarding/data/onboarding_repository.dart';
import 'package:fairbid/features/onboarding/data/requestor_onboarding_repository.dart';
import 'package:fairbid/features/onboarding/domain/onboarding_data.dart';
import 'package:fairbid/features/onboarding/domain/requestor_onboarding_data.dart';
import 'package:fairbid/features/onboarding/domain/id_extract.dart';
import 'package:fairbid/features/onboarding/domain/ssm_extract.dart';
import 'package:fairbid/features/profile/data/public_profile_repository.dart';
import 'package:fairbid/features/profile/data/review_repository.dart';
import 'package:fairbid/features/profile/data/user_report_repository.dart';
import 'package:fairbid/features/profile/domain/public_profile.dart';
import 'package:fairbid/features/profile/domain/review.dart';
import 'package:fairbid/features/wallet/data/wallet_repository.dart';
import 'package:fairbid/features/wallet/domain/ledger_entry.dart';
import 'package:fairbid/features/wallet/domain/payout_method.dart';
import 'package:image_picker/image_picker.dart';

/// What:   In-memory [AuthRepository] used to drive the UI in tests without Firebase.
///
///         Set [failWith] to simulate an auth error on the next action.
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
  String? baseDistrictCode;
  String? baseTown;

  /// A requestor's saved default job location, distinct from the provider
  /// [baseLat]/[baseLng] service base. Post-a-Job pre-fills "Where" from
  /// these, so seeding them mirrors a requestor who finished onboarding.
  double? defaultLat;
  double? defaultLng;
  String? defaultDistrictCode;
  String? defaultTown;
  String displayName = 'Test User';
  String? phone;
  String? location;
  String? bio;
  String? profilePhotoUrl;
  String? providerType;
  String? category;
  List<String> skills = [];

  int walletBalanceSen = 0;

  int ratingCount = 0;
  int ratingSum = 0;
  int jobsCompleted = 0;
  int disputesLost = 0;

  /// Mirrors the server-owned `suspended` flag; set before [seedSignedIn] to
  /// boot the app as a suspended user.
  bool suspended = false;
  String? suspensionReason;

  /// Mirrors the `watchlist` array Firestore field; seed a job id here (or
  /// mutate it via [setJobSaved]) so tests can assert the watchlist toggle.
  List<String> watchlist = [];

  /// Mirrors `User.emailVerified`. Defaults true so existing tests skip the
  /// verify-email gate; gate tests opt in with false.
  bool emailVerified = true;

  /// Set true so the next [reloadUser] flips [emailVerified] - mimics the
  /// user clicking the link while the app was backgrounded.
  bool verifyOnReload = false;

  /// Counters for tests to assert against.
  int verificationEmailsSent = 0;
  int reauthCount = 0;

  /// Enrolled second factors. Empty = 2FA off, which every existing test
  /// expects.
  List<MfaFactor> mfaFactors = [];

  /// Passes the provider/admin 2FA gate without enrolled [mfaFactors].
  /// Defaults true so existing tests skip the gate; gate tests set false.
  bool mfaEnrolled = true;

  /// When true, the next sign-in or re-auth raises an MFA challenge instead
  /// of succeeding - mirrors Firebase pausing for a second factor.
  bool requireMfaOnSignIn = false;

  /// Codes the fake accepts. Anything else fails like a wrong code.
  String validCode = '123456';

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
      baseDistrictCode: baseDistrictCode,
      baseTown: baseTown,
      defaultLat: defaultLat,
      defaultLng: defaultLng,
      defaultDistrictCode: defaultDistrictCode,
      defaultTown: defaultTown,
      phone: phone,
      location: location,
      bio: bio,
      profilePhotoUrl: profilePhotoUrl,
      providerType: providerType,
      category: category,
      skills: List.of(skills),
      walletBalanceSen: walletBalanceSen,
      ratingCount: ratingCount,
      ratingSum: ratingSum,
      jobsCompleted: jobsCompleted,
      trustScore: trust.composite,
      trustBreakdown: trust,
      suspended: suspended,
      suspensionReason: suspensionReason,
      watchlist: List.of(watchlist),
      emailVerified: emailVerified,
      mfaEnrolled: mfaEnrolled || mfaFactors.isNotEmpty,
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
    if (requireMfaOnSignIn) {
      throw const MfaRequiredException(MfaChallenge(
        resolver: 'fake-resolver',
      ));
    }
    _current = _build(role);
    _controller.add(_current);
  }

  @override
  Future<void> updateBaseLocation({
    required String uid,
    required PickedLocation picked,
  }) async {
    baseLat = picked.lat;
    baseLng = picked.lng;
    baseDistrictCode = picked.region.districtCode;
    baseTown = picked.region.town;
  }

  @override
  Future<void> updateProfile({
    required String uid,
    required String displayName,
    required String? phone,
    required String? location,
    required String? bio,
    bool isProvider = false,
    PickedLocation? picked,
    String? category,
    List<String>? skills,
  }) async {
    this.displayName = displayName;
    this.phone = phone;
    this.location = location;
    this.bio = bio;
    if (category != null) this.category = category;
    if (skills != null) this.skills = skills;
  }

  @override
  Future<void> updateProfilePhoto({
    required String uid,
    required String photoUrl,
  }) async {
    profilePhotoUrl = photoUrl;
  }

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async => _signIn(UserRole.requestor);

  /// Emails for which [sendPasswordReset] was called, for tests to assert.
  final passwordResetsSent = <String>[];

  @override
  Future<void> sendPasswordReset(String email) async {
    if (failWith != null) throw failWith!;
    passwordResetsSent.add(email);
  }

  @override
  Future<void> sendEmailVerification() async {
    if (failWith != null) throw failWith!;
    verificationEmailsSent++;
  }

  @override
  Future<bool> reloadUser() async {
    if (verifyOnReload) emailVerified = true;
    return emailVerified;
  }

  @override
  Future<void> reauthenticate({String? password}) async {
    if (failWith != null) throw failWith!;
    reauthCount++;
    if (requireMfaOnSignIn) {
      throw const MfaRequiredException(MfaChallenge(
        resolver: 'fake-resolver',
      ));
    }
  }

  @override
  Future<List<MfaFactor>> enrolledFactors() async => List.of(mfaFactors);

  @override
  Future<TotpEnrollment> startTotpEnrollment() async => const TotpEnrollment(
        secretKey: 'ABCD1234',
        qrCodeUrl: 'otpauth://totp/FairBid:test@fairbid.app?secret=ABCD1234',
        handle: 'fake-secret',
      );

  @override
  Future<void> completeTotpEnrollment({
    required TotpEnrollment enrollment,
    required String code,
  }) async {
    if (code != validCode) {
      throw const AuthException('That code is incorrect.');
    }
    mfaFactors = [
      const MfaFactor(uid: 'factor-1'),
    ];
  }

  @override
  Future<void> unenrollFactor(String factorUid) async {
    mfaFactors = mfaFactors.where((f) => f.uid != factorUid).toList();
  }

  @override
  Future<void> resolveMfa(MfaChallenge challenge, String code) async {
    if (code != validCode) {
      throw const AuthException('That code is incorrect.');
    }
    requireMfaOnSignIn = false;
    // A re-auth-originated challenge just refreshes the existing session
    // (see the design note on resolveSignIn); only sign-in needs a build.
    if (_current == null) _signIn(UserRole.requestor);
  }

  @override
  Future<void> registerWithEmail({
    required String email,
    required String password,
    required String displayName,
    required UserRole role,
  }) async => _signIn(role);

  @override
  Future<void> signInWithGoogle({required UserRole roleIfNew}) async =>
      _signIn(roleIfNew);

  @override
  Future<void> setJobSaved({
    required String uid,
    required String jobId,
    required bool saved,
  }) async {
    if (saved) {
      if (!watchlist.contains(jobId)) watchlist.add(jobId);
    } else {
      watchlist.remove(jobId);
    }
    // Re-emit so a live UI (watching AuthController) sees the new watchlist,
    // mirroring the real repo's live profile stream.
    if (_current != null) {
      _current = _build(_current!.role);
      _controller.add(_current);
    }
  }

  @override
  Future<void> signOut() async {
    _current = null;
    _controller.add(null);
  }

  @override
  Future<void> deleteAccount({String? password}) async {
    if (failWith != null) throw failWith!;
    // Mirrors the real repo: requires-recent-login re-authenticates
    // internally, so an enrolled user's challenge surfaces from here too.
    if (requireMfaOnSignIn) {
      throw const MfaRequiredException(MfaChallenge(
        resolver: 'fake-resolver',
      ));
    }
    _current = null;
    _controller.add(null);
  }
}

/// What:   In-memory [OnboardingRepository]; submission flips the fake auth repo's
///         verification status, mimicking the Firestore write.
class FakeOnboardingRepository implements OnboardingRepository {
  FakeOnboardingRepository(this.auth);

  final FakeAuthRepository auth;
  OnboardingData? saved;

  /// Set before pumping to drive the SSM step's verdict card.
  SsmExtract? ssmExtract;

  /// Same for the ID card's advisory check.
  IdExtract? idExtract;

  @override
  Future<OnboardingData> load(String uid) async => saved ?? OnboardingData();

  @override
  Stream<SsmExtract?> watchSsmExtract(String uid) async* {
    yield ssmExtract;
  }

  @override
  Stream<IdExtract?> watchIdExtract(String uid) async* {
    yield idExtract;
  }

  @override
  Future<void> save(String uid, OnboardingData data) async => saved = data;

  @override
  Future<void> submitForReview(String uid, OnboardingData data) async {
    saved = data;
    auth.verificationStatus = 'pending';
  }
}

/// What:   In-memory [RequestorOnboardingRepository]; completing flips the fake auth
///         repo's `onboardingComplete`, mimicking the Firestore write.
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

/// What:   In-memory [DocumentStorageRepository]; never touches real Firebase Storage
///         or the platform image picker, since no test currently exercises uploads.
class FakeDocumentStorageRepository implements DocumentStorageRepository {
  @override
  Future<String> uploadVerificationImage({
    required String uid,
    required String purpose,
    required XFile file,
  }) async => 'https://fake.storage/$uid/$purpose';

  @override
  Future<String> uploadAvatar({
    required String uid,
    required XFile file,
  }) async => 'https://fake.storage/avatars/$uid';

  @override
  Future<String> uploadJobPhoto({
    required String uid,
    required XFile file,
  }) async => 'https://fake.storage/jobs/$uid';

  @override
  Future<String> uploadDisputeEvidence({
    required String uid,
    required XFile file,
  }) async => 'https://fake.storage/disputes/$uid';

  @override
  Future<void> deleteByUrl(String url) async {}
}

/// What:   In-memory [JobRepository] seeded with [jobs].
class FakeJobRepository implements JobRepository {
  FakeJobRepository([
    List<Job> jobs = const [],
    Map<String, List<JobEvent>>? events,
  ])  : _jobs = [...jobs],
        _events = {
          for (final entry in (events ?? const {}).entries)
            entry.key: [...entry.value],
        };

  final List<Job> _jobs;
  final Map<String, List<JobEvent>> _events;
  final _addresses = <String, ServiceAddress>{};
  final _changes = StreamController<void>.broadcast();

  void _notify() => _changes.add(null);

  @override
  Future<String> create(Job job) async {
    _jobs.add(job);
    _notify();
    return 'job-${_jobs.length}';
  }

  @override
  Stream<List<Job>> watchOpenJobs({
    String? category,
    int limit = kOpenJobsPageSize,
  }) async* {
    // Mirrors the real query: status, then category server-side, then a
    // bounded window - so a test that relies on the category filter is
    // exercising the same shape the Firestore index serves.
    yield _jobs
        .where((j) => j.status == JobStatus.open)
        .where((j) => category == null || j.category == category)
        .take(limit)
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
  Stream<List<Job>> watchBundleTasks(String bundleId) async* {
    List<Job> tasks() {
      final t = _jobs.where((j) => j.bundleId == bundleId).toList();
      t.sort((a, b) => (a.bundleOrder ?? 0).compareTo(b.bundleOrder ?? 0));
      return t;
    }

    yield tasks();
    await for (final _ in _changes.stream) {
      yield tasks();
    }
  }

  @override
  Future<List<Job>> getBundleTasks(String bundleId) async {
    final t = _jobs.where((j) => j.bundleId == bundleId).toList();
    t.sort((a, b) => (a.bundleOrder ?? 0).compareTo(b.bundleOrder ?? 0));
    return t;
  }

  Future<Job?> getById(String id) async =>
      _jobs.cast<Job?>().firstWhere((j) => j!.id == id, orElse: () => null);

  @override
  Stream<Job?> watchJob(String id) async* {
    Job? find() =>
        _jobs.cast<Job?>().firstWhere((j) => j!.id == id, orElse: () => null);
    yield find();
    await for (final _ in _changes.stream) {
      yield find();
    }
  }

  @override
  Future<void> cancelOpenJob(String id) async {
    final i = _jobs.indexWhere((j) => j.id == id);
    if (i != -1) _jobs[i] = _rebuild(_jobs[i], status: JobStatus.cancelled);
    _notify();
  }

  @override
  Future<void> requestCancellation(String jobId, {String? reason}) async {
    final i = _jobs.indexWhere((j) => j.id == jobId);
    if (i == -1) return;
    _jobs[i] = _rebuild(
      _jobs[i],
      cancellationRequestedBy: 'requestor',
      cancellationReason: reason,
    );
    _notify();
  }

  @override
  Future<void> respondToCancellation(
    String jobId, {
    required bool accept,
  }) async {
    final i = _jobs.indexWhere((j) => j.id == jobId);
    if (i == -1) return;
    _jobs[i] = _rebuild(
      _jobs[i],
      status: accept ? JobStatus.cancelled : null,
      clearCancellationRequest: true,
    );
    _notify();
  }

  /// Price-change calls made against this fake, as `'kind:jobId[:arg]'`
  /// (`request:j1:12000`, `accept:j1`, `decline:j1`, `withdraw:j1`).
  final priceChangeCalls = <String>[];

  /// When set, thrown by the next [respondToPriceChange].
  Object? respondToPriceChangeError;

  @override
  Future<void> requestPriceChange(
    String jobId, {
    required int newAmountSen,
    required String reason,
  }) async {
    priceChangeCalls.add('request:$jobId:$newAmountSen');
  }

  @override
  Future<void> respondToPriceChange(
    String jobId, {
    required bool accept,
  }) async {
    final err = respondToPriceChangeError;
    if (err != null) {
      respondToPriceChangeError = null;
      throw err;
    }
    priceChangeCalls.add('${accept ? 'accept' : 'decline'}:$jobId');
  }

  @override
  Future<void> withdrawPriceChange(String jobId) async {
    priceChangeCalls.add('withdraw:$jobId');
  }

  /// Appointment calls made against this fake, as `'kind:jobId[:arg]'`
  /// (`propose:j1:2`, `accept:j1:0`, `withdraw:j1`, `onTheWay:j1:30`, `arrived:j1`).
  final appointmentCalls = <String>[];

  /// The `alsoJobIds` of each [proposeAppointment] call, in order.
  final proposedAlso = <List<String>>[];

  /// The uid recorded as proposer or confirmer (the signed-in test user).
  String appointmentUid = 'uid-1';

  void _updateJob(String jobId, Job Function(Job) change) {
    final i = _jobs.indexWhere((j) => j.id == jobId);
    if (i == -1) return;
    _jobs[i] = change(_jobs[i]);
    _notify();
  }

  @override
  Future<void> proposeAppointment(
    String jobId, {
    required List<DateTime> options,
    DateTime? endAt,
    String? note,
    List<String> alsoJobIds = const [],
  }) async {
    appointmentCalls.add('propose:$jobId:${options.length}');
    proposedAlso.add(alsoJobIds);
    _updateJob(
      jobId,
      (j) => _rebuild(
        j,
        appointmentProposal: AppointmentProposal(
          options: options,
          by: appointmentUid,
          endAt: endAt,
          note: note,
        ),
      ),
    );
  }

  @override
  Future<void> respondToAppointment(String jobId, int optionIndex) async {
    appointmentCalls.add('accept:$jobId:$optionIndex');
    _updateJob(jobId, (j) {
      final proposal = j.appointmentProposal;
      if (proposal == null) {
        return _rebuild(j, clearAppointmentProposal: true);
      }
      return _rebuild(
        j,
        appointment: Appointment(
          startAt: proposal.options[optionIndex],
          endAt: proposal.endAt,
        ),
        clearAppointmentProposal: true,
      );
    });
  }

  @override
  Future<void> withdrawAppointmentProposal(String jobId) async {
    appointmentCalls.add('withdraw:$jobId');
    _updateJob(jobId, (j) => _rebuild(j, clearAppointmentProposal: true));
  }

  @override
  Future<void> markOnTheWay(String jobId, int etaMinutes) async {
    appointmentCalls.add('onTheWay:$jobId:$etaMinutes');
    _updateJob(
      jobId,
      (j) => _rebuild(j, onTheWayAt: DateTime.now(), etaMinutes: etaMinutes),
    );
  }

  @override
  Future<void> markArrived(String jobId) async {
    appointmentCalls.add('arrived:$jobId');
    _updateJob(jobId, (j) => _rebuild(j, arrivedAt: DateTime.now()));
  }


  /// Yields the timeline seeded in the constructor (or added by
  /// [recordHandover]), re-emitting on every job/event change.
  ///
  /// The real query is `orderBy('at', descending: true).limit(50)` and the
  /// UI renders the list as-is, so seed **newest first** - oldest-first here
  /// would quietly test the opposite of production and make `events.first`
  /// the wrong entry.
  @override
  Stream<List<JobEvent>> watchJobEvents(String jobId) async* {
    List<JobEvent> current() => _events[jobId] ?? const [];
    yield current();
    await for (final _ in _changes.stream) {
      yield current();
    }
  }

  @override
  Stream<List<Job>> watchSavedJobs(List<String> jobIds) async* {
    List<Job> mine() => _jobs.where((j) => jobIds.contains(j.id)).toList();
    yield mine();
    await for (final _ in _changes.stream) {
      yield mine();
    }
  }

  @override
  Future<void> setJobAddress(String jobId, ServiceAddress address) async {
    _addresses[jobId] = address;
    _notify();
  }

  @override
  Stream<ServiceAddress?> watchJobAddress(String jobId) async* {
    yield _addresses[jobId];
    await for (final _ in _changes.stream) {
      yield _addresses[jobId];
    }
  }

  /// Mimics the `releaseMilestone` Cloud Function's completion write when the
  /// last milestone releases (called by [FakeMilestoneRepository]).
  void complete(String id) {
    final i = _jobs.indexWhere((j) => j.id == id);
    if (i == -1) return;
    _jobs[i] = _rebuild(_jobs[i], status: JobStatus.completed);
    _notify();
  }

  /// Mimics a refund ruling, which ends the job.
  void cancel(String id) {
    final i = _jobs.indexWhere((j) => j.id == id);
    if (i == -1) return;
    _jobs[i] = _rebuild(_jobs[i], status: JobStatus.cancelled);
    _notify();
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
    _notify();
  }

  /// Rebuilds [j] with overrides - the fake's stand-in for a Firestore update,
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
    Appointment? appointment,
    AppointmentProposal? appointmentProposal,
    bool clearAppointmentProposal = false,
    DateTime? onTheWayAt,
    int? etaMinutes,
    DateTime? arrivedAt,
  }) => Job(
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
    bundleId: j.bundleId,
    bundleOrder: j.bundleOrder,
    bundleTaskCount: j.bundleTaskCount,
    releasedAt: j.releasedAt,
    schedulingRequired: j.schedulingRequired,
    appointment: appointment ?? j.appointment,
    appointmentProposal: clearAppointmentProposal
        ? null
        : (appointmentProposal ?? j.appointmentProposal),
    onTheWayAt: onTheWayAt ?? j.onTheWayAt,
    etaMinutes: etaMinutes ?? j.etaMinutes,
    arrivedAt: arrivedAt ?? j.arrivedAt,
  );
}

/// What:   In-memory [BidRepository]. Streams re-emit whenever a bid changes so the
///         detail screen updates live, like Firestore snapshots would. [auth] backs
///         the `acceptBid` wallet-balance gate: accepting is blocked when the bid
///         amount exceeds the requestor's available balance, and a successful accept
///         debits the amount from the wallet - mirroring the `acceptBid` Cloud
///         Function.
class FakeBidRepository implements BidRepository {
  FakeBidRepository(this.jobs, this.auth, [List<Bid> bids = const []])
    : _bids = [...bids];

  final FakeJobRepository jobs;
  final FakeAuthRepository auth;
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
      (b) => b.jobId == bid.jobId && b.providerId == bid.providerId,
    );
    _bids.add(bid);
    _notify();
  }

  @override
  Future<void> withdrawBid(String jobId, String providerId) async {
    _bids.removeWhere((b) => b.jobId == jobId && b.providerId == providerId);
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
    Bid? mine() => _bids.cast<Bid?>().firstWhere(
      (b) => b!.jobId == jobId && b.providerId == providerId,
      orElse: () => null,
    );
    yield mine();
    await for (final _ in _changes.stream) {
      yield mine();
    }
  }

  @override
  Future<void> acceptBid(Bid bid) async {
    // Mirrors the `acceptBid` Cloud Function's balance gate.
    final available = auth.walletBalanceSen;
    if (bid.amountSen > available) {
      throw InsufficientBalanceException(
        shortfallSen: bid.amountSen - available,
        availableSen: available,
        requiredSen: bid.amountSen,
      );
    }
    for (var i = 0; i < _bids.length; i++) {
      final b = _bids[i];
      if (b.jobId != bid.jobId || b.status != BidStatus.pending) continue;
      _bids[i] = _withStatus(
        b,
        b.providerId == bid.providerId
            ? BidStatus.accepted
            : BidStatus.rejected,
      );
    }
    auth.walletBalanceSen -= bid.amountSen;
    jobs.assign(bid);
    _notify();
  }
}

/// What:   In-memory [MilestoneRepository]. Release mimics the Cloud Functions'
///         status flips - and, on the last release, completing the job via the fake
///         job repo. No wallet money moves in widget tests.
class FakeMilestoneRepository implements MilestoneRepository {
  FakeMilestoneRepository(this.jobs, [List<Milestone> seed = const []])
    : _milestones = [...seed];

  final FakeJobRepository jobs;
  final List<Milestone> _milestones;
  final _changes = StreamController<void>.broadcast();

  void _notify() => _changes.add(null);

  Milestone _withStatus(
    Milestone m,
    MilestoneStatus status, {
    String? note,
    String? reworkNote,
    String? disputedBy,
  }) => Milestone(
    id: m.id,
    jobId: m.jobId,
    providerId: m.providerId,
    description: m.description,
    amountSen: m.amountSen,
    order: m.order,
    status: status,
    submissionNote: note ?? m.submissionNote,
    reworkNote: reworkNote ?? m.reworkNote,
    disputedBy: disputedBy,
    createdAt: m.createdAt,
  );

  void _update(String milestoneId, Milestone Function(Milestone) change) {
    final i = _milestones.indexWhere((m) => m.id == milestoneId);
    if (i == -1) return;
    _milestones[i] = change(_milestones[i]);
    _notify();
  }

  /// Mimics a dispute ruling of `release`: pays out and closes the milestone,
  /// completing the job when it was the last un-released one.
  void resolveRelease(String jobId, String milestoneId) {
    _update(milestoneId, (m) => _withStatus(m, MilestoneStatus.released));
    _maybeComplete(jobId);
  }

  /// Mimics a dispute ruling of `refund`: the money goes back and the job ends.
  void resolveRefund(String jobId, String milestoneId, {String? note}) {
    _update(milestoneId, (m) => _withStatus(m, MilestoneStatus.refunded));
    jobs.cancel(jobId);
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
  Future<void> submitMilestone(
    String jobId,
    String milestoneId, {
    String? note,
  }) async {
    _update(
      milestoneId,
      (m) => _withStatus(m, MilestoneStatus.submitted, note: note),
    );
  }

  @override
  Future<void> releaseMilestone(String jobId, String milestoneId) async {
    _update(milestoneId, (m) => _withStatus(m, MilestoneStatus.released));
    _maybeComplete(jobId);
  }

  /// Completes the job when every milestone is terminal - `released`, or a
  /// legacy `resolved`, matching the production `isTerminal`.
  void _maybeComplete(String jobId) {
    final allTerminal = _milestones
        .where((m) => m.jobId == jobId)
        .every(
          (m) =>
              m.status == MilestoneStatus.released ||
              m.status == MilestoneStatus.resolved,
        );
    if (allTerminal) jobs.complete(jobId);
  }
}

/// What:   In-memory [WalletRepository]; records the amounts of top-up/withdraw calls
///         so tests can assert them. The ledger stays empty. The toyyibPay methods
///         return canned values - the live gateway is never exercised in widget
///         tests.
class FakeWalletRepository implements WalletRepository {
  final topUps = <int>[];
  final withdrawals = <int>[];

  @override
  Future<void> topUp(int amountSen) async => topUps.add(amountSen);

  @override
  Future<void> withdraw(int amountSen) async => withdrawals.add(amountSen);

  @override
  Future<({String billCode, String paymentUrl})> createTopUpBill(
    int amountSen,
  ) async => (billCode: 'test', paymentUrl: 'https://example.com');

  @override
  Future<bool> reconcileTopUp(String billCode) async => true;

  @override
  Stream<List<LedgerEntry>> watchMyTransactions(String uid) async* {
    yield const [];
  }

  /// Set up by default so withdraw tests reach the amount sheet.
  PayoutMethod? payoutMethod = const PayoutMethod(
    method: 'bank',
    masked: 'Maybank •••• 1234',
    holderName: 'Test User',
  );
  final savedPayouts = <Map<String, String?>>[];

  @override
  Stream<PayoutMethod?> watchPayoutMethod(String uid) async* {
    yield payoutMethod;
  }

  @override
  Future<void> savePayoutMethod({
    required String method,
    String? proxyType,
    String? bankSwift,
    String? accountNumber,
  }) async {
    savedPayouts.add({
      'method': method,
      'proxyType': proxyType,
      'bankSwift': bankSwift,
      'accountNumber': accountNumber,
    });
  }
}

/// What:   In-memory [DisputeRepository]. Raising a dispute mimics the Cloud
///         Function: it freezes the milestone (via [milestones]) and opens a dispute;
///         resolving records the ruling and closes it.
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
    raised.add((jobId: jobId, milestoneId: milestoneId, statement: statement));
    milestones?._update(
      milestoneId,
      (m) => milestones!._withStatus(
        m,
        MilestoneStatus.disputed,
        disputedBy: 'uid-1',
      ),
    );
    _open.add(
      Dispute(
        id: 'disp-${_open.length + 1}',
        jobId: jobId,
        jobTitle: 'Job $jobId',
        milestoneId: milestoneId,
        milestoneDescription: 'Milestone $milestoneId',
        amountSen: 0,
        raisedByRole: 'requestor',
        providerId: 'prov-1',
        statement: statement,
        evidenceUrls: evidenceUrls,
        createdAt: DateTime.now(),
      ),
    );
    _changes.add(null);
  }

  final withdrawn = <String>[];

  @override
  Future<void> withdrawDispute({
    required String jobId,
    required String milestoneId,
  }) async {
    withdrawn.add(milestoneId);
    milestones?._update(
      milestoneId,
      (m) => milestones!._withStatus(m, MilestoneStatus.funded),
    );
    _open.removeWhere((d) => d.milestoneId == milestoneId);
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
    // Mirror the Cloud Function: release pays out, refund ends the job.
    final d = _open.cast<Dispute?>().firstWhere(
      (d) => d!.id == disputeId,
      orElse: () => null,
    );
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

/// What:   In-memory [VerificationRepository]; seeded with pending applicants. Records
///         decisions so tests can assert an approve/reject removed the item.
class FakeVerificationRepository implements VerificationRepository {
  FakeVerificationRepository([List<PendingVerification> pending = const []])
    : _pending = [...pending];

  final List<PendingVerification> _pending;
  final _changes = StreamController<void>.broadcast();

  final decisions = <String, bool>{};
  String? lastReason;

  /// Set to drive the admin's "Automated ID checks" section.
  IdExtract? idExtract;
  SsmExtract? ssmExtract;

  @override
  Stream<List<PendingVerification>> watchPending() async* {
    yield List.of(_pending);
    await for (final _ in _changes.stream) {
      yield List.of(_pending);
    }
  }

  /// What the review gallery loads; add a selfie to show the face comparison.
  List<VerificationDocument> identityDocuments = const [
    VerificationDocument(
      label: 'Identity Document',
      url: 'https://fake.storage/id.jpg',
    ),
  ];

  @override
  Future<List<VerificationDocument>> loadIdentityDocuments(String uid) async =>
      identityDocuments;

  @override
  Future<IdExtract?> loadIdExtract(String uid) async => idExtract;

  @override
  Future<SsmExtract?> loadSsmExtract(String uid) async => ssmExtract;

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

/// What:   In-memory [UserAdminRepository]; seeded with a fixed user list. Records the
///         suspend/reinstate calls and reflects them back into the stream so the list
///         re-renders (Suspended pill / Reinstate button), mirroring the live doc.
class FakeUserAdminRepository implements UserAdminRepository {
  FakeUserAdminRepository([List<ManagedUser> seed = const []])
    : _users = [...seed];

  final List<ManagedUser> _users;
  final _changes = StreamController<void>.broadcast();

  /// Every setSuspended call, for tests to assert.
  final calls = <({String uid, bool suspended, String? reason})>[];

  /// Every clearMfa call, for tests to assert.
  final mfaClears = <String>[];

  @override
  Stream<List<ManagedUser>> watchUsers() async* {
    yield List.of(_users);
    await for (final _ in _changes.stream) {
      yield List.of(_users);
    }
  }

  @override
  Future<void> setSuspended({
    required String uid,
    required bool suspended,
    String? reason,
  }) async {
    calls.add((uid: uid, suspended: suspended, reason: reason));
    final i = _users.indexWhere((u) => u.uid == uid);
    if (i != -1) {
      final u = _users[i];
      _users[i] = ManagedUser(
        uid: u.uid,
        displayName: u.displayName,
        email: u.email,
        role: u.role,
        suspended: suspended,
        photoUrl: u.photoUrl,
      );
    }
    _changes.add(null);
  }

  @override
  Future<void> clearMfa(String uid) async {
    mfaClears.add(uid);
  }
}

/// What:   In-memory [ReviewRepository]; seeded with a fixed list of reviews. Records
///         left reviews and rejects a second review of the same job by the same reviewer.
class FakeReviewRepository implements ReviewRepository {
  FakeReviewRepository([List<Review> reviews = const []])
    : _reviews = [...reviews];

  final List<Review> _reviews;
  final _ids = <String>{};

  final left = <Review>[];

  @override
  Stream<List<Review>> watchReviews(String userId, {int limit = 20}) async* {
    yield _reviews.take(limit).toList();
  }

  @override
  Future<List<Review>> fetchReviewPage(
    String userId, {
    int limit = 20,
    DateTime? startAfter,
  }) async {
    final ordered = startAfter == null
        ? _reviews
        : _reviews
              .where(
                (r) => r.createdAt != null && r.createdAt!.isBefore(startAfter),
              )
              .toList();
    return ordered.take(limit).toList();
  }

  @override
  Future<void> leaveReview({
    required String revieweeId,
    required Review review,
    String? bundleId,
  }) async {
    final id = '$revieweeId/${bundleId ?? review.jobId}_${review.reviewerId}';
    if (!_ids.add(id)) throw const ReviewAlreadyExistsException();
    left.add(review);
  }

  @override
  Future<bool> hasReviewed({
    required String revieweeId,
    required String jobId,
    required String reviewerId,
    String? bundleId,
  }) async => _ids.contains('$revieweeId/${bundleId ?? jobId}_$reviewerId');

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

/// What:   In-memory [PublicProfileRepository]; seeded with profiles keyed by uid.
class FakePublicProfileRepository implements PublicProfileRepository {
  FakePublicProfileRepository([Map<String, PublicProfile> profiles = const {}])
    : _profiles = Map.of(profiles);

  final Map<String, PublicProfile> _profiles;

  @override
  Stream<PublicProfile?> watchProfile(String uid) async* {
    yield _profiles[uid];
  }

  @override
  Future<Map<String, ProviderTrust>> fetchTrust(Iterable<String> uids) async {
    // Only seeded profiles resolve; anyone else falls back to the score
    // stored on their bid, exactly as the real repository behaves when a
    // user document cannot be read.
    return {
      for (final uid in uids)
        if (_profiles[uid] case final p?)
          uid: (trustScore: p.trustScore, scoreVisible: p.scoreVisible),
    };
  }
}

/// What:   In-memory [UserReportRepository]; records filed reports so tests can
///         assert "Report this user" actually persists one (it used to be a stub
///         that acknowledged the report and dropped it).
class FakeUserReportRepository implements UserReportRepository {
  final List<({String reporterId, String reportedUid, String reason})> filed =
      [];

  /// When true, [reportUser] throws, so tests can assert the failure copy.
  bool shouldFail = false;

  @override
  Future<void> reportUser({
    required String reporterId,
    required String reportedUid,
    required String reason,
  }) async {
    if (shouldFail) throw Exception('offline');
    filed.add((
      reporterId: reporterId,
      reportedUid: reportedUid,
      reason: reason,
    ));
  }
}

/// What:   In-memory [ModerationRepository]; seeded with flagged reviews. Records
///         rulings so tests can assert hide/keep cleared the queue.
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

/// What:   In-memory [NotificationRepository]; seeded with notifications. Tracks
///         token registration so tests can assert the sign-in/out lifecycle.
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

/// What:   [AssistRepository] returning canned suggestions (or, by default, null -
///         proving the post-job form works with the assist entirely unavailable).
class FakeAssistRepository implements AssistRepository {
  FakeAssistRepository({this.priceRange, this.draft});

  final ({int minSen, int maxSen})? priceRange;
  final JobDraft? draft;

  @override
  Future<JobDraft?> suggestDraft({
    required String roughText,
    String? photoUrl,
  }) async => draft;


  @override
  Future<({int minSen, int maxSen})?> suggestPriceRange({
    required String category,
    required String description,
    String? photoUrl,
  }) async => priceRange;
}

/// What:   No-op [PushService] - tests exercise the in-app surfaces only.
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

/// What:   In-memory [StatsRepository] returning fixed numbers.
class FakeStatsRepository implements StatsRepository {
  FakeStatsRepository([PlatformStats? stats])
    : _stats =
          stats ??
          const PlatformStats(
            requestors: 11,
            providers: 12,
            openJobs: 13,
            inProgressJobs: 14,
            completedJobs: 15,
            pendingVerifications: 16,
            openDisputes: 17,
            releasedVolumeSen: 1234500,
            bundlesAwarded: 20,
            splitAwards: 5,
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

/// What:   In-memory [ChatRepository]. Streams re-emit whenever anything changes so
///         the conversation list, thread and unread badge update live.
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

  /// Rebuilds a conversation with overrides - the fake's stand-in for a
  /// Firestore update, since [Conversation] is immutable.
  Conversation _rebuild(
    Conversation c, {
    String? lastMessageText,
    DateTime? lastMessageAt,
    Map<String, int>? unreadCounts,
  }) => Conversation(
    id: c.id,
    jobId: c.jobId,
    jobTitle: c.jobTitle,
    requestorId: c.requestorId,
    requestorName: c.requestorName,
    providerId: c.providerId,
    providerName: c.providerName,
    lastMessageText: lastMessageText ?? c.lastMessageText,
    lastMessageAt: lastMessageAt ?? c.lastMessageAt,
    unreadCounts: unreadCounts ?? c.unreadCounts,
  );

  @override
  Future<String> openConversation(Job job) async {
    final id = '${job.id}_${job.acceptedProviderId}';
    if (_byId(id) == null) {
      _conversations.add(
        Conversation(
          id: id,
          jobId: job.id,
          jobTitle: job.title,
          requestorId: job.requestorId,
          requestorName: job.requestorName,
          providerId: job.acceptedProviderId!,
          providerName: job.acceptedProviderName ?? 'Provider',
          lastMessageAt: DateTime.now(),
        ),
      );
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
    list.add(
      Message(
        id: 'm-${list.length + 1}',
        senderId: senderId,
        text: text.trim(),
        createdAt: DateTime.now(),
      ),
    );
    final i = _conversations.indexWhere((c) => c.id == conversation.id);
    if (i != -1) {
      final c = _conversations[i];
      final recipient = c.participantIds.firstWhere(
        (id) => id != senderId,
        orElse: () => '',
      );
      _conversations[i] = _rebuild(
        c,
        lastMessageText: text.trim(),
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
    _conversations[i] = _rebuild(c, unreadCounts: {...c.unreadCounts, uid: 0});
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

/// What:   In-memory [BundleRepository]: serves the bundles a test seeds, and records
///         every `cancelBundle` so a test can assert the whole posting was called off
///         rather than one task.
class FakeBundleRepository implements BundleRepository {
  FakeBundleRepository([List<Bundle> bundles = const []])
    : _bundles = [...bundles];

  final List<Bundle> _bundles;

  /// Bundle ids passed to [cancelBundle], in call order.
  final List<String> cancelled = [];

  /// Arguments of the last [create], or null when it was never called.
  Map<String, Object?>? lastCreate;

  @override
  Future<String> create({
    required String title,
    required String description,
    required JobLocation location,
    required List<BundleTaskDraft> tasks,
    List<String> photoUrls = const [],
    DateTime? deadline,
  }) async {
    lastCreate = {
      'title': title,
      'description': description,
      'location': location,
      'tasks': tasks,
      'photoUrls': photoUrls,
      'deadline': deadline,
    };
    return 'bundle-new';
  }

  /// When set, thrown by the next [cancelBundle] instead of recording it -
  /// lets a test exercise the `BundleRejectedException` snackbar.
  Object? cancelError;

  @override
  Future<void> cancelBundle(String id) async {
    final error = cancelError;
    if (error != null) throw error;
    cancelled.add(id);
  }

  /// What [previewAward] hands back; empty unless a test seeds it.
  List<BundleAwardOption> awardOptions = const [];

  /// Arguments of the last [award], or null when it was never called.
  Map<String, Object?>? lastAward;

  /// When set, thrown by the next [award] instead of recording it - lets a
  /// test exercise the insufficient-balance and rejected-award paths.
  Object? awardError;

  @override
  Future<List<BundleAwardOption>> previewAward(String bundleId) async =>
      awardOptions;

  /// What [priceManualAward] hands back; null option and no problems unless
  /// a test seeds one or the other.
  BundleAwardOption? manualOption;
  List<String> manualProblems = const [];

  /// The `providerByTaskId` of the last [priceManualAward] call, or null.
  Map<String, String>? lastManualPicks;

  @override
  Future<({BundleAwardOption? option, List<String> problems})> priceManualAward(
    String bundleId,
    Map<String, String> providerByTaskId,
  ) async {
    lastManualPicks = providerByTaskId;
    return (option: manualOption, problems: manualProblems);
  }

  @override
  Future<void> award({
    required String bundleId,
    required Map<String, String> providerByTaskId,
    int? expectedTotalSen,
    DateTime? releasedDeadline,
    bool dropUnawarded = false,
  }) async {
    final error = awardError;
    if (error != null) throw error;
    lastAward = {
      'bundleId': bundleId,
      'providerByTaskId': providerByTaskId,
      'expectedTotalSen': expectedTotalSen,
      'releasedDeadline': releasedDeadline,
      'dropUnawarded': dropUnawarded,
    };
  }

  @override
  Stream<Bundle?> watchBundle(String id) async* {
    yield _byId(id);
  }

  @override
  Stream<List<Bundle>> watchMyBundles(String requestorId) async* {
    yield _bundles.where((b) => b.requestorId == requestorId).toList();
  }

  @override
  Future<Bundle?> getById(String id) async => _byId(id);

  Bundle? _byId(String id) => _bundles
      .cast<Bundle?>()
      .firstWhere((b) => b!.id == id, orElse: () => null);
}

/// What:   In-memory [BundleBidRepository]. The sheet's whole job is to turn a form
///         into one `submit` call, so the fake records that call's arguments instead
///         of modelling Firestore.
class FakeBundleBidRepository implements BundleBidRepository {
  FakeBundleBidRepository([List<BundleBid> bids = const []])
    : _bids = [...bids];

  final List<BundleBid> _bids;
  final _live = StreamController<void>.broadcast();

  /// Thrown by [submit] when set, to exercise the sheet's error banner.
  Object? submitError;

  /// Replaces every bid and re-emits on open [watchBundleBids] streams.
  void push(List<BundleBid> bids) {
    _bids
      ..clear()
      ..addAll(bids);
    _live.add(null);
  }

  /// Arguments of the last [submit], or null when it was never called.
  Map<String, Object?>? lastSubmission;

  /// Bundle ids passed to [withdraw], in call order.
  final List<String> withdrawn = [];

  @override
  Future<void> submit({
    required String bundleId,
    required Map<String, int> taskPrices,
    int? bundlePriceSen,
    required String estimatedDuration,
    String message = '',
  }) async {
    if (submitError != null) throw submitError!;
    lastSubmission = {
      'bundleId': bundleId,
      'taskPrices': taskPrices,
      'bundlePriceSen': bundlePriceSen,
      'estimatedDuration': estimatedDuration,
      'message': message,
    };
  }

  @override
  Future<void> withdraw(String bundleId) async => withdrawn.add(bundleId);

  @override
  Stream<BundleBid?> watchMyBundleBid(
    String bundleId,
    String providerId,
  ) async* {
    yield _bids.cast<BundleBid?>().firstWhere(
      (b) => b!.bundleId == bundleId && b.providerId == providerId,
      orElse: () => null,
    );
  }

  @override
  Future<BundleBid?> getMyBundleBid(String bundleId, String providerId) async =>
      _bids.cast<BundleBid?>().firstWhere(
        (b) => b!.bundleId == bundleId && b.providerId == providerId,
        orElse: () => null,
      );

  @override
  Stream<List<BundleBid>> watchBundleBids(String bundleId) async* {
    List<BundleBid> forBundle() =>
        _bids.where((b) => b.bundleId == bundleId).toList();
    yield forBundle();
    yield* _live.stream.map((_) => forBundle());
  }

  @override
  Stream<List<BundleBid>> watchMyBundleBids(String providerId) async* {
    yield _bids.where((b) => b.providerId == providerId).toList();
  }
}

/// What:   Face checker for tests: passes by default, or returns the given result.
///         Records the calls so tests can see whether a photo was checked at all.
class FakeFaceChecker implements FaceChecker {
  FakeFaceChecker([this.result = const FaceCheckResult()]);

  FaceCheckResult result;
  final calls = <FaceCheckKind>[];

  @override
  Future<FaceCheckResult> check(String filePath, FaceCheckKind kind) async {
    calls.add(kind);
    return result;
  }
}

