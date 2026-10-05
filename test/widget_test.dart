import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fairbid/core/app.dart';
import 'package:fairbid/core/config/platform_config.dart';
import 'package:fairbid/core/location/address_hint.dart';
import 'package:fairbid/core/location/geo.dart';
import 'package:fairbid/core/location/penang.dart';
import 'package:fairbid/core/location/penang_districts.dart';
import 'package:fairbid/core/location/region.dart';
import 'package:fairbid/core/location/region_picker_screen.dart';
import 'package:fairbid/core/theme/app_theme.dart';
import 'package:fairbid/core/util/money.dart';
import 'package:fairbid/core/util/service_categories.dart';
import 'package:fairbid/core/util/ssm_number.dart';
import 'package:fairbid/core/widgets/app_widgets.dart';
import 'package:fairbid/core/widgets/face_crop.dart';
import 'package:fairbid/core/widgets/form_widgets.dart';
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
import 'package:fairbid/features/auth/presentation/auth_controller.dart';
import 'package:fairbid/features/auth/presentation/mfa_code_sheet.dart';
import 'package:fairbid/features/auth/presentation/validators.dart';
import 'package:fairbid/features/disputes/data/dispute_repository.dart';
import 'package:fairbid/features/disputes/domain/dispute.dart';
import 'package:fairbid/features/jobs/data/assist_repository.dart';
import 'package:fairbid/features/jobs/data/bid_repository.dart';
import 'package:fairbid/features/jobs/data/bundle_bid_repository.dart';
import 'package:fairbid/features/jobs/data/bundle_repository.dart';
import 'package:fairbid/features/jobs/data/job_repository.dart';
import 'package:fairbid/features/jobs/data/milestone_repository.dart';
import 'package:fairbid/features/jobs/domain/bid.dart';
import 'package:fairbid/features/jobs/domain/bundle.dart';
import 'package:fairbid/features/jobs/domain/bundle_award.dart';
import 'package:fairbid/features/jobs/domain/bundle_bid.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/jobs/domain/job_event.dart';
import 'package:fairbid/features/jobs/domain/milestone.dart';
import 'package:fairbid/features/jobs/domain/service_address.dart';
import 'package:fairbid/features/jobs/presentation/bid/submit_bundle_bid_controller.dart';
import 'package:fairbid/features/jobs/presentation/bundle/bundle_detail_screen.dart';
import 'package:fairbid/features/jobs/presentation/bid/submit_bundle_bid_sheet.dart';
import 'package:fairbid/features/jobs/presentation/detail/service_address_sheet.dart';
import 'package:fairbid/features/jobs/presentation/detail/job_detail_view_model.dart';
import 'package:fairbid/features/jobs/presentation/widgets/bid_card.dart';
import 'package:fairbid/features/jobs/presentation/widgets/job_card.dart';
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
import 'package:fairbid/features/onboarding/presentation/onboarding_controller.dart';
import 'package:fairbid/features/onboarding/presentation/requestor_onboarding_controller.dart';
import 'package:fairbid/features/onboarding/presentation/requestor_steps/details_step.dart';
import 'package:fairbid/features/onboarding/presentation/steps/identity_step.dart';
import 'package:fairbid/features/onboarding/presentation/steps/profile_step.dart';
import 'package:fairbid/features/onboarding/presentation/steps/service_step.dart';
import 'package:fairbid/features/profile/data/public_profile_repository.dart';
import 'package:fairbid/features/profile/data/review_repository.dart';
import 'package:fairbid/features/profile/data/user_report_repository.dart';
import 'package:fairbid/features/profile/domain/public_profile.dart';
import 'package:fairbid/features/profile/domain/review.dart';
import 'package:fairbid/features/profile/presentation/edit_profile_screen.dart';
import 'package:fairbid/features/profile/presentation/public_profile_screen.dart';
import 'package:fairbid/features/wallet/data/wallet_repository.dart';
import 'package:fairbid/features/wallet/domain/ledger_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart' show Placemark;
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

/// The current text of every editable field on screen - lets a test assert
/// what a form was pre-filled with without tripping over placeholder hints,
/// which render as ordinary [Text] too.
List<String> _fieldValues(WidgetTester tester) => tester
    .widgetList<EditableText>(find.byType(EditableText))
    .map((field) => field.controller.text)
    .toList();

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
  String? payoutBankName;
  String? payoutAccountLast4;
  int walletBalanceSen = 0;

  /// Sen committed against accepted-but-not-yet-funded bids. Bumped by
  /// [FakeBidRepository.acceptBid] on success, mirroring the `acceptBid`
  /// Cloud Function's `escrowLockedSen` write.
  int escrowLockedSen = 0;
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

  /// Mirrors `User.emailVerified`. Defaults true so the existing dashboard
  /// tests don't render the banner; banner tests opt in with false.
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
      payoutBankName: payoutBankName,
      payoutAccountLast4: payoutAccountLast4,
      walletBalanceSen: walletBalanceSen,
      escrowLockedSen: escrowLockedSen,
      ratingCount: ratingCount,
      ratingSum: ratingSum,
      jobsCompleted: jobsCompleted,
      disputesLost: disputesLost,
      trustScore: trust.composite,
      trustBreakdown: trust,
      suspended: suspended,
      suspensionReason: suspensionReason,
      watchlist: List.of(watchlist),
      emailVerified: emailVerified,
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
        hints: [MfaFactor(uid: 'factor-1', displayName: 'Authenticator app')],
        resolver: 'fake-resolver',
      ));
    }
    _current = _build(role);
    _controller.add(_current);
  }

  @override
  Future<void> updateBaseLocation({
    required String uid,
    required double lat,
    required double lng,
    required String address,
    required String districtCode,
    String? town,
  }) async {
    baseLat = lat;
    baseLng = lng;
    baseDistrictCode = districtCode;
    baseTown = town;
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
        hints: [MfaFactor(uid: 'factor-1', displayName: 'Authenticator app')],
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
    required String label,
  }) async {
    if (code != validCode) {
      throw const AuthException('That code is incorrect.');
    }
    mfaFactors = [
      MfaFactor(uid: 'factor-1', displayName: label, enrolledAt: DateTime(2026)),
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
        hints: [MfaFactor(uid: 'factor-1', displayName: 'Authenticator app')],
        resolver: 'fake-resolver',
      ));
    }
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
  }) async => 'https://fake.storage/$uid/$purpose';

  @override
  Future<String> uploadSsmDocument({
    required String uid,
    required XFile file,
  }) async => 'https://fake.storage/$uid/ssm_document';

  @override
  Future<String> uploadSsmProfile({
    required String uid,
    required XFile file,
  }) async => 'https://fake.storage/$uid/ssm_profile';

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
  Future<String> uploadJobVideo({
    required String uid,
    required XFile file,
  }) async => 'https://fake.storage/jobs/$uid/video';

  @override
  Future<String> uploadDisputeEvidence({
    required String uid,
    required XFile file,
  }) async => 'https://fake.storage/disputes/$uid';

  @override
  Future<void> deleteByUrl(String url) async {}
}

/// In-memory [JobRepository] seeded with [jobs].
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

  @override
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

  @override
  Future<void> adminCancelJob(String jobId, {String? reason}) async {
    final i = _jobs.indexWhere((j) => j.id == jobId);
    if (i != -1) _jobs[i] = _rebuild(_jobs[i], status: JobStatus.cancelled);
    _notify();
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
  );
}

/// In-memory [BidRepository]. Streams re-emit whenever a bid changes so the
/// detail screen updates live, like Firestore snapshots would. [auth] backs
/// the `acceptBid` wallet-balance gate: accepting is blocked when the bid
/// amount exceeds the requestor's available balance, and a successful accept
/// locks the amount away (bumping [FakeAuthRepository.escrowLockedSen]) -
/// mirroring the `acceptBid` Cloud Function.
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
    // Mirrors the `acceptBid` Cloud Function's balance gate: available =
    // wallet balance minus what's already locked against other accepted bids.
    final available = auth.walletBalanceSen - auth.escrowLockedSen;
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
    auth.escrowLockedSen += bid.amountSen;
    jobs.assign(bid);
    _notify();
  }
}

/// In-memory [MilestoneRepository]. Fund/release mimic the Cloud Functions'
/// status flips - and, on the last release, completing the job via the fake
/// job repo. No wallet money moves in widget tests.
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
    int? reworkCount,
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
    reworkCount: reworkCount ?? m.reworkCount,
    disputedBy: disputedBy,
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
    String jobId,
    List<Milestone> milestones,
  ) async {
    // Mimics the `proposeMilestonePlan` Cloud Function: replaces any un-locked
    // plan and writes each milestone `proposed` (awaiting client approval).
    _milestones.removeWhere(
      (m) =>
          m.jobId == jobId &&
          (m.status == MilestoneStatus.proposed ||
              m.status == MilestoneStatus.pending),
    );
    for (final (i, m) in milestones.indexed) {
      _milestones.add(
        Milestone(
          id: 'm$i',
          jobId: jobId,
          providerId: m.providerId,
          description: m.description,
          amountSen: m.amountSen,
          order: i,
          status: MilestoneStatus.proposed,
          createdAt: DateTime.now(),
        ),
      );
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
      (m) => m.jobId == jobId && m.status == MilestoneStatus.proposed,
    );
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
  Future<void> fundMilestone(String jobId, String milestoneId) async {
    // Only a client-approved (pending) milestone is fundable, mirroring the
    // Cloud Function's precondition.
    final m = _milestones.cast<Milestone?>().firstWhere(
      (m) => m!.id == milestoneId,
      orElse: () => null,
    );
    if (m == null || m.status != MilestoneStatus.pending) return;
    _update(milestoneId, (m) => _withStatus(m, MilestoneStatus.funded));
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

/// In-memory [WalletRepository]; records the amounts of top-up/withdraw calls
/// so tests can assert them. The ledger stays empty. The toyyibPay methods
/// return canned values - the live gateway is never exercised in widget
/// tests.
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
        raisedByUid: 'uid-1',
        raisedByRole: 'requestor',
        requestorId: 'uid-1',
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

/// In-memory [VerificationRepository]; seeded with pending applicants. Records
/// decisions so tests can assert an approve/reject removed the item.
class FakeVerificationRepository implements VerificationRepository {
  FakeVerificationRepository([List<PendingVerification> pending = const []])
    : _pending = [...pending];

  final List<PendingVerification> _pending;
  final _changes = StreamController<void>.broadcast();

  final decisions = <String, bool>{};
  String? lastReason;

  /// Set to drive the admin's "Automated ID checks" section.
  IdExtract? idExtract;

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

/// In-memory [UserAdminRepository]; seeded with a fixed user list. Records the
/// suspend/reinstate calls and reflects them back into the stream so the list
/// re-renders (Suspended pill / Reinstate button), mirroring the live doc.
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
        suspensionReason: reason,
        verificationStatus: u.verificationStatus,
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

/// In-memory [PublicProfileRepository]; seeded with profiles keyed by uid.
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

/// In-memory [UserReportRepository]; records filed reports so tests can
/// assert "Report this user" actually persists one (it used to be a stub
/// that acknowledged the report and dropped it).
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

/// [AssistRepository] returning canned suggestions (or, by default, null -
/// proving the post-job form works with the assist entirely unavailable).
class FakeAssistRepository implements AssistRepository {
  FakeAssistRepository({this.description, this.priceRange, this.draft});

  final String? description;
  final ({int minSen, int maxSen})? priceRange;
  final JobDraft? draft;

  @override
  Future<JobDraft?> suggestDraft({
    required String roughText,
    String? photoUrl,
  }) async => draft;

  @override
  Future<String?> suggestDescription({
    required String category,
    required String roughText,
    String? photoUrl,
  }) async => description;

  @override
  Future<({int minSen, int maxSen})?> suggestPriceRange({
    required String category,
    required String description,
    String? photoUrl,
  }) async => priceRange;
}

/// No-op [PushService] - tests exercise the in-app surfaces only.
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

  /// Rebuilds a conversation with overrides - the fake's stand-in for a
  /// Firestore update, since [Conversation] is immutable.
  Conversation _rebuild(
    Conversation c, {
    String? lastMessageText,
    String? lastMessageSenderId,
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
    lastMessageSenderId: lastMessageSenderId ?? c.lastMessageSenderId,
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

/// In-memory [BundleRepository]: serves the bundles a test seeds, and records
/// every `cancelBundle` so a test can assert the whole posting was called off
/// rather than one task.
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

/// In-memory [BundleBidRepository]. The sheet's whole job is to turn a form
/// into one `submit` call, so the fake records that call's arguments instead
/// of modelling Firestore.
class FakeBundleBidRepository implements BundleBidRepository {
  FakeBundleBidRepository([List<BundleBid> bids = const []])
    : _bids = [...bids];

  final List<BundleBid> _bids;

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
    yield _bids.where((b) => b.bundleId == bundleId).toList();
  }

  @override
  Stream<List<BundleBid>> watchMyBundleBids(String providerId) async* {
    yield _bids.where((b) => b.providerId == providerId).toList();
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

/// Builds a sample open bundle for tests, with [taskIds] naming its tasks.
Bundle sampleBundle({
  String id = 'bundle-1',
  String requestorId = 'uid-1',
  String title = 'Bathroom refresh',
  List<String> taskIds = const ['job-1', 'job-2'],
  DateTime? deadline,
  BundleStatus status = BundleStatus.open,
  int? consolidationCapPct,
  int? consolidationCapSen,
}) => Bundle(
  id: id,
  requestorId: requestorId,
  requestorName: 'Test User',
  title: title,
  description: 'Small bathroom, about 4 square metres.',
  location: const JobLocation(lat: 3.14, lng: 101.7, address: 'Penang'),
  taskIds: taskIds,
  consolidationCapPct: consolidationCapPct ?? PlatformConfig.consolidationCapPct,
  consolidationCapSen: consolidationCapSen ?? PlatformConfig.consolidationCapSen,
  createdAt: DateTime.now(),
  deadline: deadline,
  status: status,
);

Widget buildApp(
  FakeAuthRepository auth, {
  List<Job> jobs = const [],
  List<Bid> bids = const [],
  List<Review> reviews = const [],
  List<Milestone> milestones = const [],
  FakeJobRepository? jobRepository,
  FakeReviewRepository? review,
  FakePublicProfileRepository? publicProfile,
  FakeUserReportRepository? userReport,
  FakeVerificationRepository? verification,
  FakeChatRepository? chat,
  FakeDisputeRepository? dispute,
  FakeModerationRepository? moderation,
  FakeStatsRepository? stats,
  FakeNotificationRepository? notifications,
  FakeUserAdminRepository? userAdmin,
  FakeAssistRepository? assist,
  FakeBundleRepository? bundle,
  FakeBundleBidRepository? bundleBid,
  FakeMilestoneRepository? milestoneRepository,
}) {
  final jobRepo = jobRepository ?? FakeJobRepository(jobs);
  final milestoneRepo =
      milestoneRepository ?? FakeMilestoneRepository(jobRepo, milestones);
  final disputeRepo = dispute ?? FakeDisputeRepository();
  disputeRepo.milestones ??= milestoneRepo;
  return FairBidApp(
    authRepository: auth,
    onboardingRepository: FakeOnboardingRepository(auth),
    requestorOnboardingRepository: FakeRequestorOnboardingRepository(auth),
    documentStorageRepository: FakeDocumentStorageRepository(),
    jobRepository: jobRepo,
    bidRepository: FakeBidRepository(jobRepo, auth, bids),
    reviewRepository: review ?? FakeReviewRepository(reviews),
    publicProfileRepository: publicProfile ?? FakePublicProfileRepository(),
    userReportRepository: userReport ?? FakeUserReportRepository(),
    verificationRepository: verification ?? FakeVerificationRepository(),
    userAdminRepository: userAdmin ?? FakeUserAdminRepository(),
    chatRepository: chat ?? FakeChatRepository(),
    milestoneRepository: milestoneRepo,
    walletRepository: FakeWalletRepository(),
    disputeRepository: disputeRepo,
    moderationRepository: moderation ?? FakeModerationRepository(),
    statsRepository: stats ?? FakeStatsRepository(),
    notificationRepository: notifications ?? FakeNotificationRepository(),
    pushService: FakePushService(),
    assistRepository: assist ?? FakeAssistRepository(),
    bundleRepository: bundle ?? FakeBundleRepository(),
    bundleBidRepository: bundleBid ?? FakeBundleBidRepository(),
  );
}

Future<void> fillField(WidgetTester tester, String label, String text) async {
  // Field labels are external; find the TextFormField below the label text.
  final direct = find.widgetWithText(TextFormField, label);
  final field = direct.evaluate().isEmpty
      ? _fieldBelowLabel(tester, label)
      : direct;
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

/// Drives a `LocationField` showing [placeholder]: opens the Penang-scoped
/// picker, selects [districtLabel] from the District dropdown and confirms.
///
/// Deliberately avoids `pumpAndSettle` while the picker (and its map's
/// network-fetched tiles) is on screen - that would otherwise wait
/// indefinitely on the tile layer. Bounded `pump`s are enough to carry the
/// route transition, the dropdown menu and `PenangDistricts.ensureLoaded()`
/// (a local asset read) forward.
Future<void> pickPenangLocation(
  WidgetTester tester, {
  required String placeholder,
  String districtLabel = 'Barat Daya',
}) async {
  await tester.tap(find.text(placeholder));
  await tester.pump(const Duration(milliseconds: 400)); // push transition
  await tester.pump(const Duration(milliseconds: 200)); // ensureLoaded()

  // The default map centre (George Town) already auto-classifies into a
  // district by this point, so the field may show its name instead of the
  // "Select a district..." hint - and when the picker is pushed on top of a
  // screen that has its own dropdown (e.g. ServiceStep's category picker),
  // that earlier dropdown is still mounted (just behind the new route), so
  // `.first` in tree order can't be trusted either. Target the District
  // dropdown via its label instead.
  await tester.tap(_districtDropdown());
  await tester.pump(const Duration(milliseconds: 400)); // menu opens
  await tester.tap(find.text(districtLabel).last);
  await tester.pump(
    const Duration(milliseconds: 400),
  ); // menu closes + recentre

  await tester.tap(find.widgetWithText(FilledButton, 'Use this location'));
  await tester.pump(const Duration(milliseconds: 400)); // pop transition
  await tester.pumpAndSettle();
}

/// Finds `RegionPickerScreen`'s District dropdown specifically - its nearest
/// enclosing [Column] (shared with the "District" label) disambiguates it
/// from any other `DropdownButtonFormField` in the tree.
Finder _districtDropdown() {
  final column = find.ancestor(
    of: find.text('District'),
    matching: find.byType(Column),
  );
  return find
      .descendant(
        of: column.first,
        matching: find.byType(DropdownButtonFormField<String>),
      )
      .first;
}

void main() {
  // Pre-warm the Penang districts GeoJSON asset load once, before any test
  // builds a real FlutterMap/TileLayer (RegionPickerScreen). Doing that first
  // `rootBundle` read while a tile layer's concurrent network fetches are in
  // flight can leave the read hanging indefinitely (a flutter_test quirk) -
  // which would then wedge every later PenangDistricts.ensureLoaded() call,
  // including the classifier's own unit test, since they all await the same
  // cached (never-completing) Future.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await PenangDistricts.instance.ensureLoaded();
  });

  group('SSM number', () {
    test('decodes the current 12-digit format', () {
      final ssm = SsmNumber.parse('201903350205')!;
      expect(ssm.format, SsmNumberFormat.current);
      expect(ssm.year, 2019);
      expect(ssm.entityType, SsmEntityType.business);
      expect(ssm.normalized, '201903350205');
    });

    test('sample business profile decodes as a sole proprietorship', () {
      expect(SsmNumber.parse('200803090077')?.entityType, SsmEntityType.business);
    });

    test('accepts the combined form printed on certificates', () {
      final ssm = SsmNumber.parse('201903350205 (003058656-T)')!;
      expect(ssm.normalized, '201903350205');
      expect(ssm.legacyNumber, '003058656T');
    });

    test('accepts legacy formats with and without a state prefix', () {
      expect(SsmNumber.parse('003058656-T')?.normalized, '003058656T');
      expect(SsmNumber.parse('SA0085324-V')?.normalized, 'SA0085324V');
      expect(SsmNumber.parse('499519-U')?.normalized, '499519U');
    });

    test('normalises case and punctuation so the same number matches', () {
      expect(SsmNumber.parse('sa 0085324 - v')?.normalized, 'SA0085324V');
    });

    test('rejects an unknown entity type code', () {
      expect(SsmNumber.validate('201999350205'), isNotNull);
    });

    test('rejects an implausible year', () {
      expect(SsmNumber.validate('999903350205'), isNotNull);
    });

    test('names the digit count on a near miss', () {
      expect(SsmNumber.validate('20190335020'), contains('12 digits'));
    });

    test('requires a value', () {
      expect(SsmNumber.validate(''), isNotNull);
      expect(SsmNumber.validate(null), isNotNull);
    });
  });

  group('SSM autofill chain', () {
    /// A picker that yields a file without touching the platform channel, so
    /// the upload path can be exercised in a widget test at all.
    Future<XFile?> fakePicker() async =>
        XFile('ssm.pdf', mimeType: 'application/pdf');

    const verdict = SsmExtract(
      verdict: SsmVerdict.passed,
      businessName: 'Jin Xiao Long Trading',
      registrationNumber: '201903350205',
    );

    OnboardingController build(FakeOnboardingRepository repo) =>
        OnboardingController(repo, FakeDocumentStorageRepository(),
            pdfPicker: fakePicker);

    test('a verdict written before this session still reaches the UI', () async {
      final repo = FakeOnboardingRepository(FakeAuthRepository())
        ..ssmExtract = verdict;
      final controller = build(repo);

      await controller.loadFor('provider-1');
      await Future<void>.delayed(Duration.zero); // let the stream deliver

      expect(controller.ssmExtract, isNotNull,
          reason: 'resuming after an upload must still show the verdict');
    });

    test('the typed number is persisted before the document is uploaded',
        () async {
      final repo = FakeOnboardingRepository(FakeAuthRepository());
      final controller = build(repo);
      await controller.loadFor('provider-1');
      controller
        ..data.providerType = ProviderType.business
        ..setSsmNumber('201903350205');

      await controller.pickSsmDocument();

      // The extract trigger fires the instant the bytes land, and reads the
      // number from Firestore - so it has to be saved first or the server's
      // cross-check compares against nothing.
      expect(repo.saved?.ssmNumberNormalized, '201903350205',
          reason: 'the server cannot cross-check a number it cannot see');
    });

    test('applying the verdict fills both fields', () async {
      final repo = FakeOnboardingRepository(FakeAuthRepository())
        ..ssmExtract = verdict;
      final controller = build(repo);
      await controller.loadFor('provider-1');
      await Future<void>.delayed(Duration.zero);

      controller.applySsmExtract();

      expect(controller.data.businessName, 'Jin Xiao Long Trading');
      expect(controller.data.ssmNumber, '201903350205');
      expect(controller.data.ssmNumberNormalized, '201903350205');
    });

    test('SsmExtract.fromMap reads what the Cloud Function writes', () {
      final extract = SsmExtract.fromMap({
        'verdict': 'needsReview',
        'failures': ['not-digitally-signed'],
        'businessName': 'Sunmal Dental Art',
        'registrationNumber': '200803090077',
        'entityStatus': 'ACTIVE',
        'ownership': 'SOLE PROPRIETORSHIP',
        'expiryDate': '2020-10-08',
        'businessStartDate': '2008-05-05',
        'natureOfBusiness': 'PERKHIDMATAN PERGIGIAN & KESIHATAN',
        'signaturePresent': false,
      });

      expect(extract, isNotNull);
      expect(extract!.verdict, SsmVerdict.needsReview);
      expect(extract.hasProposals, isTrue);
      expect(extract.reasons.single, contains('not a digitally certified copy'));
      expect(extract.expiryDate, '2020-10-08');
      expect(extract.businessStartDate, '2008-05-05');
      expect(extract.natureOfBusiness, 'PERKHIDMATAN PERGIGIAN & KESIHATAN');
    });

    test('an expired registration reads as a plain-English reason', () {
      final extract = SsmExtract.fromMap({
        'verdict': 'rejected',
        'failures': ['registration-expired'],
        'expiryDate': '2020-10-08',
      });

      expect(extract!.verdict, SsmVerdict.rejected);
      expect(extract.reasons.single, contains('expired'));
    });

    test('the owner check is three-valued, not a boolean', () {
      SsmExtract? read(Object? value) => SsmExtract.fromMap({
            'verdict': 'passed',
            'ownerNameMatches': value,
          });

      expect(read(true)!.ownerNameMatches, isTrue);
      expect(read(false)!.ownerNameMatches, isFalse);
      // Absent means no Profile was supplied, or neither name was usable -
      // which is emphatically not the same as "the owner does not match".
      expect(read(null)!.ownerNameMatches, isNull);
    });

    test('a registered trade suggests a category, in Malay or English', () {
      expect(suggestedCategoryFor('PERKHIDMATAN PEMBERSIHAN AM'), 'Cleaning');
      expect(suggestedCategoryFor('KERJA-KERJA PERPAIPAN'), 'Plumbing');
      expect(suggestedCategoryFor('PENYAMAN UDARA'), 'Aircon Servicing');
      expect(suggestedCategoryFor('General cleaning services'), 'Cleaning');
    });

    test('an unmatched trade suggests nothing rather than guessing', () {
      // The Profile sample is a dental practice - not one of the ten
      // categories this app serves. A confident null beats a wrong guess,
      // because the suggestion is written into the applicant's form.
      expect(suggestedCategoryFor('PERKHIDMATAN PERGIGIAN & KESIHATAN'),
          isNull);
      expect(suggestedCategoryFor(null), isNull);
      expect(suggestedCategoryFor(''), isNull);
    });

    test('an unrecognised verdict is treated as no verdict', () {
      expect(SsmExtract.fromMap({'verdict': 'weird'}), isNull);
      expect(SsmExtract.fromMap(null), isNull);
    });
  });

  group('SSM autofill into the later stages', () {
    /// Builds a controller whose server verdict is already in, then pumps
    /// [step] - the autofill happens in each step's initState, so the
    /// assertions are on the controller rather than on rendered widgets.
    Future<OnboardingController> pumpStage(
      WidgetTester tester,
      Widget step, {
      String? natureOfBusiness,
      void Function(OnboardingData data)? seed,
    }) async {
      await tester.binding.setSurfaceSize(const Size(500, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final repo = FakeOnboardingRepository(FakeAuthRepository())
        ..ssmExtract = SsmExtract(
          verdict: SsmVerdict.passed,
          businessName: 'Jin Xiao Long Trading',
          natureOfBusiness: natureOfBusiness,
        );
      final controller =
          OnboardingController(repo, FakeDocumentStorageRepository());
      // runAsync, because loadFor awaits a stream delivery and testWidgets'
      // fake-async zone will not drain it - a plain await here deadlocks.
      await tester.runAsync(() async {
        await controller.loadFor('provider-1');
        await Future<void>.delayed(Duration.zero); // let the verdict arrive
      });
      controller.data.providerType = ProviderType.business;
      seed?.call(controller.data);

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: ChangeNotifierProvider<OnboardingController>.value(
          value: controller,
          child: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: step,
            ),
          ),
        ),
      ));
      await tester.pump();
      return controller;
    }

    testWidgets('stage 4 offers the registered name as the display name', (
      tester,
    ) async {
      await pumpStage(tester, const ProfileStep(),
          seed: (data) => data.businessName = 'Jin Xiao Long Trading');

      expect(find.widgetWithText(TextFormField, 'Jin Xiao Long Trading'),
          findsOneWidget);
    });

    testWidgets('stage 4 never overwrites a display name already chosen', (
      tester,
    ) async {
      await pumpStage(tester, const ProfileStep(), seed: (data) {
        data
          ..businessName = 'Jin Xiao Long Trading'
          ..displayName = 'Ah Long Plumbing';
      });

      expect(find.widgetWithText(TextFormField, 'Ah Long Plumbing'),
          findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Jin Xiao Long Trading'),
          findsNothing);
    });

    testWidgets('stage 5 suggests a category from the registered trade', (
      tester,
    ) async {
      final controller = await pumpStage(tester, const ServiceStep(),
          natureOfBusiness: 'KERJA-KERJA PERPAIPAN');

      expect(controller.data.category, 'Plumbing');
    });

    testWidgets('stage 5 never overwrites a category already chosen', (
      tester,
    ) async {
      final controller = await pumpStage(tester, const ServiceStep(),
          natureOfBusiness: 'KERJA-KERJA PERPAIPAN',
          seed: (data) => data.category = 'Tutoring');

      expect(controller.data.category, 'Tutoring');
    });

    testWidgets('stage 5 leaves the category alone for an unmatched trade', (
      tester,
    ) async {
      // The Profile sample is a dental practice - not a category this app
      // serves, so nothing should be filled in.
      final controller = await pumpStage(tester, const ServiceStep(),
          natureOfBusiness: 'PERKHIDMATAN PERGIGIAN & KESIHATAN');

      expect(controller.data.category, isNull);
    });
  });

  group('Business provider SSM step', () {
    /// Pumps the identity stage on its own, with the controller pre-loaded and
    /// the ID and selfie already uploaded - so the only thing standing between
    /// it and Continue is the SSM block under test.
    Future<OnboardingController> pumpStep(
      WidgetTester tester, {
      ProviderType type = ProviderType.business,
      IdDocumentType idType = IdDocumentType.passport,
      bool consent = true,
    }) async {
      await tester.binding.setSurfaceSize(const Size(500, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // A verdict is preloaded so the ID card is not a never-settling spinner.
      final controller = OnboardingController(
        FakeOnboardingRepository(FakeAuthRepository())
          ..idExtract = const IdExtract(verdict: IdVerdict.passed),
        FakeDocumentStorageRepository(),
      );
      await tester.runAsync(() async {
        await controller.loadFor('provider-1');
        await Future<void>.delayed(Duration.zero);
      });
      controller.data
        ..providerType = type
        ..idDocumentType = idType
        ..idDocumentUrl = 'https://fake.storage/id'
        ..selfieUrl = 'https://fake.storage/selfie'
        ..idConsentAt = consent ? DateTime(2026, 9, 30) : null;

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: ChangeNotifierProvider<OnboardingController>.value(
          value: controller,
          child: const Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: IdentityStep(),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return controller;
    }

    FilledButton continueButton(WidgetTester tester) => tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue'));

    /// The document is uploaded through the system file picker, which cannot
    /// run in a widget test - so apply the result the upload would have
    /// produced, then notify, exactly as `pickSsmDocument` does.
    void attachDocument(OnboardingController controller) {
      controller.data.ssmDocumentUrl = 'https://fake.storage/ssm';
      controller.selectProviderType(ProviderType.business);
    }

    testWidgets('individual providers never see the business block', (
      tester,
    ) async {
      await pumpStep(tester, type: ProviderType.individual);

      expect(find.text('Business registration'), findsNothing);
      // ID and selfie are already in place, so nothing else blocks Continue.
      expect(continueButton(tester).onPressed, isNotNull);
    });

    testWidgets('a business is blocked until name, number and document are in', (
      tester,
    ) async {
      final controller = await pumpStep(tester);

      expect(find.text('Business registration'), findsOneWidget);
      expect(continueButton(tester).onPressed, isNull,
          reason: 'nothing supplied yet');

      await fillField(
          tester, 'Registered Business Name', 'Jin Xiao Long Trading');
      await fillField(tester, 'SSM Registration Number', '201903350205');
      await tester.pumpAndSettle();
      expect(continueButton(tester).onPressed, isNull,
          reason: 'the SSM document is required');

      attachDocument(controller);
      await tester.pump(); // a spinner is now on screen - see above
      expect(continueButton(tester).onPressed, isNotNull);
    });

    testWidgets('names what is still missing instead of only disabling', (
      tester,
    ) async {
      await pumpStep(tester);

      String hint() =>
          tester.widget<Text>(find.textContaining('Still needed:')).data!;

      // The button is driven by the same list as the hint, so the two can
      // never disagree - that is the point of the change.
      expect(continueButton(tester).onPressed, isNull);
      expect(hint(), contains('your registered business name'));
      expect(hint(), contains('a valid SSM registration number'));
      expect(hint(), contains('your SSM document'));

      await fillField(
          tester, 'Registered Business Name', 'Jin Xiao Long Trading');
      await tester.pumpAndSettle();
      expect(hint(), isNot(contains('your registered business name')),
          reason: 'the hint must shrink as requirements are met');
    });

    testWidgets('shows a checking state between upload and verdict', (
      tester,
    ) async {
      final controller = await pumpStep(tester);
      attachDocument(controller); // uploaded, no verdict yet
      // pump(), not pumpAndSettle(): the checking card holds a
      // CircularProgressIndicator, which never stops animating and so never
      // lets the tree settle.
      await tester.pump();

      expect(find.textContaining('Checking your document'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
    });

    testWidgets('the owner check is offered but never gates Continue', (
      tester,
    ) async {
      final controller = await pumpStep(tester);
      expect(find.text('Confirm you are the owner (optional)'), findsOneWidget);

      await fillField(
          tester, 'Registered Business Name', 'Jin Xiao Long Trading');
      await fillField(tester, 'SSM Registration Number', '201903350205');
      await tester.pumpAndSettle();
      attachDocument(controller);
      await tester.pump();

      // No Business Profile supplied - Continue must still be available, or
      // the "optional" framing is a lie.
      expect(continueButton(tester).onPressed, isNotNull);
    });

    testWidgets('an unparseable SSM number keeps Continue locked', (
      tester,
    ) async {
      final controller = await pumpStep(tester);
      await fillField(
          tester, 'Registered Business Name', 'Jin Xiao Long Trading');
      await fillField(tester, 'SSM Registration Number', '12345');
      await tester.pumpAndSettle();
      // Attached last: once the checking card is up, nothing settles.
      attachDocument(controller);
      await tester.pump();

      expect(continueButton(tester).onPressed, isNull);
    });

    testWidgets('the typed number is normalised for matching', (
      tester,
    ) async {
      final controller = await pumpStep(tester);

      await fillField(tester, 'SSM Registration Number', 'sa 0085324 - v');
      await tester.pumpAndSettle();

      expect(controller.data.ssmNumberNormalized, 'SA0085324V');
    });

    String hint(WidgetTester tester) =>
        tester.widget<Text>(find.textContaining('Still needed:')).data!;

    testWidgets('an invalid MyKad number shows an error and blocks Continue', (
      tester,
    ) async {
      await pumpStep(tester,
          type: ProviderType.individual, idType: IdDocumentType.mykad);

      expect(hint(tester), contains('a valid MyKad number'));
      await fillField(tester, 'MyKad Number', '901301-07-1234');
      await tester.pumpAndSettle();

      expect(find.text('The birth date in this number is not a real date.'),
          findsOneWidget);
      expect(continueButton(tester).onPressed, isNull);
      expect(hint(tester), contains('a valid MyKad number'));
    });

    testWidgets('a valid MyKad number clears the requirement', (
      tester,
    ) async {
      final controller = await pumpStep(tester,
          type: ProviderType.individual, idType: IdDocumentType.mykad);

      await fillField(tester, 'MyKad Number', '900101-07-1234');
      await tester.pumpAndSettle();

      expect(find.text('Still needed: a valid MyKad number.'), findsNothing);
      expect(controller.data.icNumber, '900101-07-1234');
      // A number typed after the photo went up invalidates the photo.
      expect(controller.data.idDocumentUrl, isNull);
    });

    testWidgets('Passport hides the MyKad field', (tester) async {
      await pumpStep(tester,
          type: ProviderType.individual, idType: IdDocumentType.mykad);
      expect(find.text('MyKad Number'), findsOneWidget);

      await tester.tap(find.text('Passport'));
      await tester.pumpAndSettle();

      expect(find.text('MyKad Number'), findsNothing);
      // The MyKad photo was never checked as a passport, so a fresh one is due.
      expect(hint(tester), isNot(contains('MyKad number')));
      expect(hint(tester), contains('a photo of your ID'));
    });

    test('changing the IC clears the uploaded ID, re-typing the same does not',
        () {
      final controller = OnboardingController(
        FakeOnboardingRepository(FakeAuthRepository()),
        FakeDocumentStorageRepository(),
      );
      controller.data.idDocumentUrl = 'https://fake.storage/id';

      controller.setIcNumber('900101-07-1234');
      expect(controller.data.idDocumentUrl, isNull);

      controller.data.idDocumentUrl = 'https://fake.storage/id';
      controller.setIcNumber('900101071234'); // same digits, no dashes
      expect(controller.data.idDocumentUrl, isNotNull);

      controller.setIcNumber('850615-10-5567');
      expect(controller.data.idDocumentUrl, isNull);
    });

    test('the IC is private and the ID type is public', () {
      final data = OnboardingData()
        ..icNumber = '900101-07-1234'
        ..idDocumentType = IdDocumentType.passport;
      expect(data.toMap().containsKey('icNumber'), isFalse);
      expect(data.privateMap()['icNumber'], '900101-07-1234');
      expect(OnboardingData.fromMap(data.toMap()).idDocumentType,
          IdDocumentType.passport);
      expect(OnboardingData.fromMap(null).idDocumentType,
          IdDocumentType.mykad);
    });
  });

  group('Automated ID check', () {
    test('switching ID type clears the uploaded photo, same type keeps it', () {
      final controller = OnboardingController(
        FakeOnboardingRepository(FakeAuthRepository()),
        FakeDocumentStorageRepository(),
      );
      controller.data.idDocumentUrl = 'https://fake.storage/id';

      controller.setIdDocumentType(IdDocumentType.mykad); // unchanged
      expect(controller.data.idDocumentUrl, isNotNull);

      controller.setIdDocumentType(IdDocumentType.passport);
      expect(controller.data.idDocumentUrl, isNull);
    });

    test('the ID type is saved before the photo uploads, for both types',
        () async {
      for (final type in IdDocumentType.values) {
        final events = <String>[];
        final controller = OnboardingController(
          _OrderRepo(FakeAuthRepository(), events),
          _OrderStorage(events),
          imagePicker: _FakePicker(),
          faceChecker: FakeFaceChecker(),
        );
        await controller.loadFor('provider-1');
        controller.data
          ..idDocumentType = type
          ..idConsentAt = DateTime(2026, 9, 30);

        await controller.pickIdDocument(ImageSource.gallery);

        expect(events, ['save:${type.name}', 'upload'], reason: type.name);
      }
    });

    test('IdExtract.fromMap reads the function output and tolerates gaps', () {
      final extract = IdExtract.fromMap({
        'verdict': 'rejected',
        'failures': ['ic-mismatch', 7, 'name-mismatch'],
        'maskedIc': '******-07-**34',
        'ageOk': true,
        'nameMatches': null,
        'storagePath': 'verification/u/id_document_1.jpg',
      });
      expect(extract!.verdict, IdVerdict.rejected);
      expect(extract.failures, ['ic-mismatch', 'name-mismatch']);
      expect(extract.maskedIc, '******-07-**34');
      expect(extract.ageOk, isTrue);
      expect(extract.nameMatches, isNull);
      expect(extract.genderConsistent, isNull);
      expect(IdExtract.fromMap({'verdict': 'weird'}), isNull);
      expect(IdExtract.fromMap(null), isNull);
      expect(idFailureLabel('ic-mismatch'), contains('does not match'));
      expect(idFailureLabel('mystery'), 'mystery');
    });

    Future<OnboardingController> pumpCard(
      WidgetTester tester, {
      IdExtract? extract,
    }) async {
      await tester.binding.setSurfaceSize(const Size(500, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repo = FakeOnboardingRepository(FakeAuthRepository())
        ..idExtract = extract;
      final controller =
          OnboardingController(repo, FakeDocumentStorageRepository());
      await tester.runAsync(() async {
        await controller.loadFor('provider-1');
        await Future<void>.delayed(Duration.zero);
      });
      controller.data
        ..idDocumentType = IdDocumentType.mykad
        ..icNumber = '900101-07-1234'
        ..idDocumentUrl = 'https://fake.storage/id'
        ..selfieUrl = 'https://fake.storage/selfie'
        ..idConsentAt = DateTime(2026, 9, 30);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: ChangeNotifierProvider<OnboardingController>.value(
          value: controller,
          child: const Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: IdentityStep(),
            ),
          ),
        ),
      ));
      await tester.pump();
      return controller;
    }

    FilledButton continueButton(WidgetTester tester) => tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue'));

    testWidgets('shows a checking state until the verdict arrives', (
      tester,
    ) async {
      await pumpCard(tester);
      expect(find.textContaining('Checking your card'), findsOneWidget);
      expect(continueButton(tester).onPressed, isNotNull);
    });

    testWidgets('a verdict that never comes degrades to a background note', (
      tester,
    ) async {
      final controller = OnboardingController(
        FakeOnboardingRepository(FakeAuthRepository()),
        FakeDocumentStorageRepository(),
        imagePicker: _FakePicker(),
        faceChecker: FakeFaceChecker(),
      );
      await tester.binding.setSurfaceSize(const Size(500, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        await controller.loadFor('provider-1');
        await Future<void>.delayed(Duration.zero);
      });
      controller.data
        ..icNumber = '900101-07-1234'
        ..idConsentAt = DateTime(2026, 9, 30)
        ..selfieUrl = 'https://fake.storage/selfie';
      await controller.pickIdDocument(ImageSource.gallery);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: ChangeNotifierProvider<OnboardingController>.value(
          value: controller,
          child: const Scaffold(
            body: SingleChildScrollView(child: IdentityStep()),
          ),
        ),
      ));
      await tester.pump();
      expect(find.textContaining('Checking your card'), findsOneWidget);

      await tester.pump(const Duration(seconds: 31));
      expect(find.textContaining('Checking your card'), findsNothing);
      expect(find.textContaining('finish checking this in the background'),
          findsOneWidget);
      expect(continueButton(tester).onPressed, isNotNull);
    });

    testWidgets('a needs-review verdict lists each failure label', (
      tester,
    ) async {
      await pumpCard(tester,
          extract: const IdExtract(
              verdict: IdVerdict.needsReview,
              failures: ['name-mismatch', 'unknown-pb-code']));
      expect(find.text(idFailureLabel('name-mismatch')), findsOneWidget);
      expect(find.text(idFailureLabel('unknown-pb-code')), findsOneWidget);
      expect(find.text('An admin will review your documents.'), findsOneWidget);
    });

    testWidgets('a passed verdict says the card looks good', (tester) async {
      await pumpCard(tester,
          extract: const IdExtract(verdict: IdVerdict.passed));
      expect(find.text('Card details look good'), findsOneWidget);
      expect(continueButton(tester).onPressed, isNotNull);
    });

    testWidgets('a rejected verdict lists reasons but never blocks Continue', (
      tester,
    ) async {
      await pumpCard(tester,
          extract: const IdExtract(
              verdict: IdVerdict.rejected, failures: ['ic-mismatch']));
      expect(find.text(idFailureLabel('ic-mismatch')), findsOneWidget);
      expect(find.textContaining('retaking a clear'), findsOneWidget);
      expect(find.text('An admin will review your documents.'), findsOneWidget);
      expect(continueButton(tester).onPressed, isNotNull);
    });

    testWidgets('the card is hidden for passports', (tester) async {
      final controller = await pumpCard(tester);
      controller.setIdDocumentType(IdDocumentType.passport);
      await tester.pump();
      expect(find.textContaining('Checking your card'), findsNothing);
    });
  });

  group('Upload progress', () {
    Future<OnboardingController> build(
      _GatedStorage storage,
      FaceChecker faces,
    ) async {
      final controller = OnboardingController(
        FakeOnboardingRepository(FakeAuthRepository()),
        storage,
        imagePicker: _FakePicker(),
        faceChecker: faces,
      );
      await controller.loadFor('provider-1');
      controller.data
        ..icNumber = '900101-07-1234'
        ..idConsentAt = DateTime(2026, 9, 30);
      return controller;
    }

    Future<void> pumpIdentity(
      WidgetTester tester,
      OnboardingController controller,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: ChangeNotifierProvider<OnboardingController>.value(
          value: controller,
          child: const Scaffold(
            body: SingleChildScrollView(child: IdentityStep()),
          ),
        ),
      ));
      await tester.pump();
    }

    // The ID box is the first UploadBox on the page (individual, MyKad).
    Finder idBox() => find.byType(UploadBox).at(0);

    Future<void> tapIdBox(WidgetTester tester) async {
      await tester.tap(find.textContaining('JPEG, PNG up to 10MB'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose from gallery'));
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('the ID box spins while its upload is pending', (tester) async {
      final storage = _GatedStorage();
      final controller = await build(storage, FakeFaceChecker());
      await pumpIdentity(tester, controller);

      await tapIdBox(tester);
      expect(find.descendant(of: idBox(), matching: find.text('Uploading…')),
          findsOneWidget);
      expect(
          find.descendant(
              of: idBox(), matching: find.byType(CircularProgressIndicator)),
          findsOneWidget);
      // The selfie box is untouched.
      expect(find.descendant(
          of: find.byType(UploadBox).at(1), matching: find.text('Uploading…')),
          findsNothing);

      storage.gate.complete('https://fake.storage/id');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Document uploaded'), findsOneWidget);
      expect(find.text('Uploading…'), findsNothing);
      await tester.pump(const Duration(seconds: 31)); // the ID-check wait timer
    });

    testWidgets('a pending face check shows "Checking photo…"', (tester) async {
      final faces = _GatedFaceChecker();
      final storage = _GatedStorage()..gate.complete('https://fake.storage/id');
      final controller = await build(storage, faces);
      await pumpIdentity(tester, controller);

      await tapIdBox(tester);
      expect(find.descendant(of: idBox(), matching: find.text('Checking photo…')),
          findsOneWidget);
      expect(
          find.descendant(
              of: idBox(), matching: find.byType(CircularProgressIndicator)),
          findsOneWidget);

      faces.gate.complete(const FaceCheckResult());
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Checking photo…'), findsNothing);
      expect(find.text('Document uploaded'), findsOneWidget);
      await tester.pump(const Duration(seconds: 31)); // the ID-check wait timer
    });

    test('a second pick while one is in flight starts no second upload',
        () async {
      final storage = _GatedStorage();
      final controller = await build(storage, FakeFaceChecker());

      final first = controller.pickIdDocument(ImageSource.gallery);
      await Future<void>.delayed(Duration.zero);
      expect(controller.isUploading('id_document'), isTrue);
      expect(controller.isUploading('selfie'), isFalse);

      await controller.pickSelfie(ImageSource.gallery); // ignored
      expect(storage.purposes, ['id_document']);

      storage.gate.complete('https://fake.storage/id');
      await first;
      expect(controller.isUploading('id_document'), isFalse);
      expect(controller.data.selfieUrl, isNull);
      controller.dispose(); // cancels the ID-check wait timer
    });

    testWidgets('the requestor profile photo box spins while uploading',
        (tester) async {
      final storage = _GatedStorage();
      final controller = RequestorOnboardingController(
        FakeRequestorOnboardingRepository(FakeAuthRepository()),
        storage,
        imagePicker: _FakePicker(),
      );
      await controller.loadFor('client-1');
      await tester.binding.setSurfaceSize(const Size(500, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: ChangeNotifierProvider<RequestorOnboardingController>.value(
          value: controller,
          child: const Scaffold(
            body: SingleChildScrollView(child: DetailsStep()),
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.byType(UploadBox));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Uploading…'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(UploadBox),
              matching: find.byType(CircularProgressIndicator)),
          findsOneWidget);

      storage.gate.complete('https://fake.storage/avatar');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Photo added'), findsOneWidget);
      expect(find.text('Uploading…'), findsNothing);
    });
  });

  group('Face check and consent', () {
    const box =
        FaceBox(left: 0.25, top: 0.25, width: 0.5, height: 0.5, aspect: 1.5);
    const noFace = FaceCheckResult(problem: 'Face the camera straight on.');

    Future<(OnboardingController, List<String>)> build(
      FakeFaceChecker faces, {
      bool consent = true,
    }) async {
      final events = <String>[];
      final controller = OnboardingController(
        _OrderRepo(FakeAuthRepository(), events),
        _OrderStorage(events),
        imagePicker: _FakePicker(),
        faceChecker: faces,
      );
      await controller.loadFor('provider-1');
      if (consent) controller.data.idConsentAt = DateTime(2026, 9, 30);
      return (controller, events);
    }

    test('FaceBox survives toMap/fromMap, and bad maps give null', () {
      expect(FaceBox.fromMap(box.toMap()), box);
      expect(FaceBox.fromMap(null), isNull);
      expect(FaceBox.fromMap({'left': 0.1}), isNull);
    });

    test('a face problem shows the message and uploads nothing', () async {
      final (controller, events) = await build(FakeFaceChecker(noFace));

      await controller.pickSelfie(ImageSource.gallery);

      expect(controller.errorMessage, noFace.problem);
      expect(events, isEmpty, reason: 'no save and no upload');
      expect(controller.data.selfieUrl, isNull);
      expect(controller.isBusy, isFalse);
    });

    test('a passing photo uploads and its face box lands in privateMap',
        () async {
      final faces = FakeFaceChecker(const FaceCheckResult(box: box));
      final (controller, events) = await build(faces);

      await controller.pickSelfie(ImageSource.gallery);
      await controller.pickIdDocument(ImageSource.gallery);

      expect(faces.calls, [FaceCheckKind.selfie, FaceCheckKind.idCard]);
      expect(events, contains('upload'));
      expect(controller.data.selfieUrl, isNotNull);
      final private = controller.data.privateMap();
      expect(private['selfieFaceBox'], box.toMap());
      expect(private['idFaceBox'], box.toMap());
      expect(controller.data.toMap().containsKey('selfieFaceBox'), isFalse);
    });

    test('changing the IC drops the old ID face box', () async {
      final (controller, _) =
          await build(FakeFaceChecker(const FaceCheckResult(box: box)));
      await controller.pickIdDocument(ImageSource.gallery);
      expect(controller.data.idFaceBox, box);

      controller.setIcNumber('900101-07-1234');
      expect(controller.data.idFaceBox, isNull);
    });

    test('without consent nothing is checked or uploaded', () async {
      final faces = FakeFaceChecker();
      final (controller, events) = await build(faces, consent: false);

      await controller.pickSelfie(ImageSource.gallery);
      await controller.pickIdDocument(ImageSource.gallery);

      expect(faces.calls, isEmpty);
      expect(events, isEmpty);
    });

    test('consent is stamped in privateMap only, and unticking clears it', () {
      final controller = OnboardingController(
        FakeOnboardingRepository(FakeAuthRepository()),
        FakeDocumentStorageRepository(),
      );
      expect(controller.data.privateMap()['idConsentAt'], isNull);

      controller.setIdConsent(true);
      expect(controller.data.privateMap()['idConsentAt'], isA<DateTime>());
      expect(controller.data.toMap().containsKey('idConsentAt'), isFalse);

      controller.setIdConsent(false);
      expect(controller.data.privateMap()['idConsentAt'], isNull);
    });

    testWidgets('uploads stay locked and the hint asks until consent is ticked',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = OnboardingController(
        FakeOnboardingRepository(FakeAuthRepository()),
        FakeDocumentStorageRepository(),
      );
      await tester.runAsync(() async {
        await controller.loadFor('provider-1');
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: ChangeNotifierProvider<OnboardingController>.value(
          value: controller,
          child: const Scaffold(
            body: SingleChildScrollView(child: IdentityStep()),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      String hint() =>
          tester.widget<Text>(find.textContaining('Still needed:')).data!;
      final selfieBox = find.textContaining('Make sure face and ID are clear');

      expect(hint(), contains('your consent to identity checks'));
      await tester.tap(selfieBox, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Add your selfie'), findsNothing);

      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      expect(hint(), isNot(contains('consent')));
      expect(controller.data.idConsentAt, isNotNull);
      await tester.tap(selfieBox);
      await tester.pumpAndSettle();
      expect(find.text('Add your selfie'), findsOneWidget);
    });

    testWidgets('a failed image shows its icon inside the visible crop', (
      tester,
    ) async {
      for (final box in <FaceBox?>[
        const FaceBox(left: 0.4, top: 0.3, width: 0.2, height: 0.2, aspect: 1.5),
        null,
      ]) {
        await tester.pumpWidget(MaterialApp(
          home: Center(
            child: FaceCrop(url: 'https://fake.storage/gone.jpg', box: box),
          ),
        ));
        await tester.pumpAndSettle(); // the test HTTP client answers 400

        final icon = find.byIcon(Icons.broken_image_outlined);
        expect(icon, findsOneWidget, reason: 'box: $box');
        expect(icon.hitTestable(), findsOneWidget, reason: 'box: $box');
        final crop = tester.getRect(find.byType(FaceCrop));
        expect(crop.contains(tester.getCenter(icon)), isTrue, reason: 'box: $box');
      }
    });

    test('FaceCropLayout pads the box by 20% and scales it to the width', () {
      // Padded box is (0.15, 0.15, 0.7, 0.7); at 100 wide the image is 100/0.7.
      const b =
          FaceBox(left: 0.25, top: 0.25, width: 0.5, height: 0.5, aspect: 1);
      final l = FaceCropLayout.of(b, 100);
      expect(l.imageW, closeTo(142.857, 0.001));
      expect(l.imageH, closeTo(142.857, 0.001));
      expect(l.cropH, closeTo(100, 0.001));
      expect(l.left, closeTo(-21.428, 0.001));
      expect(l.top, closeTo(-21.428, 0.001));
    });

    test('FaceCropLayout keeps the padding inside the image', () {
      const b = FaceBox(left: 0, top: 0, width: 0.5, height: 0.5, aspect: 2);
      final l = FaceCropLayout.of(b, 100); // padded (0, 0, 0.6, 0.6)
      expect(l.left, 0);
      expect(l.top, 0);
      expect(l.imageW, closeTo(166.667, 0.001));
      expect(l.imageH, closeTo(83.333, 0.001));
      expect(l.cropH, closeTo(50, 0.001));
    });
  });

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

      final editable = tester.widget<EditableText>(
        find.byType(EditableText).first,
      );
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

    testWidgets('Forgot password with no email prompts for one', (
      tester,
    ) async {
      final repo = FakeAuthRepository();
      await tester.pumpWidget(buildApp(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Forgot?'));
      await tester.pump(); // let the snackbar animate in

      expect(find.text('Enter your email first'), findsOneWidget);
      expect(repo.passwordResetsSent, isEmpty);
    });

    testWidgets('Forgot password sends a reset email for the typed address', (
      tester,
    ) async {
      final repo = FakeAuthRepository();
      await tester.pumpWidget(buildApp(repo));
      await tester.pumpAndSettle();

      await fillField(tester, 'Email', 'test@fairbid.app');
      await tester.tap(find.text('Forgot?'));
      await tester.pumpAndSettle();

      expect(repo.passwordResetsSent, ['test@fairbid.app']);
      expect(
        find.text('Password reset email sent to test@fairbid.app'),
        findsOneWidget,
      );
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

    testWidgets('as requestor (Hire) is redirected into onboarding', (
      tester,
    ) async {
      // A brand-new requestor has not completed onboarding yet.
      await tester.pumpWidget(
        buildApp(FakeAuthRepository()..onboardingComplete = false),
      );
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

    testWidgets('requestor completes onboarding and lands on home', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(FakeAuthRepository()..onboardingComplete = false),
      );
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
      await pickPenangLocation(
        tester,
        placeholder: 'Pick your default location in Penang',
      );
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

    testWidgets('as provider (Work) is redirected into onboarding', (
      tester,
    ) async {
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

    testWidgets('onboarding continue unlocks after picking a provider type', (
      tester,
    ) async {
      await tester.pumpWidget(buildApp(FakeAuthRepository()));
      await tester.pumpAndSettle();
      await openRegister(tester);
      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();
      await fillRegisterForm(tester);
      await submit(tester);

      // Continue starts disabled.
      final continueButton = find.widgetWithText(FilledButton, 'Continue');
      expect(tester.widget<FilledButton>(continueButton).onPressed, isNull);

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

    testWidgets('shows the four bottom-nav tabs after sign-in', (tester) async {
      await tester.pumpWidget(buildApp(FakeAuthRepository()));
      await tester.pumpAndSettle();
      await login(tester);

      expect(find.byType(NavigationBar), findsOneWidget);
      for (final tab in ['Home', 'My jobs', 'Messages', 'Profile']) {
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

      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Profile'),
        ),
      );
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

    test('PublicProfile.fromMap maps every public field and cannot expose '
        'private ones', () {
      // A realistic doc carrying every field the mapper is forbidden from
      // reading (email/phone/wallet/payout/private-doc-only/coordinates/
      // raw disputesLost/suspension), alongside the fields it should map.
      final map = <String, dynamic>{
        'displayName': 'Jane Doe',
        'email': 'jane@example.com',
        'role': 'provider',
        'bio': 'Experienced plumber.',
        'location': 'Some free-text address',
        'baseTown': 'Bayan Lepas',
        'baseLat': 5.35,
        'baseLng': 100.28,
        'baseAddress': '12, Jalan Mawar 3',
        'walletBalanceSen': 999999,
        'escrowLockedSen': 5000,
        'verificationStatus': 'approved',
        'trustScore': 620,
        'trust': {
          'reviewScore': 80,
          'trackRecordScore': 70,
          'verificationScore': 100,
          'profileScore': 60,
          'composite': 620,
          'scoreVisible': true,
        },
        'ratingCount': 12,
        'ratingSum': 55,
        'jobsCompleted': 8,
        'jobsPosted': 3,
        'hireRate': 66,
        'disputesLost': 2,
        'suspended': true,
        'suspensionReason': 'spam',
        'profilePhotoUrl': 'https://example.com/me.jpg',
        'idDocumentUrl': 'https://example.com/id.jpg',
        'selfieUrl': 'https://example.com/selfie.jpg',
        'createdAt': DateTime(2025, 3, 1),
        'onboarding': {
          'providerType': 'individual',
          'category': 'Plumbing',
          'skills': ['Pipe repair', 'Leak detection'],
          'coverageArea': 'George Town, Bayan Lepas',
          'hourlyRate': '60',
          'portfolioImageUrls': ['https://example.com/p1.jpg'],
          'portfolioLinks': ['https://example.com/portfolio'],
          'certificateUrls': [
            'https://example.com/c1.pdf',
            'https://example.com/c2.pdf',
          ],
          'bankName': 'Maybank',
          'accountHolder': 'Jane Doe',
          'accountLast4': '6789',
          'branchCode': '1234',
        },
      };

      final profile = PublicProfile.fromMap('uid-1', map);

      // Public fields map correctly.
      expect(profile.displayName, 'Jane Doe');
      expect(profile.bio, 'Experienced plumber.');
      // Prefers the structured town over the free-text location field.
      expect(profile.location, 'Bayan Lepas');
      expect(profile.trustScore, 620);
      expect(profile.scoreVisible, isTrue);
      expect(profile.ratingCount, 12);
      expect(profile.averageRating, closeTo(55 / 12, 0.001));
      expect(profile.jobsCompleted, 8);
      expect(profile.jobsPosted, 3);
      expect(profile.hireRate, 66);
      expect(profile.category, 'Plumbing');
      expect(profile.skills, ['Pipe repair', 'Leak detection']);
      expect(profile.coverageArea, 'George Town, Bayan Lepas');
      expect(profile.hourlyRate, '60');
      expect(profile.portfolioImageUrls, ['https://example.com/p1.jpg']);
      expect(profile.portfolioLinks, ['https://example.com/portfolio']);
      expect(profile.memberSince, DateTime(2025, 3, 1));

      // Certificates are exposed only as a count, never the URLs - and
      // [PublicProfile] has no field/getter at all that could return them,
      // nor one for email/phone/wallet/payout/coordinates/suspension: the
      // type itself is the proof those values can never surface through
      // this model, regardless of what the source map carries.
      expect(profile.certificateCount, 2);
    });

    test('PublicProfile.hireRate is null when jobsPosted is zero', () {
      // Never a forged "0%" for a client who hasn't posted a job yet.
      final profile = PublicProfile.fromMap('uid-2', {
        'role': 'requestor',
        'jobsPosted': 0,
        'hireRate': 0,
      });
      expect(profile.jobsPosted, 0);
      expect(profile.hireRate, isNull);
    });

    test('PublicProfile falls back to the free-text location field', () {
      final profile = PublicProfile.fromMap('uid-3', {
        'role': 'requestor',
        'location': 'Georgetown',
      });
      expect(profile.location, 'Georgetown');
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
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Profile'),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows Earnings & payouts for a provider', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()..verificationStatus = 'approved';
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();
      await openRegisterAs(tester, 'Work');
      await openProfileTab(tester);

      expect(find.text('Earnings & payouts'), findsOneWidget);
    });

    testWidgets('hides Earnings & payouts for a requestor', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(buildApp(FakeAuthRepository()));
      await tester.pumpAndSettle();
      await loginRequestor(tester);
      await openProfileTab(tester);

      expect(find.text('Earnings & payouts'), findsNothing);
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

    testWidgets('reviews section shows the empty state with no reviews', (
      tester,
    ) async {
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
      await tester.pumpWidget(
        buildApp(FakeAuthRepository(), reviews: [review]),
      );
      await tester.pumpAndSettle();
      await loginRequestor(tester);
      await openProfileTab(tester);

      expect(find.text('Sarah Connor'), findsOneWidget);
      expect(find.text('"Communications were clear."'), findsOneWidget);
    });

    testWidgets('Trust Score card shows the New User state until earned', (
      tester,
    ) async {
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

      expect(find.text('New User'), findsOneWidget);
      // The four real sub-bars replace the old decorative ones.
      expect(find.text('Track Record'), findsOneWidget);
      expect(find.text('Verification'), findsOneWidget);
      expect(find.textContaining('/100'), findsNothing); // no headline number
    });

    testWidgets('Trust Score card shows the number once earned', (
      tester,
    ) async {
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

      expect(find.text('New User'), findsNothing);
      expect(find.textContaining('/100'), findsOneWidget);
    });

    testWidgets('earnings screen shows the balance and Withdraw', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..walletBalanceSen = 85000;
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();
      await openRegisterAs(tester, 'Work');
      await openProfileTab(tester);

      await tester.tap(find.text('Earnings & payouts'));
      await tester.pumpAndSettle();

      expect(find.text('RM\u00A0850.00'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Withdraw'), findsOneWidget);
    });

    testWidgets('delete account cancel keeps the user signed in', (
      tester,
    ) async {
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

    testWidgets('delete account confirmed with password signs the user out', (
      tester,
    ) async {
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
        'secret123',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      // Signed out -> router redirects back to the login screen.
      expect(find.text('Delete account?'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Log In'), findsOneWidget);
    });

    testWidgets('delete account failure shows an error and stays signed in', (
      tester,
    ) async {
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
        find.widgetWithText(TextField, 'Confirm your password'),
        'wrong',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Incorrect password.'), findsOneWidget);
      expect(find.text('Delete Account'), findsOneWidget);
    });
  });

  group('Email verification', () {
    Future<void> loginRequestor(WidgetTester tester) async {
      await fillField(tester, 'Email', 'test@fairbid.app');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();
    }

    testWidgets('unverified user sees the banner and can resend', (
      tester,
    ) async {
      final auth = FakeAuthRepository()..emailVerified = false;
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();
      await loginRequestor(tester);

      expect(find.text('Verify your email'), findsOneWidget);

      await tester.tap(find.text('Resend'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(auth.verificationEmailsSent, 1);
      expect(find.textContaining('Verification email sent'), findsOneWidget);

      // Let the 60s cooldown finish so its Timer.periodic self-cancels
      // instead of leaking past the end of the test.
      await tester.pump(const Duration(seconds: 61));
    });

    testWidgets('verified user sees no banner', (tester) async {
      await tester.pumpWidget(buildApp(FakeAuthRepository()));
      await tester.pumpAndSettle();
      await loginRequestor(tester);

      expect(find.text('Verify your email'), findsNothing);
    });

    testWidgets('tapping refresh after verifying hides the banner', (
      tester,
    ) async {
      final auth = FakeAuthRepository()
        ..emailVerified = false
        ..verifyOnReload = true;
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();
      await loginRequestor(tester);

      await tester.tap(find.byTooltip("I've verified - refresh"));
      await tester.pumpAndSettle();

      expect(find.text('Verify your email'), findsNothing);
    });

    testWidgets('withdrawing asks to confirm identity; cancelling stops it', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..walletBalanceSen = 85000;
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();
      await openRegisterAs(tester, 'Work');
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Profile'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Earnings & payouts'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Withdraw'));
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(auth.reauthCount, 0);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('confirming identity opens the withdraw amount sheet', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..walletBalanceSen = 85000;
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();
      await openRegisterAs(tester, 'Work');
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Profile'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Earnings & payouts'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Withdraw'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Your password'),
        'secret123',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await tester.pumpAndSettle();

      expect(auth.reauthCount, 1);
      expect(
        find.textContaining('Move money from your FairBid balance'),
        findsOneWidget,
      );
    });
  });

  group('Two-factor authentication', () {
    Future<void> loginRequestor(WidgetTester tester) async {
      await fillField(tester, 'Email', 'test@fairbid.app');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();
    }

    Future<void> openSecurityScreen(WidgetTester tester) async {
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Profile'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Security'));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'signing in with 2FA on prompts for a code; wrong code stays open, '
      'right code signs in',
      (tester) async {
        final auth = FakeAuthRepository()..requireMfaOnSignIn = true;
        await tester.pumpWidget(buildApp(auth));
        await tester.pumpAndSettle();
        await loginRequestor(tester);

        expect(find.text('Two-factor authentication'), findsOneWidget);
        expect(find.byType(NavigationBar), findsNothing);

        // The login screen's own fields are still mounted behind the sheet
        // (TextFormField renders a TextField internally too), so scope the
        // finder to the sheet's field.
        final codeField = find.descendant(
          of: find.byType(MfaCodeSheet),
          matching: find.byType(TextField),
        );
        await tester.enterText(codeField, '000000');
        await tester.tap(find.widgetWithText(FilledButton, 'Verify'));
        await tester.pumpAndSettle();
        expect(find.text('That code is incorrect.'), findsOneWidget);

        await tester.enterText(codeField, '123456');
        await tester.tap(find.widgetWithText(FilledButton, 'Verify'));
        await tester.pumpAndSettle();

        expect(find.byType(NavigationBar), findsOneWidget);
      },
    );

    testWidgets('security screen shows Off, then On after enrolling', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository();
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();
      await loginRequestor(tester);
      await openSecurityScreen(tester);

      expect(find.text('Off'), findsOneWidget);

      await tester.tap(find.widgetWithText(PrimaryButton, 'Turn on'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Your password'),
        'secret123',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      await tester.pumpAndSettle();

      expect(find.text('Scan this code'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '123456');
      await tester.tap(find.text('Verify and turn on'));
      await tester.pumpAndSettle();

      expect(find.text('On'), findsOneWidget);
    });

    testWidgets('unverified email blocks turning 2FA on', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()..emailVerified = false;
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();
      await loginRequestor(tester);
      await openSecurityScreen(tester);

      expect(find.text('Verify your email first'), findsOneWidget);
      expect(find.text('Turn on'), findsNothing);
    });

    testWidgets('turning off asks for confirmation, then returns to Off', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()
        ..mfaFactors = const [
          MfaFactor(uid: 'factor-1', displayName: 'Authenticator app'),
        ];
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();
      await loginRequestor(tester);
      await openSecurityScreen(tester);

      expect(find.text('On'), findsOneWidget);
      await tester.tap(find.widgetWithText(SecondaryButton, 'Turn off'));
      await tester.pumpAndSettle();

      expect(find.text('Turn off two-factor?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Turn off'));
      await tester.pumpAndSettle();

      expect(find.text('Off'), findsOneWidget);
    });

    testWidgets(
      'withdrawing as an enrolled user shows re-auth, then the code sheet',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 2200));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        // Seeded already signed in - this test targets the reauth path, not
        // the (separately covered) sign-in one, and requireMfaOnSignIn is a
        // single-use flag.
        final auth = FakeAuthRepository()
          ..verificationStatus = 'approved'
          ..walletBalanceSen = 85000
          ..mfaFactors = const [
            MfaFactor(uid: 'factor-1', displayName: 'Authenticator app'),
          ]
          ..requireMfaOnSignIn = true
          ..seedSignedIn(UserRole.provider);
        await tester.pumpWidget(buildApp(auth));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('Profile'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Earnings & payouts'));
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(FilledButton, 'Withdraw'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Your password'),
          'secret123',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
        await tester.pumpAndSettle();

        expect(find.text('Two-factor authentication'), findsOneWidget);

        // The reauth dialog's password field is still mounted behind the
        // sheet - scope the finder to the sheet's field.
        await tester.enterText(
          find.descendant(
            of: find.byType(MfaCodeSheet),
            matching: find.byType(TextField),
          ),
          '123456',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Verify'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Move money from your FairBid balance'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'deleting the account as an MFA-enrolled user with a stale session '
      'prompts for the code and completes the deletion',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 2200));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        // Seeded already signed in, same as the withdraw test above -
        // deleteAccount re-authenticates internally, so the challenge
        // surfaces from that call rather than a separate reauth dialog.
        final auth = FakeAuthRepository()
          ..mfaFactors = const [
            MfaFactor(uid: 'factor-1', displayName: 'Authenticator app'),
          ]
          ..requireMfaOnSignIn = true
          ..seedSignedIn(UserRole.requestor);
        await tester.pumpWidget(buildApp(auth));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('Profile'),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Delete Account'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Confirm your password'),
          'secret123',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
        await tester.pumpAndSettle();

        // The Security nav card behind the sheet also says "Two-factor
        // authentication", so scope this to the sheet itself.
        expect(find.byType(MfaCodeSheet), findsOneWidget);

        await tester.enterText(
          find.descendant(
            of: find.byType(MfaCodeSheet),
            matching: find.byType(TextField),
          ),
          '123456',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Verify'));
        await tester.pumpAndSettle();

        // Signed out -> router redirects back to the login screen.
        expect(find.text('Delete account?'), findsNothing);
        expect(find.widgetWithText(FilledButton, 'Log In'), findsOneWidget);
      },
    );
  });

  group('Money & distance', () {
    test('formatRm formats sen as RM', () {
      expect(formatRm(0), 'RM\u00A00.00');
      expect(formatRm(12550), 'RM\u00A0125.50');
      expect(formatRm(100000), 'RM\u00A01,000.00');
    });

    test('formatBudget handles fixed, range and hourly', () {
      expect(formatBudget(), isNull);
      expect(formatBudget(minSen: 10000), 'RM\u00A0100.00');
      expect(
        formatBudget(minSen: 10000, maxSen: 25000),
        'RM\u00A0100.00 – RM\u00A0250.00',
      );
      expect(formatBudget(minSen: 5000, hourly: true), 'RM\u00A050.00/hr');
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

  group('Penang location scoping', () {
    test('Region.label composes town/district/state and tolerates legacy '
        'data', () {
      const withTown = Region(
        districtCode: 'TL',
        districtName: 'Timur Laut',
        town: 'George Town',
      );
      expect(withTown.label, 'George Town, Timur Laut, Penang');

      const withoutTown = Region(
        districtCode: 'BD',
        districtName: 'Barat Daya',
      );
      expect(withoutTown.label, 'Barat Daya, Penang');

      expect(Region.fromMap(null), isNull);
      expect(
        Region.fromMap(const {'address': 'Some legacy free text'}),
        isNull,
      );

      final rebuilt = Region.fromMap(withTown.toMap());
      expect(rebuilt?.label, withTown.label);
    });

    test(
      'PenangDistricts classifies known points and rejects the sea',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        final districts = PenangDistricts.instance;
        await districts.ensureLoaded();

        expect(districts.districtCodeAt(kGeorgeTown), 'TL');
        expect(districts.districtCodeAt(const LatLng(5.2945, 100.2640)), 'BD');
        expect(districts.districtCodeAt(const LatLng(5.3991, 100.3638)), 'SPU');
        expect(districts.districtCodeAt(const LatLng(5.3630, 100.4667)), 'SPT');
        expect(districts.districtCodeAt(const LatLng(5.1656, 100.4790)), 'SPS');

        // A point out in the sea belongs to none of the 5 districts.
        expect(districts.districtCodeAt(const LatLng(5.30, 100.10)), isNull);
        expect(districts.isInPenang(const LatLng(5.30, 100.10)), isFalse);
      },
    );

    testWidgets('confirm is disabled when the centre is outside Penang', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: const RegionPickerScreen(initialCenter: LatLng(5.30, 100.10)),
        ),
      );
      // No pumpAndSettle: the map's tile layer fetches over the network and
      // would otherwise stall the "settle" wait indefinitely. A couple of
      // pumps is enough for PenangDistricts.ensureLoaded() (a local asset
      // read) to resolve.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Use this location'),
      );
      expect(button.onPressed, isNull);
      expect(find.text('Choose a spot within Penang.'), findsOneWidget);
    });

    testWidgets('picking a district updates the dropdown and unlocks confirm', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: const RegionPickerScreen(initialCenter: kGeorgeTown),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // George Town auto-classifies to Timur Laut by this point, so the
      // field already shows a value rather than the hint - target the
      // District dropdown by its label instead of assuming tree order.
      await tester.tap(_districtDropdown());
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Barat Daya').last);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Barat Daya'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Use this location'),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('provider onboarding Coverage Area drives the Penang picker', (
      tester,
    ) async {
      // The smallest host that exercises ServiceStep's real picker wiring:
      // an OnboardingController (backed by the fake repo) provided directly
      // to the widget, rather than driving the full multi-stage flow.
      final auth = FakeAuthRepository();
      final controller = OnboardingController(
        FakeOnboardingRepository(auth),
        FakeDocumentStorageRepository(),
      );
      await controller.loadFor('uid-1');

      // Tall surface: ServiceStep's card (category, coverage area, rate,
      // portfolio) is taller than the default test viewport, and the
      // picker's dropdown row needs the default width to avoid overflow.
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: ChangeNotifierProvider<OnboardingController>.value(
            value: controller,
            child: const Scaffold(
              body: SingleChildScrollView(child: ServiceStep()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.data.districtCode, isNull);
      expect(find.text('Pick your coverage area in Penang'), findsOneWidget);

      await pickPenangLocation(
        tester,
        placeholder: 'Pick your coverage area in Penang',
      );

      // The structured pick landed on the provider's OnboardingData, not
      // just a display string.
      expect(controller.data.districtCode, 'BD');
      expect(controller.data.town, isNull);
      expect(controller.data.lat, isNotNull);
      expect(controller.data.lng, isNotNull);
      expect(controller.data.coverageArea, 'Barat Daya, Penang');
      expect(find.text('Barat Daya, Penang'), findsOneWidget);
    });
  });

  group('Address autofill from the map pin', () {
    test('AddressHint maps a placemark into form-ready fields', () {
      final hint = AddressHint.fromPlacemark(const Placemark(
        subThoroughfare: '12',
        thoroughfare: 'Jalan Mawar 3',
        postalCode: '11900',
        locality: 'Bayan Lepas',
        subLocality: 'Batu Maung',
      ));

      expect(hint.line1, '12, Jalan Mawar 3');
      expect(hint.postcode, '11900');
      expect(hint.city, 'Bayan Lepas');
      expect(hint.isEmpty, isFalse);
    });

    test('AddressHint drops blanks and never repeats the house number', () {
      // The common Malaysian case: a street but no house number, and empty
      // strings where the geocoder had nothing.
      final noNumber = AddressHint.fromPlacemark(const Placemark(
        subThoroughfare: '',
        thoroughfare: 'Lebuh Chulia',
        postalCode: '',
      ));
      expect(noNumber.line1, 'Lebuh Chulia');
      expect(noNumber.postcode, isNull);
      expect(noNumber.city, isNull);

      // Android sometimes folds the number into `street`; don't double it up.
      final folded = AddressHint.fromPlacemark(const Placemark(
        subThoroughfare: '12',
        street: '12 Jalan Mawar 3',
      ));
      expect(folded.line1, '12 Jalan Mawar 3');

      expect(const AddressHint().isEmpty, isTrue);
    });

    test('matchTown only ever returns one of the fixed town options', () {
      final hint = AddressHint.fromPlacemark(const Placemark(
        subLocality: 'george town',
        locality: 'Somewhere Else',
      ));

      // Case-insensitive, but the returned value is the canonical spelling
      // from the caller's list - never the geocoder's own string.
      expect(hint.matchTown(kPenangTowns['TL']!), 'George Town');
      // A locality that isn't a known town yields nothing rather than
      // leaking raw geocoder output into the stored region.
      expect(
        AddressHint.fromPlacemark(const Placemark(locality: 'Kuala Lumpur'))
            .matchTown(kPenangTowns['TL']!),
        isNull,
      );
    });

    testWidgets('the address sheet pre-fills from the hint', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ServiceAddressSheet(
            defaultCity: 'Bayan Lepas',
            hint: AddressHint.fromPlacemark(const Placemark(
              subThoroughfare: '12',
              thoroughfare: 'Jalan Mawar 3',
              postalCode: '11900',
              locality: 'Somewhere Else',
            )),
          ),
        ),
      ));
      await tester.pump();

      // Read the controllers rather than the rendered text: a field's hint
      // ("11900") is a Text too, so find.text would double-count it.
      expect(
        _fieldValues(tester),
        containsAll(<String>['12, Jalan Mawar 3', '11900', 'Bayan Lepas']),
      );
      // The curated town from the picker beats the geocoder's city label.
      expect(_fieldValues(tester), isNot(contains('Somewhere Else')));
      expect(
        find.textContaining('Filled in from your map pin'),
        findsOneWidget,
      );
    });

    testWidgets('an existing address always beats the hint', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ServiceAddressSheet(
            initial: const ServiceAddress(
              line1: '9, Lorong Kenari',
              postcode: '11700',
              city: 'Gelugor',
            ),
            hint: AddressHint.fromPlacemark(const Placemark(
              subThoroughfare: '12',
              thoroughfare: 'Jalan Mawar 3',
              postalCode: '11900',
            )),
          ),
        ),
      ));
      await tester.pump();

      expect(
        _fieldValues(tester),
        containsAll(<String>['9, Lorong Kenari', '11700', 'Gelugor']),
      );
      expect(_fieldValues(tester), isNot(contains('12, Jalan Mawar 3')));
      // No "check this" notice when nothing was guessed.
      expect(find.textContaining('Filled in from your map pin'), findsNothing);
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
      // Keep the default 800 width - the region picker overflows narrower
      // than that - and add height for the four-section form.
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        buildApp(FakeAuthRepository(), jobs: [sampleJob()]),
      );
      await tester.pumpAndSettle();
      await login(tester);

      expect(find.text('Fix leaking sink'), findsWidgets);
    });

    testWidgets('provider home shows nearby jobs with a base location', (
      tester,
    ) async {
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
      expect(find.text('Job details'), findsOneWidget);
    }

    testWidgets('approved provider submits a bid (with form validation)', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..baseLat = 3.139
        ..baseLng = 101.6869;
      // Someone else's job, so the provider section (not bids) is shown.
      await tester.pumpWidget(
        buildApp(auth, jobs: [sampleJob(requestorId: 'req-9')]),
      );
      await tester.pumpAndSettle();
      await openJobAsProvider(tester);

      // Open the sheet and submit empty → validation errors. "Submit a bid"
      // is the pinned bottom bar's button; the bids slot doesn't repeat it.
      expect(find.widgetWithText(FilledButton, 'Submit a bid'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Submit a bid'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Submit bid'));
      await tester.pumpAndSettle();
      expect(find.text('Enter your bid amount.'), findsOneWidget);
      expect(find.text('Pick a duration.'), findsOneWidget);
      expect(find.text('Message is required.'), findsOneWidget);

      // Fill the form and submit.
      await fillField(tester, 'Your bid (RM)', '150');
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Less than 1 week').last);
      await tester.pumpAndSettle();
      await fillField(tester, 'Proposal message', 'I can start tomorrow.');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Submit bid'));
      await tester.pumpAndSettle();

      // Sheet closed; the detail now shows the live bid with Withdraw (the
      // bid card's own secondary action - the bottom bar doesn't offer it).
      expect(find.text('Your bid'), findsOneWidget);
      expect(find.text('RM\u00A0150.00'), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, 'Withdraw bid'),
        findsOneWidget,
      );

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
        buildApp(auth, jobs: [sampleJob(requestorId: 'req-9')]),
      );
      await tester.pumpAndSettle();
      await openJobAsProvider(tester);

      expect(find.text('Bidding locked'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Submit a bid'), findsNothing);
    });

    testWidgets('approved provider sees "Bidding closed" once the deadline has '
        'passed', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..baseLat = 3.139
        ..baseLng = 101.6869;
      final job = sampleJob(
        requestorId: 'req-9',
        deadline: DateTime.now().subtract(const Duration(hours: 1)),
      );
      await tester.pumpWidget(buildApp(auth, jobs: [job]));
      await tester.pumpAndSettle();
      await openJobAsProvider(tester);

      // "Bidding closed" also appears as the job's own deadline info row, so
      // assert on the locked-state banner's more specific body text.
      expect(find.text('Bidding for this job has closed.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Submit a bid'), findsNothing);
    });

    testWidgets('requestor sees a bid and accepting flips the job to '
        'in progress', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // Enough available balance to cover the RM 150 bid (see FakeBidRepository
      // .acceptBid's balance gate, mirroring the acceptBid Cloud Function).
      final auth = FakeAuthRepository()..walletBalanceSen = 20000;
      await tester.pumpWidget(
        buildApp(auth, jobs: [sampleJob()], bids: [sampleBid()]),
      );
      await tester.pumpAndSettle();
      await fillField(tester, 'Email', 'a@b.com');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();

      // Open own job → the bid list shows the provider's offer.
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();
      expect(find.text('Pro Fixer'), findsOneWidget);
      expect(find.text('RM\u00A0150.00'), findsOneWidget);

      // Accept → confirm in the dialog.
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Accept bid'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Accept bid'));
      await tester.pumpAndSettle();
      expect(find.text('Accept this bid?'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Accept bid'),
        ),
      );
      await tester.pumpAndSettle();

      // The job is now in progress with the winner shown.
      expect(find.text('In progress'), findsOneWidget);
      expect(find.text('Assigned provider'), findsOneWidget);
      expect(find.text('Pro Fixer'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // Licensing notice (docs/BUNDLE_BIDDING.md "Licensing"): shown on any job's
  // detail screen when its category needs one.
  // -------------------------------------------------------------------------
  group('Licence notice', () {
    Future<void> openOwnJob(WidgetTester tester, {required String category}) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final auth = FakeAuthRepository()..seedSignedIn(UserRole.requestor);
      await tester.pumpWidget(
          buildApp(auth, jobs: [sampleJob(title: 'A task', category: category)]));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
          of: find.byType(NavigationBar), matching: find.text('My jobs')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A task'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows on an Electrical job', (tester) async {
      await openOwnJob(tester, category: 'Electrical');
      expect(find.text('Licensing'), findsOneWidget);
      expect(find.textContaining('Energy Commission-registered contractor'),
          findsOneWidget);
    });

    testWidgets('does not show on a Cleaning job', (tester) async {
      await openOwnJob(tester, category: 'Cleaning');
      expect(find.text('Licensing'), findsNothing);
    });
  });

  group('Watchlist', () {
    testWidgets('bookmarking a job on the feed toggles its saved state', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()..verificationStatus = 'approved';
      await tester.pumpWidget(
        buildApp(auth, jobs: [sampleJob(requestorId: 'req-9')]),
      );
      await tester.pumpAndSettle();
      await openRegisterAs(tester, 'Work');

      // Into the full "Find Jobs" feed, where the bookmark toggle lives.
      await tester.tap(find.text('View all'));
      await tester.pumpAndSettle();

      // Scoped to the job list - the feed's AppBar has its own (separate)
      // bookmark_border icon that opens the Saved Jobs screen.
      final list = find.byType(ListView);
      Finder cardBookmark(IconData icon) =>
          find.descendant(of: list, matching: find.byIcon(icon));

      expect(cardBookmark(Icons.bookmark_border), findsOneWidget);
      await tester.tap(cardBookmark(Icons.bookmark_border));
      await tester.pumpAndSettle();

      expect(cardBookmark(Icons.bookmark), findsOneWidget);
      expect(auth.watchlist, contains('job-1'));

      // Tapping again unsaves it.
      await tester.tap(cardBookmark(Icons.bookmark));
      await tester.pumpAndSettle();
      expect(cardBookmark(Icons.bookmark_border), findsOneWidget);
      expect(auth.watchlist, isEmpty);
    });
  });

  group('Wallet balance gate on bid acceptance', () {
    test('AppUser.availableBalanceSen subtracts locked escrow', () {
      const user = AppUser(
        uid: 'uid-1',
        email: 'a@b.com',
        displayName: 'Test User',
        role: UserRole.requestor,
        walletBalanceSen: 50000,
        escrowLockedSen: 20000,
      );
      expect(user.availableBalanceSen, 30000);
    });

    testWidgets(
      'accepting a bid over the available balance shows a top-up dialog',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        // RM 100 available, but the sample bid is RM 150 - RM 50 short.
        final auth = FakeAuthRepository()..walletBalanceSen = 10000;
        await tester.pumpWidget(
          buildApp(auth, jobs: [sampleJob()], bids: [sampleBid()]),
        );
        await tester.pumpAndSettle();
        await fillField(tester, 'Email', 'a@b.com');
        await fillField(tester, 'Password', 'secret123');
        await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.widgetWithText(FilledButton, 'Accept bid'),
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Accept bid'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(FilledButton, 'Accept bid'),
          ),
        );
        await tester.pumpAndSettle();

        // The gate blocked the accept and surfaced the shortfall.
        expect(find.text('Not enough balance'), findsOneWidget);
        expect(find.textContaining('RM\u00A050.00 more available'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Top up'), findsOneWidget);
        expect(find.text('In progress'), findsNothing);

        // Top up routes to the wallet screen.
        await tester.tap(find.widgetWithText(FilledButton, 'Top up'));
        await tester.pumpAndSettle();
        expect(find.text('My wallet'), findsOneWidget);
      },
    );

    test('sequential overdraw guard: locking one bid blocks a second that no '
        'longer fits', () async {
      // RM 200 available - enough for either bid alone, not both.
      final auth = FakeAuthRepository()..walletBalanceSen = 20000;
      final jobRepo = FakeJobRepository([
        sampleJob(id: 'job-a', title: 'Job A'),
        sampleJob(id: 'job-b', title: 'Job B'),
      ]);
      final bidRepo = FakeBidRepository(jobRepo, auth);
      final bidA = sampleBid(
        jobId: 'job-a',
        providerId: 'p-a',
        amountSen: 15000,
      );
      final bidB = sampleBid(
        jobId: 'job-b',
        providerId: 'p-b',
        amountSen: 15000,
      );

      // Accepting job A locks its amount away.
      await bidRepo.acceptBid(bidA);
      expect(auth.escrowLockedSen, 15000);

      // Job B's RM 150 alone fits the raw RM 200 balance, but not the RM 50
      // left available once job A's commitment is locked.
      await expectLater(
        bidRepo.acceptBid(bidB),
        throwsA(
          isA<InsufficientBalanceException>()
              .having((e) => e.shortfallSen, 'shortfallSen', 10000)
              .having((e) => e.availableSen, 'availableSen', 5000)
              .having((e) => e.requiredSen, 'requiredSen', 15000),
        ),
      );
    });
  });

  group('Trust Score', () {
    test(
      'Bayesian review score starts at the prior and moves with reviews',
      () {
        // No reviews → the platform prior (3.5/5 → 700).
        expect(PlatformConfig.trustScoreFor(ratingSum: 0, ratingCount: 0), 700);
        // One 5★ on a fresh provider is smoothed toward the prior, not 1000.
        expect(PlatformConfig.trustScoreFor(ratingSum: 5, ratingCount: 1), 727);
        // A long run of 5★ approaches but never exceeds the cap.
        final many = PlatformConfig.trustScoreFor(
          ratingSum: 500,
          ratingCount: 100,
        );
        expect(many, greaterThan(900));
        expect(many, lessThanOrEqualTo(1000));
      },
    );

    // The shared vectors that also pin functions/index.js (`npm test`): if the
    // Dart and JS formulas ever drift, one of the two suites fails.
    final vectors =
        (jsonDecode(File('test/fixtures/trust_vectors.json').readAsStringSync())
                as Map<String, dynamic>)['vectors']
            as List;
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
        trustScore: 300,
      ),
      sampleBid(
        providerId: 'p-trust',
        providerName: 'Trusty Tina',
        amountSen: 12000,
        trustScore: 950,
      ),
    ];

    Future<void> openOwnJob(WidgetTester tester) async {
      await fillField(tester, 'Email', 'a@b.com');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();
    }

    testWidgets('defaults to composite order and badges the top bid', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        buildApp(FakeAuthRepository(), jobs: [sampleJob()], bids: valueBids()),
      );
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
        findsOneWidget,
      );
      expect(
        find.descendant(of: firstCard, matching: find.text('BEST VALUE')),
        findsOneWidget,
      );
    });

    testWidgets('the Compare button opens a side-by-side table of bids', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        buildApp(FakeAuthRepository(), jobs: [sampleJob(bidCount: 2)], bids: valueBids()),
      );
      await tester.pumpAndSettle();
      await openOwnJob(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Compare 2 bids'));
      await tester.pumpAndSettle();

      final table = find.byType(DataTable);
      expect(find.text('Compare 2 bids'), findsWidgets);
      expect(table, findsOneWidget);
      expect(find.descendant(of: table, matching: find.text('Cheap Charlie')),
          findsOneWidget);
      expect(find.descendant(of: table, matching: find.text('Trusty Tina')),
          findsOneWidget);

      // Picking a row starts that bid's accept.
      await tester.tap(
          find.descendant(of: table, matching: find.text('Cheap Charlie')));
      await tester.pumpAndSettle();
      expect(find.text('Accept this bid?'), findsOneWidget);
    });

    testWidgets('re-sorting by Price reorders but keeps the badge fixed', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        buildApp(FakeAuthRepository(), jobs: [sampleJob()], bids: valueBids()),
      );
      await tester.pumpAndSettle();
      await openOwnJob(tester);

      await tester.tap(find.text('Price'));
      await tester.pumpAndSettle();

      // Cheapest sorts first now, but the badge stays on the value winner.
      expect(
        find.descendant(
          of: find.byType(BidCard).first,
          matching: find.text('Cheap Charlie'),
        ),
        findsOneWidget,
      );
      expect(find.text('BEST VALUE'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(BidCard).last,
          matching: find.text('BEST VALUE'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a bid from a new provider shows a New badge, not a score', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        buildApp(
          FakeAuthRepository(),
          jobs: [sampleJob()],
          bids: [sampleBid(scoreVisible: false)],
        ),
      );
      await tester.pumpAndSettle();
      await openOwnJob(tester);

      expect(find.text('New provider, no score yet'), findsOneWidget);
      expect(find.textContaining('Trust Score'), findsNothing);
      // Still rankable / acceptable - the internal score just isn't surfaced.
      expect(find.widgetWithText(FilledButton, 'Accept bid'), findsOneWidget);
    });

    testWidgets("tapping a bid card's identity row opens the provider's public "
        'profile', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final publicProfile = FakePublicProfileRepository({
        'p-trust': const PublicProfile(
          uid: 'p-trust',
          displayName: 'Trusty Tina',
          role: UserRole.provider,
          bio: 'Reliable and fast.',
        ),
      });
      await tester.pumpWidget(
        buildApp(
          FakeAuthRepository(),
          jobs: [sampleJob()],
          bids: valueBids(),
          publicProfile: publicProfile,
        ),
      );
      await tester.pumpAndSettle();
      await openOwnJob(tester);

      await tester.tap(find.text('Trusty Tina'));
      await tester.pumpAndSettle();

      expect(find.byType(PublicProfileScreen), findsOneWidget);
      expect(find.text('Reliable and fast.'), findsOneWidget);
      // Private fields never render, even though nothing in this profile
      // sets them (the model has no field for them at all).
      expect(find.textContaining('@'), findsNothing);
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

    // A bundle task's extra "Part of a bundle" banner pushes the inline
    // review status card (slot 10) below the fold; scroll to it to check the
    // note it shows. The "Review X" button itself lives on the pinned bar.
    Future<void> scrollToReviewSection(WidgetTester tester) async {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'releasing the last milestone completes the job and the requestor '
      'reviews the provider',
      (tester) async {
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
        await tester.pumpWidget(
          buildApp(
            FakeAuthRepository(),
            jobs: [job],
            milestones: [milestone],
            review: review,
          ),
        );
        await tester.pumpAndSettle();
        await loginRequestor(tester);

        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();
        expect(find.text('Assigned provider'), findsOneWidget);
        expect(find.text('1. Full repair'), findsOneWidget);

        // Release the delivered milestone from the bottom bar (with
        // confirmation) - the last one, so the job completes.
        final releaseBtn = find.widgetWithText(
          FilledButton,
          'Release RM 150.00',
        );
        expect(find.widgetWithText(FilledButton, 'Release payment'),
            findsNothing);
        await tester.tap(releaseBtn);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(FilledButton, 'Release'),
          ),
        );
        await tester.pumpAndSettle();

        // Completed → review the provider with 5★ from the bottom bar.
        final reviewBtn = find.widgetWithText(FilledButton, 'Review Pro Fixer');
        expect(reviewBtn, findsOneWidget);
        await tester.tap(reviewBtn);
        await tester.pumpAndSettle();
        expect(find.text('Leave a Review'), findsOneWidget);
        await giveStarsAndSubmit(tester, 5);

        // The provider's aggregates and Bayesian review score were recomputed.
        expect(review.ratingCounts['prov-1'], 1);
        expect(review.reviewScores['prov-1'], 73); // (10·3.5+5)/11 /5 ·100
        await scrollToReviewSection(tester);
        expect(find.text('Review submitted'), findsOneWidget);
      },
    );

    testWidgets('accepted provider reviews the requestor on a completed job', (
      tester,
    ) async {
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
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('My jobs'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();

      // "Review Rita Client" is the bottom bar's button only.
      final reviewBtn = find.widgetWithText(FilledButton, 'Review Rita Client');
      expect(reviewBtn, findsOneWidget);
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
      await tester.pumpWidget(
        buildApp(FakeAuthRepository(), jobs: [job], review: review),
      );
      await tester.pumpAndSettle();
      await loginRequestor(tester);

      // Completed jobs are hidden from Active Jobs, so open it via My Jobs.
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('My jobs'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();

      // "Review Pro Fixer" is the bottom bar's button only.
      final reviewBtn = find.widgetWithText(FilledButton, 'Review Pro Fixer');
      expect(reviewBtn, findsOneWidget);
      await tester.tap(reviewBtn);
      await tester.pumpAndSettle();
      await giveStarsAndSubmit(tester, 5);

      expect(find.text('You have already reviewed this job.'), findsOneWidget);
    });

    testWidgets(
      'reviewing a completed live bundle task with no other tasks pending '
      'writes a bundle-keyed review id, unlike a plain job',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final review = FakeReviewRepository();
        final bundleTask = sampleJob(
          status: JobStatus.completed,
          acceptedProviderId: 'prov-1',
          acceptedProviderName: 'Pro Fixer',
          acceptedBidAmountSen: 15000,
          bundleId: 'bundle-1',
          bundleTaskCount: 1,
        );
        await tester.pumpWidget(
          buildApp(FakeAuthRepository(), jobs: [bundleTask], review: review),
        );
        await tester.pumpAndSettle();
        await loginRequestor(tester);

        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('My jobs'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();
        await scrollToReviewSection(tester);
        final reviewBtn = find
            .widgetWithText(FilledButton, 'Review Pro Fixer')
            .first;
        await tester.ensureVisible(reviewBtn);
        await tester.tap(reviewBtn);
        await tester.pumpAndSettle();
        await giveStarsAndSubmit(tester, 5);

        // Bundle-keyed, not job-keyed - the plain-job test above already
        // covers the job-keyed id via 'job-1_uid-1'.
        expect(review.left.single.jobId, 'job-1');
        expect(await review.hasReviewed(
          revieweeId: 'prov-1',
          jobId: 'job-1',
          reviewerId: 'uid-1',
          bundleId: 'bundle-1',
        ), isTrue);
        expect(await review.hasReviewed(
          revieweeId: 'prov-1',
          jobId: 'job-1',
          reviewerId: 'uid-1',
        ), isFalse);
      },
    );

    testWidgets(
      'reviewing a completed RELEASED bundle task still writes the '
      'bundle-keyed id - rules key on bundleId alone, not releasedAt',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final review = FakeReviewRepository();
        final releasedTask = sampleJob(
          status: JobStatus.completed,
          acceptedProviderId: 'prov-1',
          acceptedProviderName: 'Pro Fixer',
          acceptedBidAmountSen: 15000,
          bundleId: 'bundle-1',
          bundleTaskCount: 1,
          releasedAt: DateTime.now(),
        );
        await tester.pumpWidget(
          buildApp(FakeAuthRepository(), jobs: [releasedTask], review: review),
        );
        await tester.pumpAndSettle();
        await loginRequestor(tester);

        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('My jobs'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();
        await scrollToReviewSection(tester);
        final reviewBtn = find
            .widgetWithText(FilledButton, 'Review Pro Fixer')
            .first;
        await tester.ensureVisible(reviewBtn);
        await tester.tap(reviewBtn);
        await tester.pumpAndSettle();
        await giveStarsAndSubmit(tester, 5);

        expect(await review.hasReviewed(
          revieweeId: 'prov-1',
          jobId: 'job-1',
          reviewerId: 'uid-1',
          bundleId: 'bundle-1',
        ), isTrue);
      },
    );

    testWidgets(
      "a completed bundle task's review waits while the provider still has "
      'another task in progress, then opens once every task is done',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final review = FakeReviewRepository();
        final taskA = sampleJob(
          id: 'job-1',
          title: 'Fix leaking sink',
          status: JobStatus.completed,
          acceptedProviderId: 'prov-1',
          acceptedProviderName: 'Pro Fixer',
          acceptedBidAmountSen: 15000,
          bundleId: 'bundle-1',
          bundleOrder: 0,
          bundleTaskCount: 2,
        );
        final taskBInProgress = sampleJob(
          id: 'job-2',
          title: 'Retile the floor',
          status: JobStatus.inProgress,
          acceptedProviderId: 'prov-1',
          acceptedProviderName: 'Pro Fixer',
          acceptedBidAmountSen: 20000,
          bundleId: 'bundle-1',
          bundleOrder: 1,
          bundleTaskCount: 2,
        );
        final jobRepo = FakeJobRepository([taskA, taskBInProgress]);
        await tester.pumpWidget(
          buildApp(
            FakeAuthRepository(),
            jobRepository: jobRepo,
            review: review,
          ),
        );
        await tester.pumpAndSettle();
        await loginRequestor(tester);

        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('My jobs'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();
        await scrollToReviewSection(tester);

        expect(
          find.text(
            'You can review Pro Fixer once all their tasks in this bundle '
            'are done.',
          ),
          findsOneWidget,
        );
        // Only the pinned bottom bar's button exists - the inline slot shows
        // the wait banner.
        expect(
          find.widgetWithText(FilledButton, 'Review Pro Fixer'),
          findsOneWidget,
        );

        // The provider's other task finishes too - leave and reopen the job
        // so the inline card's one-shot gate check runs again.
        jobRepo.complete('job-2');
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();
        await scrollToReviewSection(tester);

        expect(
          find.text(
            'You can review Pro Fixer once all their tasks in this bundle '
            'are done.',
          ),
          findsNothing,
        );
        // The wait banner is gone and the bar's button is what's left.
        expect(
          find.widgetWithText(FilledButton, 'Review Pro Fixer'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'reviewing one bundle task counts for the rest of the same provider\'s '
      'tasks in the bundle',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final review = FakeReviewRepository();
        final taskA = sampleJob(
          id: 'job-1',
          title: 'Fix leaking sink',
          status: JobStatus.completed,
          acceptedProviderId: 'prov-1',
          acceptedProviderName: 'Pro Fixer',
          acceptedBidAmountSen: 15000,
          bundleId: 'bundle-1',
          bundleOrder: 0,
          bundleTaskCount: 2,
        );
        final taskB = sampleJob(
          id: 'job-2',
          title: 'Retile the floor',
          status: JobStatus.completed,
          acceptedProviderId: 'prov-1',
          acceptedProviderName: 'Pro Fixer',
          acceptedBidAmountSen: 20000,
          bundleId: 'bundle-1',
          bundleOrder: 1,
          bundleTaskCount: 2,
        );
        await tester.pumpWidget(
          buildApp(
            FakeAuthRepository(),
            jobs: [taskA, taskB],
            review: review,
          ),
        );
        await tester.pumpAndSettle();
        await loginRequestor(tester);

        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('My jobs'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();
        await scrollToReviewSection(tester);
        final reviewBtn = find
            .widgetWithText(FilledButton, 'Review Pro Fixer')
            .first;
        await tester.ensureVisible(reviewBtn);
        await tester.tap(reviewBtn);
        await tester.pumpAndSettle();
        await giveStarsAndSubmit(tester, 5);
        await scrollToReviewSection(tester);
        expect(find.text('Review submitted'), findsOneWidget);

        // Leave and check task B - same provider, same bundle, already
        // reviewed via task A.
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Retile the floor').first);
        await tester.pumpAndSettle();
        await scrollToReviewSection(tester);

        expect(find.text('Review submitted'), findsOneWidget);
        // Only the pinned bottom bar's button exists - the inline slot shows
        // the already-reviewed state.
        expect(
          find.widgetWithText(FilledButton, 'Review Pro Fixer'),
          findsOneWidget,
        );
      },
    );
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

    testWidgets('unread badge shows, opening the thread clears it, and a reply '
        'sends', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final chat = FakeChatRepository([sampleConversation()]);
      // An incoming message from the provider → 1 unread for the requestor.
      await chat.sendMessage(
        conversation: sampleConversation(),
        senderId: 'prov-1',
        text: 'Hello! I can come by tomorrow.',
      );

      await tester.pumpWidget(buildApp(FakeAuthRepository(), chat: chat));
      await tester.pumpAndSettle();
      await login(tester);

      // The Messages tab shows the unread badge.
      expect(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );

      // The conversation list shows the counterparty, job and preview.
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Messages'),
        ),
      );
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
          of: find.byType(NavigationBar),
          matching: find.text('1'),
        ),
        findsNothing,
      );

      // Send a reply.
      await tester.enterText(find.byType(TextField), 'Great, see you then!');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Great, see you then!'), findsOneWidget);
    });

    testWidgets('requestor opens the chat from the bottom bar', (
      tester,
    ) async {
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
        buildApp(FakeAuthRepository(), jobs: [job], chat: chat),
      );
      await tester.pumpAndSettle();
      await login(tester);

      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();
      expect(find.text('Assigned provider'), findsOneWidget);

      // The bar's message button (the only one - the inline tile would
      // repeat it) lazily creates the conversation and opens it.
      expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Message provider'));
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
    }) => PendingVerification(
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

    testWidgets('admin lands on the queue and sees pending applicants', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      await tester.pumpWidget(
        buildApp(
          auth,
          verification: FakeVerificationRepository([samplePending()]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Verification Queue'), findsOneWidget);
      expect(find.text('Alex Rivera'), findsOneWidget);
      // The "Pending Review" stat reflects the queue length.
      expect(find.text('1'), findsOneWidget);
    });

    Future<void> openDetail(
      WidgetTester tester,
      FakeVerificationRepository repo, {
      Size size = const Size(500, 2400),
    }) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      await tester.pumpWidget(buildApp(auth, verification: repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alex Rivera'));
      await tester.pumpAndSettle();
    }

    testWidgets('detail says when no automated ID check has run', (
      tester,
    ) async {
      await openDetail(tester, FakeVerificationRepository([samplePending()]));
      expect(find.text('Automated ID checks'), findsOneWidget);
      expect(find.text('No automated check yet'), findsOneWidget);
    });

    testWidgets('detail shows the automated ID check result', (tester) async {
      await openDetail(tester, FakeVerificationRepository([samplePending()])
        ..idExtract = const IdExtract(
          verdict: IdVerdict.needsReview,
          failures: ['name-mismatch'],
          maskedIc: '******-07-**34',
          ageOk: true,
          nameMatches: false,
        ));
      expect(find.textContaining('Needs review', findRichText: true),
          findsOneWidget);
      expect(find.text('******-07-**34'), findsOneWidget);
      expect(find.text('18 or older'), findsOneWidget);
      expect(find.text('Does not match'), findsOneWidget);
      expect(find.textContaining(idFailureLabel('name-mismatch')),
          findsOneWidget);
    });

    testWidgets('detail shows the face comparison when ID and selfie exist', (
      tester,
    ) async {
      await openDetail(tester, FakeVerificationRepository([samplePending()])
        ..identityDocuments = const [
          VerificationDocument(
            label: 'Identity Document',
            url: 'https://fake.storage/id.jpg',
            faceBox: FaceBox(
                left: 0.1, top: 0.1, width: 0.3, height: 0.4, aspect: 1.5),
          ),
          VerificationDocument(
              label: 'Selfie', url: 'https://fake.storage/selfie.jpg'),
        ]);
      expect(find.text('Face comparison'), findsOneWidget);
      expect(find.text('Compare the two faces before approving.'),
          findsOneWidget);
      expect(find.text('On ID'), findsOneWidget);
      expect(find.byType(FaceCrop), findsNWidgets(2));
    });

    testWidgets('the face comparison fits a 360dp phone without overflow', (
      tester,
    ) async {
      await openDetail(
        tester,
        FakeVerificationRepository([samplePending()])
          ..identityDocuments = const [
            VerificationDocument(
              label: 'Identity Document',
              url: 'https://fake.storage/id.jpg',
              faceBox: FaceBox(
                  left: 0.1, top: 0.1, width: 0.3, height: 0.4, aspect: 1.5),
            ),
            VerificationDocument(
                label: 'Selfie', url: 'https://fake.storage/selfie.jpg'),
          ],
        size: const Size(360, 800),
      );
      expect(find.text('Face comparison'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final crops = tester.widgetList(find.byType(FaceCrop)).cast<FaceCrop>();
      expect(crops.map((c) => c.size).toSet().single, lessThan(140));
    });

    testWidgets('detail hides the face comparison without a selfie', (
      tester,
    ) async {
      await openDetail(tester, FakeVerificationRepository([samplePending()]));
      expect(find.text('Face comparison'), findsNothing);
      expect(find.byType(FaceCrop), findsNothing);
    });

    testWidgets('empty queue shows the all-caught-up state', (tester) async {
      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();

      expect(find.text('All caught up'), findsOneWidget);
    });

    testWidgets('approving an applicant records the decision and clears it', (
      tester,
    ) async {
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
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Approve'),
        ),
      );
      await tester.pumpAndSettle();

      // Decision recorded; back on the queue, now empty.
      expect(verification.decisions['prov-9'], isTrue);
      expect(find.text('All caught up'), findsOneWidget);
    });

    testWidgets('admin profile shows admin info, not marketplace fields', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      await tester.pumpWidget(
        buildApp(
          auth,
          verification: FakeVerificationRepository([samplePending()]),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Profile'),
        ),
      );
      await tester.pumpAndSettle();

      // Admin-appropriate content.
      expect(find.text('Administrator'), findsOneWidget);
      expect(find.text('Administrator Access'), findsOneWidget);
      // StatCard uppercases its label.
      expect(find.text('PENDING VERIFICATIONS'), findsOneWidget);
      // Marketplace-participant content is hidden for admins.
      expect(find.text('Trust Score'), findsNothing);
      expect(find.text('Earnings & payouts'), findsNothing);
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
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Reject'),
        ),
      );
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

    test('provider toMap excludes payout bank details (they go private)', () {
      final data = OnboardingData()
        ..bankName = 'Maybank'
        ..accountHolder = 'Jane Doe'
        ..accountNumber = '1234567890'
        ..branchCode = 'BR1';
      final map = data.toMap();
      expect(map.containsKey('bankName'), isFalse);
      expect(map.containsKey('accountHolder'), isFalse);
      expect(map.containsKey('accountLast4'), isFalse);
      expect(map.containsKey('branchCode'), isFalse);
      expect(data.payoutMap()['bankName'], 'Maybank');
      expect(data.payoutMap()['accountHolder'], 'Jane Doe');
      expect(data.payoutMap()['accountLast4'], '7890');
      expect(data.payoutMap()['branchCode'], 'BR1');
    });

    test('requestor toMap excludes the ID/SSM document URL', () {
      final data = RequestorOnboardingData()
        ..clientDocumentUrl = 'https://x/doc.jpg';
      expect(data.toMap().containsKey('clientDocumentUrl'), isFalse);
      expect(data.privateMap()['clientDocumentUrl'], 'https://x/doc.jpg');
    });

    test('requestor toMap excludes the phone number (it goes private)', () {
      final data = RequestorOnboardingData()..phone = '012-345 6789';
      expect(data.toMap().containsKey('phone'), isFalse);
      expect(data.payoutMap()['phone'], '012-345 6789');
    });

    test('PendingVerification merges phone/bank details from the private '
        'payout doc, preferring it over legacy public-doc locations', () {
      final v = PendingVerification.fromMap(
        'prov-1',
        {
          'role': 'provider',
          'displayName': 'Alex Rivera',
          // Legacy public locations, still present on a doc that hasn't
          // fully migrated yet - the payout doc below must win.
          'phone': '011-000 0000',
          'onboarding': {
            'bankName': 'Legacy Bank',
            'accountHolder': 'Legacy Name',
            'accountLast4': '0000',
            'branchCode': 'OLD',
          },
        },
        payoutData: {
          'phone': '012-345 6789',
          'bankName': 'Maybank',
          'accountHolder': 'Alex Rivera',
          'accountLast4': '6789',
          'branchCode': 'BR1',
        },
      );
      expect(v?.phone, '012-345 6789');
      expect(v?.bankName, 'Maybank');
      expect(v?.accountHolder, 'Alex Rivera');
      expect(v?.accountLast4, '6789');
      expect(v?.branchCode, 'BR1');
    });

    test('PendingVerification falls back to the legacy public-doc fields '
        'when the private payout doc is missing (pre-migration applicant)', () {
      final requestor = PendingVerification.fromMap('req-1', {
        'role': 'requestor',
        'displayName': 'Jamie Lee',
        'phone': '019-888 7777',
      });
      expect(requestor?.phone, '019-888 7777');

      final provider = PendingVerification.fromMap('prov-2', {
        'role': 'provider',
        'displayName': 'Old Provider',
        'onboarding': {
          'bankName': 'CIMB',
          'accountHolder': 'Old Provider',
          'accountLast4': '1234',
          'branchCode': 'OLD1',
        },
      });
      expect(provider?.bankName, 'CIMB');
      expect(provider?.accountHolder, 'Old Provider');
      expect(provider?.accountLast4, '1234');
      expect(provider?.branchCode, 'OLD1');
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
      expect(
        LedgerType.fromStorage('dispute_release'),
        LedgerType.disputeRelease,
      );
      expect(
        LedgerType.fromStorage('dispute_refund'),
        LedgerType.disputeRefund,
      );
    });

    test('escrow refund ledger type parses from storage', () {
      expect(LedgerType.fromStorage('refund'), LedgerType.refund);
      expect(LedgerType.refund.label, 'Escrow refund');
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

    testWidgets('requestor raises a dispute on a funded milestone', (
      tester,
    ) async {
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
      await tester.pumpWidget(
        buildApp(
          FakeAuthRepository(),
          jobs: [job],
          milestones: [milestone],
          dispute: dispute,
        ),
      );
      await tester.pumpAndSettle();
      await fillField(tester, 'Email', 'a@b.com');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();

      // Open own job → the funded (current) milestone step offers the
      // "Raise a dispute" button.
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();
      final disputeBtn = find.widgetWithText(OutlinedButton, 'Raise a dispute');
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
        tester,
        'What went wrong?',
        'The pipe still leaks after repair.',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Submit Dispute'));
      await tester.pumpAndSettle();

      expect(dispute.raised, hasLength(1));
      expect(dispute.raised.single.milestoneId, 'ms-1');
      expect(find.text('Disputed, on hold'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Raise a dispute'), findsNothing);

      // The person who raised it can take it back.
      final withdrawBtn = find.text('Withdraw dispute');
      await tester.ensureVisible(withdrawBtn);
      await tester.tap(withdrawBtn);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Withdraw'));
      await tester.pumpAndSettle();

      expect(dispute.withdrawn, ['ms-1']);
      expect(find.text('Disputed, on hold'), findsNothing);
      expect(find.text('Withdraw dispute'), findsNothing);
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
      expect(
        find.text('The pipe still leaks after the repair.'),
        findsOneWidget,
      );

      // Release → the ruling note is required before confirming.
      await tester.tap(find.text('Pay the provider RM 150.00'));
      await tester.pumpAndSettle();
      final confirm = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Pay provider'),
      );
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.enterText(
        find.byType(TextField).last,
        'Work matches the milestone scope.',
      );
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

      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Profile'),
        ),
      );
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
        find.byType(TextField).last,
        'This reviewer was never my client.',
      );
      await tester.pumpAndSettle();
      await tester.tap(report);
      await tester.pumpAndSettle();

      expect(review.flags, hasLength(1));
      expect(review.flags.single.$2, 'r1');
      expect(review.flags.single.$3, 'This reviewer was never my client.');
    });

    testWidgets('admin hides a flagged review from the Reviews tab', (
      tester,
    ) async {
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

    testWidgets('stats tab shows the aggregated platform numbers', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();

      // The scrollable TabBar puts 'Stats' past the right edge in the wide
      // Ahem test font - bring it on-screen first.
      await tester.ensureVisible(find.text('Stats'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stats'));
      await tester.pumpAndSettle();

      expect(find.text('Platform statistics'), findsOneWidget);
      expect(find.text('RM\u00A012,345.00'), findsOneWidget); // released volume
      expect(find.text('11'), findsOneWidget); // clients
      expect(find.text('12'), findsOneWidget); // providers
      expect(find.text('17'), findsOneWidget); // open disputes
      expect(find.text('23'), findsOneWidget); // total users
    });

    testWidgets('stats tab shows bundle award counts', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Stats'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stats'));
      await tester.pumpAndSettle();

      expect(find.text('Bundles'), findsOneWidget);
      expect(find.text('20'), findsOneWidget); // bundles awarded
      expect(find.text('5 (25%)'), findsOneWidget); // split awards
    });

    testWidgets('stats tab can trigger the Trust Score recompute', (
      tester,
    ) async {
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

      final btn = find.widgetWithText(OutlinedButton, 'Recompute Trust Scores');
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
      FakeJobRepository jobs,
    ) {
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

    test(
      'refunding ends the job instead of reopening the milestone',
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
        expect(m.status, MilestoneStatus.refunded); // can't be funded again
        final job = await jobs.getById('job-1');
        expect(job!.status, JobStatus.cancelled);
      },
    );

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

    test(
      'a proposed plan is not fundable until the client approves it',
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
      },
    );
  });

  group('Job detail view model', () {
    // Pure-function tests (no widget pumping) over the role × status matrix
    // that drives the job detail screen's fixed slot order and its bottom
    // bar's single CTA.
    AppUser testUser({
      String uid = 'me',
      UserRole role = UserRole.requestor,
      String verificationStatus = 'none',
    }) => AppUser(
      uid: uid,
      email: '$uid@fairbid.app',
      displayName: uid,
      role: role,
      verificationStatus: verificationStatus,
    );

    test('owner + open with bids: primary action compares them', () {
      final job = sampleJob(requestorId: 'me', bidCount: 3);
      final vm = buildJobDetailVm(job, testUser(), null);

      expect(vm.role, JobViewerRole.owner);
      expect(vm.primaryAction?.kind, JobActionKind.compareBids);
      expect(vm.primaryAction?.label, 'Compare 3 bids');
      expect(vm.showBids, isTrue);
      expect(vm.showMilestones, isFalse);
      expect(vm.showCancel, isTrue);
    });

    test('owner + open with no bids: no action, a waiting line instead', () {
      final job = sampleJob(requestorId: 'me');
      final vm = buildJobDetailVm(job, testUser(), null);

      expect(vm.primaryAction, isNull);
      expect(vm.waitingLine, isNotNull);
    });

    test('owner + in progress: message the provider, milestones and address '
        'show', () {
      final job = sampleJob(
        requestorId: 'me',
        status: JobStatus.inProgress,
        acceptedProviderId: 'prov-1',
        acceptedProviderName: 'Pro Fixer',
        acceptedBidAmountSen: 15000,
      );
      final vm = buildJobDetailVm(job, testUser(), null);

      expect(vm.role, JobViewerRole.owner);
      expect(vm.primaryAction?.kind, JobActionKind.message);
      expect(vm.primaryAction?.label, 'Message provider');
      expect(vm.showMilestones, isTrue);
      expect(vm.showAddress, isTrue);
      expect(vm.showCancel, isTrue);
      expect(vm.showCancellationResponse, isFalse);
    });

    test('owner + in progress with a pending cancellation: the response card '
        'shows', () {
      final job = Job(
        id: 'job-1',
        requestorId: 'me',
        requestorName: 'Test User',
        title: 'Fix leaking sink',
        description: 'Kitchen sink is leaking under the cabinet.',
        category: 'Plumbing',
        location: const JobLocation(
          lat: 3.14,
          lng: 101.7,
          address: 'Bangsar, KL',
        ),
        status: JobStatus.inProgress,
        acceptedProviderId: 'prov-1',
        acceptedProviderName: 'Pro Fixer',
        acceptedBidAmountSen: 15000,
        cancellationRequestedBy: 'provider',
      );
      final vm = buildJobDetailVm(job, testUser(), null);

      expect(vm.showCancellationResponse, isTrue);
      expect(vm.statusHeadline, contains('cancellation'));
    });

    test('owner + completed: leave-a-review is the primary action', () {
      final job = sampleJob(
        requestorId: 'me',
        status: JobStatus.completed,
        acceptedProviderId: 'prov-1',
        acceptedProviderName: 'Pro Fixer',
        acceptedBidAmountSen: 15000,
      );
      final vm = buildJobDetailVm(job, testUser(), null);

      expect(vm.primaryAction?.kind, JobActionKind.leaveReview);
      expect(vm.primaryAction?.label, 'Review Pro Fixer');
      expect(vm.showReviewPrompt, isTrue);
      expect(vm.showCancel, isFalse);
    });

    test('owner + cancelled: no primary action', () {
      final job = sampleJob(requestorId: 'me', status: JobStatus.cancelled);
      final vm = buildJobDetailVm(job, testUser(), null);

      expect(vm.primaryAction, isNull);
      expect(vm.showMilestones, isFalse);
      expect(vm.showCancel, isFalse);
    });

    test('accepted provider + in progress: message the client', () {
      final job = sampleJob(
        status: JobStatus.inProgress,
        acceptedProviderId: 'me',
        acceptedProviderName: 'Pro Fixer',
        acceptedBidAmountSen: 15000,
      );
      final vm = buildJobDetailVm(job, testUser(role: UserRole.provider), null);

      expect(vm.role, JobViewerRole.acceptedProvider);
      expect(vm.primaryAction?.kind, JobActionKind.message);
      expect(vm.primaryAction?.label, 'Message client');
      expect(vm.showMilestones, isTrue);
      expect(vm.showAddress, isTrue);
    });

    test(
      'accepted provider + completed: leave-a-review is the primary action',
      () {
        final job = sampleJob(
          status: JobStatus.completed,
          acceptedProviderId: 'me',
          acceptedProviderName: 'Pro Fixer',
          acceptedBidAmountSen: 15000,
        );
        final vm = buildJobDetailVm(
          job,
          testUser(role: UserRole.provider),
          null,
        );

        expect(vm.primaryAction?.kind, JobActionKind.leaveReview);
        expect(vm.showReviewPrompt, isTrue);
      },
    );

    test('bidder: shows the placed bid', () {
      final job = sampleJob(requestorId: 'req-9');
      final bid = sampleBid(providerId: 'me', amountSen: 15000);
      final vm = buildJobDetailVm(job, testUser(role: UserRole.provider), bid);

      expect(vm.role, JobViewerRole.bidder);
      expect(vm.primaryAction?.kind, JobActionKind.editBid);
      expect(vm.primaryAction?.label, 'Edit bid');
      expect(vm.showBids, isTrue);
    });

    test('browser: a verified provider can submit a bid', () {
      final job = sampleJob(requestorId: 'req-9');
      final vm = buildJobDetailVm(
        job,
        testUser(role: UserRole.provider, verificationStatus: 'approved'),
        null,
      );

      expect(vm.role, JobViewerRole.browser);
      expect(vm.primaryAction?.kind, JobActionKind.submitBid);
    });

    test('browser: an unverified provider is routed to get verified', () {
      final job = sampleJob(requestorId: 'req-9');
      final vm = buildJobDetailVm(job, testUser(role: UserRole.provider), null);

      expect(vm.primaryAction?.kind, JobActionKind.getVerified);
    });

    test('browser: bidding is closed once the deadline has passed', () {
      final job = sampleJob(
        requestorId: 'req-9',
        deadline: DateTime.now().subtract(const Duration(hours: 1)),
      );
      final vm = buildJobDetailVm(
        job,
        testUser(role: UserRole.provider, verificationStatus: 'approved'),
        null,
      );

      expect(vm.primaryAction, isNull);
    });

    test('browser: a non-provider viewer gets no bidding action', () {
      final job = sampleJob(requestorId: 'req-9');
      final vm = buildJobDetailVm(job, testUser(), null);

      expect(vm.role, JobViewerRole.browser);
      expect(vm.primaryAction, isNull);
    });

    test('outsider: no relation to a job that has moved on', () {
      final job = sampleJob(
        requestorId: 'req-9',
        status: JobStatus.inProgress,
        acceptedProviderId: 'prov-1',
        acceptedProviderName: 'Pro Fixer',
      );
      final vm = buildJobDetailVm(job, testUser(role: UserRole.provider), null);

      expect(vm.role, JobViewerRole.outsider);
      expect(vm.primaryAction, isNull);
      expect(vm.showBids, isFalse);
    });

    test('outsider: a cancelled job says so plainly', () {
      final job = sampleJob(requestorId: 'req-9', status: JobStatus.cancelled);
      final vm = buildJobDetailVm(job, testUser(role: UserRole.provider), null);

      expect(vm.statusHeadline, 'This job was cancelled.');
    });

    test('not signed in: browsing an open job with no bidding action', () {
      final job = sampleJob(requestorId: 'req-9');
      final vm = buildJobDetailVm(job, null, null);

      expect(vm.role, JobViewerRole.browser);
      expect(vm.primaryAction, isNull);
    });

    test('owner + open live bundle task: headline counts bundle bids, '
        'action opens the bundle', () {
      final job = sampleJob(
        requestorId: 'me',
        bundleId: 'b1',
        bundleOrder: 0,
        bundleTaskCount: 2,
        bidCount: 2,
      );
      final vm = buildJobDetailVm(job, testUser(), null);

      expect(vm.role, JobViewerRole.owner);
      expect(vm.statusHeadline, '2 bundle bids cover this task.');
      expect(vm.primaryAction?.kind, JobActionKind.viewBundle);
      expect(vm.primaryAction?.label, 'View bundle');
      // The per-job bid list is always empty for a live bundle task - the
      // bundle screen is where its bids actually live.
      expect(vm.showBids, isFalse);
    });

    test('owner + open live bundle task with no bids yet', () {
      final job = sampleJob(
        requestorId: 'me',
        bundleId: 'b1',
        bundleOrder: 0,
        bundleTaskCount: 2,
      );
      final vm = buildJobDetailVm(job, testUser(), null);

      expect(vm.statusHeadline, 'Waiting for providers to bid on this bundle.');
    });

    test('owner + open RELEASED bundle task: reads exactly like an ordinary '
        'job', () {
      final job = sampleJob(
        requestorId: 'me',
        bundleId: 'b1',
        bundleOrder: 0,
        bundleTaskCount: 2,
        bidCount: 1,
        releasedAt: DateTime.now(),
      );
      final vm = buildJobDetailVm(job, testUser(), null);

      expect(vm.primaryAction?.kind, JobActionKind.compareBids);
      expect(vm.primaryAction?.label, 'View 1 bid');
      expect(vm.showBids, isTrue);
    });

    test(
      'browser + live bundle task with a pending covering bundle bid: '
      'edits it instead of being treated as a new bidder',
      () {
        final job = sampleJob(
          requestorId: 'req-9',
          bundleId: 'b1',
          bundleOrder: 0,
          bundleTaskCount: 2,
        );
        final myBundleBid = BundleBid(
          bundleId: 'b1',
          providerId: 'me',
          providerName: 'Pro Fixer',
          taskPrices: const {'job-1': 15000, 'job-2': 20000},
          estimatedDuration: '1 week',
        );
        final vm = buildJobDetailVm(
          job,
          testUser(role: UserRole.provider, verificationStatus: 'approved'),
          null,
          myBundleBid: myBundleBid,
        );

        expect(vm.role, JobViewerRole.browser);
        expect(
          vm.statusHeadline,
          'You bid RM\u00A0150.00 on this task as part of a bundle bid.',
        );
        expect(vm.primaryAction?.kind, JobActionKind.submitBid);
        expect(vm.primaryAction?.label, 'Edit bundle bid');
      },
    );

    test(
      "browser + live bundle task: a bundle bid that doesn't cover this "
      'task is still edited, not re-bid',
      () {
        final job = sampleJob(
          requestorId: 'req-9',
          bundleId: 'b1',
          bundleOrder: 0,
          bundleTaskCount: 2,
        );
        final myBundleBid = BundleBid(
          bundleId: 'b1',
          providerId: 'me',
          providerName: 'Pro Fixer',
          taskPrices: const {'job-2': 20000},
          estimatedDuration: '1 week',
        );
        final vm = buildJobDetailVm(
          job,
          testUser(role: UserRole.provider, verificationStatus: 'approved'),
          null,
          myBundleBid: myBundleBid,
        );

        expect(vm.primaryAction?.kind, JobActionKind.submitBid);
        expect(vm.primaryAction?.label, 'Edit bundle bid');
        expect(
          vm.statusHeadline,
          "Your bundle bid doesn't include this task yet. "
          'Edit it to add this task.',
        );
      },
    );
  });

  group('Admin user suspension', () {
    testWidgets('admin suspends a user from the Users tab', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      final users = FakeUserAdminRepository([
        const ManagedUser(
          uid: 'u-2',
          displayName: 'Bob Provider',
          email: 'bob@fairbid.app',
          role: 'provider',
          suspended: false,
        ),
      ]);
      await tester.pumpWidget(buildApp(auth, userAdmin: users));
      await tester.pumpAndSettle();

      // The Users tab is the last, scrollable-off-screen one in the wide test
      // font - bring it on-screen first (same as the Stats tab test).
      await tester.ensureVisible(find.text('Users'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Users'));
      await tester.pumpAndSettle();

      expect(find.text('Bob Provider'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Suspend'));
      await tester.pumpAndSettle();

      // Confirm sheet: enter a reason and confirm.
      await tester.enterText(
        find.widgetWithText(TextField, 'Reason (optional)'),
        'Spam bids',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Suspend'));
      await tester.pumpAndSettle();

      expect(users.calls, hasLength(1));
      expect(users.calls.first.uid, 'u-2');
      expect(users.calls.first.suspended, isTrue);
      expect(users.calls.first.reason, 'Spam bids');
      // The list re-renders: the user now shows the Suspended pill and the
      // action flips to Reinstate.
      expect(find.text('Suspended'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Reinstate'), findsOneWidget);
    });

    testWidgets('admin resets a lost authenticator from the Users tab', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      final users = FakeUserAdminRepository([
        const ManagedUser(
          uid: 'u-2',
          displayName: 'Bob Provider',
          email: 'bob@fairbid.app',
          role: 'provider',
          suspended: false,
        ),
      ]);
      await tester.pumpWidget(buildApp(auth, userAdmin: users));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Users'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Users'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset two-factor'));
      await tester.pumpAndSettle();

      expect(find.text('Reset two-factor for Bob Provider?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
      await tester.pumpAndSettle();

      expect(users.mfaClears, ['u-2']);
      expect(find.text('Two-factor authentication reset.'), findsOneWidget);
    });

    testWidgets('a suspended user is locked to the suspended screen', (
      tester,
    ) async {
      final auth = FakeAuthRepository()
        ..suspended = true
        ..suspensionReason = 'Repeated policy violations'
        ..seedSignedIn(UserRole.requestor);
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();

      expect(find.text('Account suspended'), findsOneWidget);
      expect(find.textContaining('Repeated policy violations'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Sign Out'), findsOneWidget);
    });
  });

  postJobAndOnboardingTests();
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

// ---------------------------------------------------------------------------
// Post a job, and leaving onboarding.
//
// Both funnels were previously unguarded: nothing exercised the post-a-job
// form at all, and nothing pinned the onboarding back-arrow behaviour, which
// used to sign the user out without asking.
// ---------------------------------------------------------------------------

/// Registered from [main]. Kept as a function rather than inlined so this
/// file's newest groups are easy to find in a 4,000-line suite.
void postJobAndOnboardingTests() {
  group('Post a job', () {
    /// Signs in a requestor and opens the post-a-job form.
    Future<void> openPostJob(WidgetTester tester) async {
      // The form is four sections tall; on the default test viewport the
      // lower fields' centres stay off-screen even after ensureVisible, so
      // taps land on nothing. Same trick the bidding tests use.
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // Seed a default location, the way onboarding leaves a real requestor.
      // The form then pre-fills "Where" (see _locationDefaulted), which is
      // both the common path and keeps the map picker out of this test - the
      // picker is already exercised by the onboarding tests.
      final auth = FakeAuthRepository()
        ..defaultLat = 5.4164
        ..defaultLng = 100.3327
        ..defaultDistrictCode = 'TL'
        ..defaultTown = 'George Town'
        ..seedSignedIn(UserRole.requestor);
      await tester.pumpWidget(buildApp(auth));
      await tester.pumpAndSettle();
      await tester.tap(find.text('+ Post a job'));
      await tester.pumpAndSettle();
      expect(find.text('Post a job'), findsOneWidget);
    }

    testWidgets('an empty form reports every required field', (tester) async {
      await openPostJob(tester);

      final submit = find.widgetWithText(FilledButton, 'Post job');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();

      // All three sit in the first section, above the submit button.
      expect(find.text('Pick a category.'), findsOneWidget);
      expect(find.text('Title is required.'), findsOneWidget);
      expect(find.text('Description is required.'), findsOneWidget);
      // Nothing was posted, so the form is still up.
      expect(find.text('Post a job'), findsOneWidget);
    });

    testWidgets('a complete form posts the job', (tester) async {
      await openPostJob(tester);

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plumbing').last);
      await tester.pumpAndSettle();

      await fillField(tester, 'Job title', 'Fix the kitchen tap');
      await fillField(tester, 'Description', 'It drips constantly.');

      // "Where" is already satisfied by the seeded default location.

      final submit = find.widgetWithText(FilledButton, 'Post job');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();

      // No photo or video, so it asks first instead of posting.
      expect(find.text('Post without photos?'), findsOneWidget);
      expect(find.text('Job posted!'), findsNothing);
      await tester.tap(find.text('Post anyway'));
      await tester.pumpAndSettle();

      expect(find.text('Job posted!'), findsOneWidget);
    });
  });

  group('Saved Jobs covers the whole watchlist', () {
    // Firestore's whereIn caps at 30 values. Saved Jobs used to `take(30)`,
    // so a user who bookmarked a 31st job never saw it again - silently, with
    // nothing in the UI to explain the gap. These pin the chunking that
    // replaced it. (The repository itself needs a live Firestore and so
    // cannot be unit-tested; this covers the arithmetic that carried the bug.)
    test('a 35-id watchlist is split into chunks that lose nothing', () {
      final ids = [for (var i = 0; i < 35; i++) 'job-$i'];
      final chunks = chunkForWhereIn(ids);

      expect(chunks.length, 2);
      expect(chunks[0].length, 30);
      expect(chunks[1].length, 5);
      // The bug was losing ids, so assert on coverage, not just on counts.
      expect(chunks.expand((c) => c).toList(), ids);
    });

    test('never exceeds the whereIn limit, at any size', () {
      for (final size in [1, 29, 30, 31, 60, 61, 200]) {
        final ids = [for (var i = 0; i < size; i++) 'job-$i'];
        final chunks = chunkForWhereIn(ids);
        expect(
          chunks.every((c) => c.length <= kWhereInLimit && c.isNotEmpty),
          isTrue,
          reason: 'a $size-id watchlist produced an invalid chunk',
        );
        expect(
          chunks.expand((c) => c).length,
          size,
          reason: 'a $size-id watchlist lost or duplicated ids',
        );
      }
    });

    test('an empty watchlist produces no queries', () {
      expect(chunkForWhereIn(const []), isEmpty);
    });
  });

  group('Best Value uses live trust, not the bid snapshot', () {
    // The stored scores would rank Cheap Charlie first; the providers' current
    // scores are the reverse. Ranking must follow the live numbers, otherwise
    // Best Value orders today's bids by last week's reputation while each
    // provider's own profile shows something different.
    //
    //   stored: Charlie 950 -> 0.6*1.000 + 0.4*0.95 = 0.98  (would win)
    //   live:   Charlie 300 -> 0.6*1.000 + 0.4*0.30 = 0.72
    //           Tina    950 -> 0.6*0.833 + 0.4*0.95 = 0.88  -> wins
    testWidgets('ranks on the provider\'s current score', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final publicProfile = FakePublicProfileRepository({
        'p-cheap': const PublicProfile(
          uid: 'p-cheap',
          displayName: 'Cheap Charlie',
          role: UserRole.provider,
          trustScore: 300, // dropped since bidding
        ),
        'p-trust': const PublicProfile(
          uid: 'p-trust',
          displayName: 'Trusty Tina',
          role: UserRole.provider,
          trustScore: 950, // climbed since bidding
        ),
      });

      await tester.pumpWidget(
        buildApp(
          FakeAuthRepository(),
          jobs: [sampleJob()],
          bids: [
            sampleBid(
              providerId: 'p-cheap',
              providerName: 'Cheap Charlie',
              amountSen: 10000,
              trustScore: 950, // stale snapshot on the bid
            ),
            sampleBid(
              providerId: 'p-trust',
              providerName: 'Trusty Tina',
              amountSen: 12000,
              trustScore: 300, // stale snapshot on the bid
            ),
          ],
          publicProfile: publicProfile,
        ),
      );
      await tester.pumpAndSettle();
      await fillField(tester, 'Email', 'a@b.com');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();

      final firstCard = find.byType(BidCard).first;
      expect(
        find.descendant(of: firstCard, matching: find.text('Trusty Tina')),
        findsOneWidget,
        reason: 'live trust should decide the order, not the bid snapshot',
      );
      expect(
        find.descendant(of: firstCard, matching: find.text('BEST VALUE')),
        findsOneWidget,
      );
    });
  });

  group('Leaving onboarding', () {
    /// Registers a brand-new requestor, who the router sends into onboarding.
    Future<void> openOnboarding(WidgetTester tester) async {
      await tester.pumpWidget(
        buildApp(FakeAuthRepository()..onboardingComplete = false),
      );
      await tester.pumpAndSettle();
      await openRegisterAs(tester, 'Hire');
      expect(find.text('How will you hire?'), findsOneWidget);
    }

    testWidgets('back on the first stage asks before signing out', (
      tester,
    ) async {
      await openOnboarding(tester);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      // It must ask, not act: this used to sign the user out on one tap.
      expect(find.text('Leave onboarding?'), findsOneWidget);
    });

    testWidgets('choosing Stay keeps the user in onboarding', (tester) async {
      await openOnboarding(tester);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Stay'));
      await tester.pumpAndSettle();

      expect(find.text('Leave onboarding?'), findsNothing);
      expect(find.text('How will you hire?'), findsOneWidget);
    });

    testWidgets('choosing Sign out leaves onboarding', (tester) async {
      await openOnboarding(tester);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Sign out'));
      await tester.pumpAndSettle();

      expect(find.text('How will you hire?'), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // Bundle bidding (docs/BUNDLE_BIDDING.md phase 2): a provider prices the
  // tasks of a bundle they can do, as one package bid.
  // -------------------------------------------------------------------------
  group('Bundle bidding', () {
    final tasks = [
      sampleJob(
        id: 'job-1',
        title: 'Waterproof the floor',
        bundleId: 'b1',
        bundleOrder: 0,
        bundleTaskCount: 2,
      ),
      sampleJob(
        id: 'job-2',
        title: 'Tile the floor',
        bundleId: 'b1',
        bundleOrder: 1,
        bundleTaskCount: 2,
      ),
    ];

    /// Taps something that may be below the fold on this tall form.
    Future<void> tapAt(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    /// Pumps the sheet on its own: it is a form, so it needs nothing from the
    /// router or the shell, only the controller its fields drive.
    Future<FakeBundleBidRepository> pumpSheet(
      WidgetTester tester, {
      BundleBid? existing,
      Bundle? bundle,
    }) async {
      final bundleBids = FakeBundleBidRepository();
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: ChangeNotifierProvider(
          create: (_) => SubmitBundleBidController(bundleBids),
          child: Scaffold(
            body: SubmitBundleBidSheet(
              bundle: bundle ??
                  sampleBundle(id: 'b1', taskIds: const ['job-1', 'job-2']),
              tasks: tasks,
              bidder: const AppUser(
                uid: 'prov-1',
                email: 'pro@test.com',
                displayName: 'Pro Fixer',
                role: UserRole.provider,
              ),
              existing: existing,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return bundleBids;
    }

    /// Fills in everything the form needs beyond the task prices.
    Future<void> fillRest(WidgetTester tester) async {
      await tapAt(tester, find.byType(DropdownButtonFormField<String>));
      await tester.tap(find.text('Less than 1 week').last);
      await tester.pumpAndSettle();
      await fillField(tester, 'Proposal message', 'I can do this.');
      await tapAt(tester, find.byType(CheckboxListTile).last);
    }

    testWidgets('a bundle task card says how big its bundle is', (
      tester,
    ) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: JobCard(
            job: sampleJob(bundleId: 'b1', bundleOrder: 0, bundleTaskCount: 3),
          ),
        ),
      ));

      expect(find.text('Part of a 3-task bundle'), findsOneWidget);
    });

    testWidgets('an ordinary job card carries no bundle pill', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: JobCard(job: sampleJob())),
      ));

      expect(find.textContaining('bundle'), findsNothing);
    });

    testWidgets('submitting with no task picked is refused', (tester) async {
      final bundleBids = await pumpSheet(tester);

      await tapAt(
          tester, find.widgetWithText(PrimaryButton, 'Submit bundle bid'));

      expect(find.text('Pick at least one task to bid on.'), findsOneWidget);
      expect(bundleBids.lastSubmission, isNull);
    });

    testWidgets('one picked task is sent with its price in sen', (
      tester,
    ) async {
      final bundleBids = await pumpSheet(tester);

      await tapAt(
          tester, find.widgetWithText(CheckboxListTile, 'Tile the floor'));
      await fillField(tester, 'Price if you get only this task (RM)', '150.50');
      await fillRest(tester);
      await tapAt(
          tester, find.widgetWithText(PrimaryButton, 'Submit bundle bid'));

      expect(bundleBids.lastSubmission?['taskPrices'], {'job-2': 15050});
      expect(bundleBids.lastSubmission?['bundlePriceSen'], isNull);
      expect(
          bundleBids.lastSubmission?['estimatedDuration'], 'Less than 1 week');
    });

    testWidgets('a bundle price at or above the task total is refused', (
      tester,
    ) async {
      final bundleBids = await pumpSheet(tester);

      // Bundle price only makes sense once two or more tasks are picked.
      await tapAt(tester,
          find.widgetWithText(CheckboxListTile, 'Waterproof the floor'));
      await tapAt(
          tester, find.widgetWithText(CheckboxListTile, 'Tile the floor'));
      // Two task price fields now share a label; fill each by position.
      final priceFields = find.byType(TextFormField);
      await tester.ensureVisible(priceFields.at(0));
      await tester.enterText(priceFields.at(0), '50.00');
      await tester.ensureVisible(priceFields.at(1));
      await tester.enterText(priceFields.at(1), '50.00');
      await tester.pumpAndSettle();
      await tapAt(tester, find.text('+ Add a package deal (optional)'));
      await fillField(tester, 'Price if you win all 2 tasks (RM)', '100.00');
      await fillRest(tester);
      await tapAt(
          tester, find.widgetWithText(PrimaryButton, 'Submit bundle bid'));

      expect(
        find.textContaining('Must be under RM 100.00 (your task total)'),
        findsOneWidget,
      );
      expect(bundleBids.lastSubmission, isNull);
    });

    testWidgets('the sheet opens with a one-line tip', (tester) async {
      await pumpSheet(tester);

      expect(
        find.text('Tip: covering more tasks can win you the whole bundle.'),
        findsOneWidget,
      );
    });

    testWidgets(
      'a partial read of the bundle tasks blocks the sheet with a snackbar',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final auth = FakeAuthRepository()
          ..verificationStatus = 'approved'
          ..baseLat = 3.139
          ..baseLng = 101.6869;
        // Only job-1 is seeded, even though the bundle claims two tasks - a
        // stand-in for a `getBundleTasks` read landing before every task
        // document has synced.
        final job = sampleJob(
          requestorId: 'req-9',
          bundleId: 'b1',
          bundleOrder: 0,
          bundleTaskCount: 2,
        );
        final bundles = FakeBundleRepository(
          [sampleBundle(id: 'b1', taskIds: const ['job-1', 'job-2'])],
        );
        await tester.pumpWidget(buildApp(auth, jobs: [job], bundle: bundles));
        await tester.pumpAndSettle();
        await openRegisterAs(tester, 'Work');
        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();

        await tester.tap(
          find.widgetWithText(FilledButton, 'Bid on this bundle').first,
        );
        await tester.pumpAndSettle();

        expect(
          find.text(
            "Couldn't load every task in this bundle. Check your "
            'connection and try again.',
          ),
          findsOneWidget,
        );
        expect(find.byType(SubmitBundleBidSheet), findsNothing);
      },
    );
  });

  // -------------------------------------------------------------------------
  // A provider's package bids belong on their "Pending Bids" list alongside
  // their ordinary per-job bids (docs/BUNDLE_BIDDING.md) - both the Provider
  // Home stat and the My Jobs section.
  // -------------------------------------------------------------------------
  group('Pending bundle bids', () {
    testWidgets(
      'a pending bundle bid counts toward Pending Bids and shows in My '
      'Jobs, but a closed one does not',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final pending = BundleBid(
          bundleId: 'b1',
          providerId: 'uid-1',
          providerName: 'New User',
          taskPrices: const {'job-1': 37500, 'job-2': 52000},
          estimatedDuration: '1 week',
          bundleTitle: 'Bathroom refresh',
          createdAt: DateTime.now(),
        );
        final closed = BundleBid(
          bundleId: 'b2',
          providerId: 'uid-1',
          providerName: 'New User',
          taskPrices: const {'job-3': 10000},
          estimatedDuration: '1 week',
          status: BundleBidStatus.closed,
          bundleTitle: 'Kitchen refresh',
          createdAt: DateTime.now(),
        );
        final auth = FakeAuthRepository()..verificationStatus = 'approved';
        await tester.pumpWidget(buildApp(
          auth,
          bundleBid: FakeBundleBidRepository([pending, closed]),
        ));
        await tester.pumpAndSettle();
        await openRegisterAs(tester, 'Work');

        // Provider Home's "Pending Bids" stat counts only the pending one.
        expect(find.widgetWithText(StatCard, '1'), findsOneWidget);

        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('My jobs'),
          ),
        );
        await tester.pumpAndSettle();

        // The tile's primary line is now the quoted amount, with the bundle
        // title folded into a "<title> • N tasks" caption underneath.
        expect(find.textContaining('Bathroom refresh'), findsOneWidget);
        expect(find.textContaining('Kitchen refresh'), findsNothing);
      },
    );
  });

  // -------------------------------------------------------------------------
  // My Jobs groups a bundle's tasks under one card (bundle phase 4).
  // -------------------------------------------------------------------------
  group('My Jobs bundle grouping', () {
    testWidgets(
      "a requestor's bundle shows as one card with a progress line, "
      'and plain jobs stay unchanged',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final tasks = [
          sampleJob(id: 'job-1', title: 'Waterproofing', bundleId: 'b1',
              bundleOrder: 0, bundleTaskCount: 3, status: JobStatus.completed),
          sampleJob(id: 'job-2', title: 'Tiling', bundleId: 'b1',
              bundleOrder: 1, bundleTaskCount: 3, status: JobStatus.inProgress),
          sampleJob(id: 'job-3', title: 'Electrical fittings', bundleId: 'b1',
              bundleOrder: 2, bundleTaskCount: 3, status: JobStatus.open),
          sampleJob(id: 'job-4', title: 'Fix the fence'),
        ];
        final auth = FakeAuthRepository()..seedSignedIn(UserRole.requestor);
        final bundles = FakeBundleRepository([
          sampleBundle(
              id: 'b1',
              title: 'Bathroom refresh',
              taskIds: const ['job-1', 'job-2', 'job-3']),
        ]);
        await tester
            .pumpWidget(buildApp(auth, jobs: tasks, bundle: bundles));
        await tester.pumpAndSettle();
        await tester.tap(find.descendant(
            of: find.byType(NavigationBar), matching: find.text('My jobs')));
        await tester.pumpAndSettle();

        expect(find.text('Bathroom refresh'), findsOneWidget);
        expect(find.text('3 tasks · 1 in progress · 1 done · '
            '1 open'), findsOneWidget);
        expect(find.text('Waterproofing'), findsOneWidget);
        expect(find.text('Tiling'), findsOneWidget);
        expect(find.text('Electrical fittings'), findsOneWidget);
        // A plain job (no bundleId) still renders as its own ordinary card.
        expect(find.text('Fix the fence'), findsOneWidget);
      },
    );

    testWidgets(
      'a status filter narrows a bundle to its matching tasks, and hides '
      "the card entirely if none match",
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final tasks = [
          sampleJob(id: 'job-1', title: 'Waterproofing', bundleId: 'b1',
              bundleOrder: 0, bundleTaskCount: 3, status: JobStatus.completed),
          sampleJob(id: 'job-2', title: 'Tiling', bundleId: 'b1',
              bundleOrder: 1, bundleTaskCount: 3, status: JobStatus.inProgress),
          sampleJob(id: 'job-3', title: 'Electrical fittings', bundleId: 'b1',
              bundleOrder: 2, bundleTaskCount: 3, status: JobStatus.open),
          sampleJob(id: 'job-4', title: 'Roof repair', bundleId: 'b2',
              bundleOrder: 0, bundleTaskCount: 1, status: JobStatus.open),
        ];
        final auth = FakeAuthRepository()..seedSignedIn(UserRole.requestor);
        final bundles = FakeBundleRepository([
          sampleBundle(
              id: 'b1',
              title: 'Bathroom refresh',
              taskIds: const ['job-1', 'job-2', 'job-3']),
          sampleBundle(
              id: 'b2', title: 'Roofing', taskIds: const ['job-4']),
        ]);
        await tester
            .pumpWidget(buildApp(auth, jobs: tasks, bundle: bundles));
        await tester.pumpAndSettle();
        await tester.tap(find.descendant(
            of: find.byType(NavigationBar), matching: find.text('My jobs')));
        await tester.pumpAndSettle();

        final chip = find.widgetWithText(ChoiceChip, 'Completed');
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pumpAndSettle();

        // Only the matching task shows, but the progress line still counts
        // every task in the bundle.
        expect(find.text('Bathroom refresh'), findsOneWidget);
        expect(find.text('3 tasks · 1 in progress · 1 done · '
            '1 open'), findsOneWidget);
        expect(find.text('Waterproofing'), findsOneWidget);
        expect(find.text('Tiling'), findsNothing);
        expect(find.text('Electrical fittings'), findsNothing);
        // No task in "Roofing" is completed, so the card is hidden entirely.
        expect(find.text('Roofing'), findsNothing);
      },
    );
  });

  // -------------------------------------------------------------------------
  // A task `awardBundle` left unawarded (docs/BUNDLE_BIDDING.md): from then
  // on it is an ordinary job, not a bundle task, for both bidding and
  // cancelling - even though `bundleId` is still set.
  // -------------------------------------------------------------------------
  group('Released bundle tasks', () {
    testWidgets(
      "a released task's bid sheet is the ordinary one, not the bundle's",
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final auth = FakeAuthRepository()
          ..verificationStatus = 'approved'
          ..baseLat = 3.139
          ..baseLng = 101.6869;
        final job = sampleJob(
          requestorId: 'req-9',
          bundleId: 'b1',
          bundleOrder: 0,
          bundleTaskCount: 2,
          releasedAt: DateTime.now(),
        );
        final bundles = FakeBundleRepository(
            [sampleBundle(id: 'b1', status: BundleStatus.awarded)]);
        await tester.pumpWidget(buildApp(auth, jobs: [job], bundle: bundles));
        await tester.pumpAndSettle();
        await openRegisterAs(tester, 'Work');
        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();

        expect(find.text('Released from its bundle'), findsOneWidget);

        await tester.tap(find.widgetWithText(FilledButton, 'Submit a bid').first);
        await tester.pumpAndSettle();

        expect(find.widgetWithText(FilledButton, 'Submit bid'), findsOneWidget);
        expect(find.widgetWithText(PrimaryButton, 'Submit bundle bid'),
            findsNothing);
      },
    );

    testWidgets(
      "the owner cancels a released task like an ordinary job, not the "
      'bundle',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final auth = FakeAuthRepository()..walletBalanceSen = 20000;
        final job = sampleJob(
          bundleId: 'b1',
          bundleOrder: 0,
          bundleTaskCount: 2,
          releasedAt: DateTime.now(),
        );
        final bundles = FakeBundleRepository(
            [sampleBundle(id: 'b1', status: BundleStatus.awarded)]);
        await tester.pumpWidget(buildApp(auth, jobs: [job], bundle: bundles));
        await tester.pumpAndSettle();
        await fillField(tester, 'Email', 'a@b.com');
        await fillField(tester, 'Password', 'secret123');
        await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();

        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel job'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Cancel job'));
        await tester.pumpAndSettle();

        expect(bundles.cancelled, isEmpty);
        expect(find.text('This job was cancelled.'), findsOneWidget);
      },
    );
  });

  // -------------------------------------------------------------------------
  // Posting a bundle: Post-a-Job's "Add another task", which is the only way
  // a requestor can reach createBundle (docs/BUNDLE_BIDDING.md, "Requestor
  // side"). One task still posts an ordinary job - the group above covers
  // that path and must keep passing.
  // -------------------------------------------------------------------------
  group('Post a bundle', () {
    /// Signs in a requestor, opens the form, and hands back the fake the
    /// posting will go through.
    Future<FakeBundleRepository> openPostJob(WidgetTester tester) async {
      // Taller than the single-job form's 1600: a task card adds a section.
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final auth = FakeAuthRepository()
        ..defaultLat = 5.4164
        ..defaultLng = 100.3327
        ..defaultDistrictCode = 'TL'
        ..defaultTown = 'George Town'
        ..seedSignedIn(UserRole.requestor);
      final bundles = FakeBundleRepository();
      await tester.pumpWidget(buildApp(auth, bundle: bundles));
      await tester.pumpAndSettle();
      await tester.tap(find.text('+ Post a job'));
      await tester.pumpAndSettle();
      return bundles;
    }

    Future<void> addTask(WidgetTester tester) async {
      final add = find.textContaining('Add another task');
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();
    }

    /// Picks [category] in the [index]-th category dropdown (0 is task 1).
    Future<void> pickCategory(
      WidgetTester tester,
      int index,
      String category,
    ) async {
      final dropdown = find.byType(DropdownButtonFormField<String>).at(index);
      await tester.ensureVisible(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text(category).last);
      await tester.pumpAndSettle();
    }

    testWidgets('adding a task turns the form into a bundled posting', (
      tester,
    ) async {
      await openPostJob(tester);
      expect(find.widgetWithText(FilledButton, 'Post job'), findsOneWidget);

      await addTask(tester);

      expect(find.text('Task 1'), findsOneWidget);
      expect(find.text('Task 2'), findsOneWidget);
      expect(find.text('Posting title'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Post bundle'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Post job'), findsNothing);
    });

    /// Taps something that may be below the fold on this long form.
    Future<void> tapAt(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    testWidgets('adding a task counts them and asks for a posting name', (
      tester,
    ) async {
      await openPostJob(tester);
      await addTask(tester);

      expect(find.text('2 tasks in this posting'), findsOneWidget);
      // The name is asked for at the end of the form, not above the fold.
      expect(find.text('Name this posting'), findsOneWidget);
    });

    testWidgets('the task you add is scrolled into view', (tester) async {
      await openPostJob(tester);
      // A phone-sized viewport, where the new card starts off screen.
      await tester.binding.setSurfaceSize(const Size(400, 700));
      await tester.pumpAndSettle();

      await addTask(tester);

      final card = tester.getRect(find.text('Task 2'));
      expect(card.top, lessThan(700));
      expect(card.bottom, greaterThan(0));
    });

    testWidgets('an address already added is flagged, and clears', (
      tester,
    ) async {
      await openPostJob(tester);
      await tapAt(tester,
          find.text('Add address (only your hired provider sees it)'));
      await fillField(tester, 'Address line 1', '12 Jalan Mawar');
      await fillField(tester, 'Postcode', '11900');
      await fillField(tester, 'Town/City', 'Bayan Lepas');
      await tapAt(tester, find.widgetWithText(FilledButton, 'Save address'));

      await addTask(tester);

      expect(find.textContaining('service address you added will not be'),
          findsOneWidget);
      await tapAt(tester, find.widgetWithText(TextButton, 'Clear it'));
      expect(find.textContaining('service address you added will not be'),
          findsNothing);
    });

    testWidgets('a two-task form posts one bundle', (tester) async {
      final bundles = await openPostJob(tester);

      await pickCategory(tester, 0, 'Plumbing');
      await fillField(tester, 'Job title', 'Fix the kitchen tap');
      await fillField(tester, 'Description', 'It drips constantly.');
      await addTask(tester);
      await pickCategory(tester, 1, 'Electrical');
      await fillField(tester, 'Task 2 title', 'Replace the ceiling light');
      await fillField(tester, 'Task 2 description', 'The fitting is cracked.');
      await fillField(tester, 'Posting title', 'Kitchen refresh');

      final submit = find.widgetWithText(FilledButton, 'Post bundle');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Post anyway'));
      await tester.pumpAndSettle();

      final posted = bundles.lastCreate!;
      final tasks = posted['tasks'] as List<BundleTaskDraft>;
      expect(posted['title'], 'Kitchen refresh');
      expect(tasks.map((t) => t.title),
          ['Fix the kitchen tap', 'Replace the ceiling light']);
      expect(tasks.map((t) => t.category), ['Plumbing', 'Electrical']);
      // The shared location came from the requestor's saved default.
      expect((posted['location'] as JobLocation).districtCode, 'TL');
      // A blank summary falls back to the task titles, because createBundle
      // requires a description and the form already knows one.
      expect(posted['description'],
          '2 tasks: Fix the kitchen tap, Replace the ceiling light.');
      expect(find.text('Bundle posted with 2 tasks!'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // Awarding a bundle (phase 3): the requestor's screen turns the server's
  // three options into one award action.
  // -------------------------------------------------------------------------
  group('Bundle award', () {
    final tasks = [
      sampleJob(id: 'job-1', title: 'Waterproof the floor', bundleId: 'b1',
          bundleOrder: 0, bundleTaskCount: 2),
      sampleJob(id: 'job-2', title: 'Tile the floor', bundleId: 'b1',
          bundleOrder: 1, bundleTaskCount: 2),
    ];

    final recommended = const BundleAwardOption(
      key: 'recommended',
      label: 'Recommended',
      totalSen: 87500,
      providerCount: 2,
      premiumSen: 3500,
      weightedTrust: 751,
      awards: [
        BundleAwardItem(
          providerId: 'prov-1',
          providerName: 'Aida Renovation',
          taskAmountsSen: {'job-1': 37500},
        ),
        BundleAwardItem(
          providerId: 'prov-2',
          providerName: 'Dev Tiling',
          taskAmountsSen: {'job-2': 50000},
        ),
      ],
    );

    BundleBid bid() => BundleBid(
      bundleId: 'b1',
      providerId: 'prov-1',
      providerName: 'Aida Renovation',
      taskPrices: const {'job-1': 37500, 'job-2': 52000},
      estimatedDuration: '1 week',
      createdAt: DateTime.now(),
    );

    Future<FakeBundleRepository> pumpBundle(
      WidgetTester tester, {
      Bundle? bundle,
    }) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final bundles = FakeBundleRepository([
        bundle ?? sampleBundle(id: 'b1', taskIds: const ['job-1', 'job-2']),
      ])..awardOptions = [recommended];
      // A nested route (rather than a bare `home:`) so the screen's own
      // `context.pop()` on a successful award has somewhere to go back to -
      // matching how it's really reached, pushed from a job's "View bundle".
      final router = GoRouter(
        initialLocation: '/bundle',
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const Scaffold(body: SizedBox()),
            routes: [
              GoRoute(
                path: 'bundle',
                builder: (context, state) => MultiProvider(
                  providers: [
                    Provider<BundleRepository>.value(value: bundles),
                    Provider<JobRepository>.value(
                        value: FakeJobRepository(tasks)),
                    Provider<BundleBidRepository>.value(
                        value: FakeBundleBidRepository([bid()])),
                    // The bundle's requestorId defaults to 'uid-1', matching
                    // the fake's default signed-in uid, so the screen sees
                    // the caller as the owner - as it always is in practice.
                    ChangeNotifierProvider<AuthController>(
                      create: (_) => AuthController(
                          FakeAuthRepository()..seedSignedIn(UserRole.requestor)),
                    ),
                  ],
                  child: const BundleDetailScreen(bundleId: 'b1'),
                ),
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(
        theme: AppTheme.light,
        routerConfig: router,
      ));
      await tester.pumpAndSettle();
      return bundles;
    }

    testWidgets('the screen lists each task with what was bid on it', (
      tester,
    ) async {
      await pumpBundle(tester);

      // The by-task pick rows; the bids open from a button.
      expect(find.text('Waterproof the floor'), findsOneWidget);
      expect(find.text('Tile the floor'), findsOneWidget);
      expect(find.text('View all bids (1)'), findsOneWidget);
      // Options are only fetched when the requestor asks for them.
      expect(find.text('Recommended'), findsNothing);
    });

    testWidgets('awarding an option sends its picks and total', (
      tester,
    ) async {
      final bundles = await pumpBundle(tester);

      await tester.tap(find.widgetWithText(FilledButton,
          'Show award options'));
      await tester.pumpAndSettle();
      expect(find.text('Recommended'), findsOneWidget);
      expect(find.textContaining('RM\u00A035.00 (4.2%) more than the cheapest'),
          findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Award this option'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Award'));
      await tester.pumpAndSettle();

      expect(bundles.lastAward?['providerByTaskId'],
          {'job-1': 'prov-1', 'job-2': 'prov-2'});
      expect(bundles.lastAward?['expectedTotalSen'], 87500);
    });

    testWidgets('a partial award can drop the tasks it leaves out', (
      tester,
    ) async {
      final bundles = await pumpBundle(tester);
      // Options are fetched on demand, so swapping them after pumping works.
      bundles.awardOptions = const [
        BundleAwardOption(
          key: 'recommended',
          label: 'Recommended',
          totalSen: 37500,
          providerCount: 1,
          premiumSen: 0,
          weightedTrust: 751,
          uncoveredTaskIds: ['job-2'],
          awards: [
            BundleAwardItem(
              providerId: 'prov-1',
              providerName: 'Aida Renovation',
              taskAmountsSen: {'job-1': 37500},
            ),
          ],
        ),
      ];

      await tester.tap(find.widgetWithText(FilledButton,
          'Show award options'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Award this option'));
      await tester.pumpAndSettle();

      // Posting separately is the default, so the deadline row shows first.
      expect(find.textContaining('Released back until'), findsOneWidget);
      await tester.tap(find.text('Drop'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Released back until'), findsNothing);
      expect(find.text('It will be cancelled.'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Award'));
      await tester.pumpAndSettle();

      expect(bundles.lastAward?['providerByTaskId'], {'job-1': 'prov-1'});
      expect(bundles.lastAward?['dropUnawarded'], true);
      expect(bundles.lastAward?['releasedDeadline'], isNull);
    });

    testWidgets('a closed bundle hides the award buttons and explains why', (
      tester,
    ) async {
      final pastDeadline = DateTime.now().subtract(const Duration(days: 1));
      await pumpBundle(
        tester,
        bundle: sampleBundle(
          id: 'b1',
          taskIds: const ['job-1', 'job-2'],
          deadline: pastDeadline,
        ),
      );

      expect(find.widgetWithText(FilledButton, 'Show award options'),
          findsNothing);
      expect(find.textContaining('Bidding closed on'), findsOneWidget);
      expect(find.textContaining('can no longer be awarded'), findsOneWidget);
    });

    testWidgets('a rejected award brings back "Show award options"', (
      tester,
    ) async {
      final bundles = await pumpBundle(tester);
      bundles.awardError = const BundleRejectedException('The bids changed.');

      await tester.tap(
          find.widgetWithText(FilledButton, 'Show award options'));
      await tester.pumpAndSettle();
      await tester.tap(
          find.widgetWithText(FilledButton, 'Award this option'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Award'));
      await tester.pumpAndSettle();

      expect(find.text('The bids changed.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Show award options'),
          findsOneWidget);
      expect(find.text('Recommended'), findsNothing);
    });

    testWidgets('an insufficient balance shows the Top up dialog', (
      tester,
    ) async {
      final bundles = await pumpBundle(tester);
      bundles.awardError = const InsufficientBalanceException(
        shortfallSen: 5000,
        availableSen: 30000,
        requiredSen: 35000,
      );

      await tester.tap(
          find.widgetWithText(FilledButton, 'Show award options'));
      await tester.pumpAndSettle();
      await tester.tap(
          find.widgetWithText(FilledButton, 'Award this option'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Award'));
      await tester.pumpAndSettle();

      expect(find.text('Not enough balance'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Top up'), findsOneWidget);
    });

    /// Opens the task row titled [task] and picks [label] in its sheet.
    Future<void> pickManual(
      WidgetTester tester,
      String task,
      String label,
    ) async {
      await tester.ensureVisible(find.text(task));
      await tester.tap(find.text(task));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    final manualPick = const BundleAwardOption(
      key: 'manual',
      label: 'Your pick',
      totalSen: 89500,
      providerCount: 1,
      premiumSen: 2000,
      weightedTrust: 700,
      awards: [
        BundleAwardItem(
          providerId: 'prov-1',
          providerName: 'Aida Renovation',
          taskAmountsSen: {'job-1': 37500, 'job-2': 52000},
        ),
      ],
    );

    testWidgets('picking providers prices them and shows "Your pick"', (
      tester,
    ) async {
      final bundles = await pumpBundle(tester);
      bundles.manualOption = manualPick;

      await pickManual(tester, 'Waterproof the floor', 'Aida Renovation');
      await pickManual(tester, 'Tile the floor', 'Aida Renovation');

      expect(find.textContaining('Your pick: RM'), findsOneWidget);
      expect(bundles.lastManualPicks, {'job-1': 'prov-1', 'job-2': 'prov-1'});
    });

    testWidgets('a manual pick the server refuses shows its problems', (
      tester,
    ) async {
      final bundles = await pumpBundle(tester);
      bundles.manualProblems = const ['Prov-1 already covers job-2 elsewhere.'];

      await pickManual(tester, 'Waterproof the floor', 'Aida Renovation');

      expect(find.text('Prov-1 already covers job-2 elsewhere.'),
          findsOneWidget);
      final award = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Award your pick'));
      expect(award.onPressed, isNull);
    });

    testWidgets('clearing every pick removes the bar', (tester) async {
      final bundles = await pumpBundle(tester);
      bundles.manualOption = manualPick;

      await pickManual(tester, 'Waterproof the floor', 'Aida Renovation');
      expect(find.text('Award your pick'), findsOneWidget);

      await pickManual(tester, 'Waterproof the floor', "Don't award");
      expect(find.text('Award your pick'), findsNothing);
    });
  });

  group('AppTextField', () {
    testWidgets('a labelTrailing widget sits flush with the row\'s right '
        'edge', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: AppTextField(
            controller: TextEditingController(),
            label: 'Password',
            labelTrailing: const Text('Forgot?'),
          ),
        ),
      ));

      final row = find.ancestor(
        of: find.text('Forgot?'),
        matching: find.byType(Row),
      );
      final rowRight = tester.getRect(row).right;
      final trailingRight = tester.getRect(find.text('Forgot?')).right;
      // Expanded (not Flexible+Spacer) pushes the label to wrap instead of
      // splitting the row 50/50, so the trailing widget lands flush right.
      expect(trailingRight, closeTo(rowRight, 0.5));
    });
  });

  group('Description assist', () {
    Future<void> openPostJob(WidgetTester tester, {String? description}) async {
      await tester.binding.setSurfaceSize(const Size(800, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final auth = FakeAuthRepository()
        ..defaultLat = 5.4164
        ..defaultLng = 100.3327
        ..defaultDistrictCode = 'TL'
        ..defaultTown = 'George Town'
        ..seedSignedIn(UserRole.requestor);
      await tester.pumpWidget(buildApp(auth,
          assist: FakeAssistRepository(description: description)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('+ Post a job'));
      await tester.pumpAndSettle();
    }

    testWidgets('the written-draft Undo snackbar disappears on its own', (
      tester,
    ) async {
      await openPostJob(tester, description: 'A proper description.');

      final categoryDropdown =
          find.byType(DropdownButtonFormField<String>).first;
      await tester.ensureVisible(categoryDropdown);
      await tester.tap(categoryDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plumbing').last);
      await tester.pumpAndSettle();
      await fillField(tester, 'Description', 'leaking pipe');

      await tester.tap(find.text('Help me write this'));
      await tester.pumpAndSettle();

      expect(find.text('Draft written. Edit it to match your situation.'),
          findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'A proper description.'),
          findsOneWidget);

      // persist: false + a fixed duration: unlike the SDK default for a
      // SnackBar with an action (persist forever), this one times out on
      // its own.
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();

      expect(find.text('Draft written. Edit it to match your situation.'),
          findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // The one-shot draft: one rough note fills the form, and never overwrites
  // anything already typed.
  // -------------------------------------------------------------------------
  group('Drafting a post with AI', () {
    final draft = const JobDraft(
      title: 'Fix the kitchen tap',
      category: 'Plumbing',
      description: 'What needs doing\nTap drips all night.',
      minSen: 8000,
      maxSen: 15000,
    );

    Future<void> openPostJob(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final auth = FakeAuthRepository()
        ..defaultLat = 5.4164
        ..defaultLng = 100.3327
        ..defaultDistrictCode = 'TL'
        ..defaultTown = 'George Town'
        ..seedSignedIn(UserRole.requestor);
      await tester.pumpWidget(
          buildApp(auth, assist: FakeAssistRepository(draft: draft)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('+ Post a job'));
      await tester.pumpAndSettle();
    }

    Future<void> runDraft(WidgetTester tester) async {
      await tester.tap(find.text("Describe it once, we'll fill this in"));
      await tester.pumpAndSettle();
      await fillField(tester, 'In your own words', 'kitchen tap drips');
      await tester.tap(find.widgetWithText(FilledButton, 'Draft my post'));
      await tester.pumpAndSettle();
    }

    testWidgets('one note fills the title, category and budget', (
      tester,
    ) async {
      await openPostJob(tester);
      await runDraft(tester);

      expect(find.widgetWithText(TextFormField, 'Fix the kitchen tap'),
          findsOneWidget);
      expect(find.text('Plumbing'), findsOneWidget); // the category dropdown
      expect(find.widgetWithText(TextFormField, '80.00'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '150.00'), findsOneWidget);
    });

    testWidgets('a draft never overwrites what you already typed', (
      tester,
    ) async {
      await openPostJob(tester);
      await fillField(tester, 'Job title', 'My own title');
      await runDraft(tester);

      expect(find.widgetWithText(TextFormField, 'My own title'),
          findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Fix the kitchen tap'),
          findsNothing);
      // The fields it did fill are named back to the requestor.
      expect(find.textContaining('Filled in'), findsOneWidget);
    });
  });
}

/// Records save/upload order so tests can assert what the server would see.
class _OrderRepo extends FakeOnboardingRepository {
  _OrderRepo(super.auth, this.events);

  final List<String> events;

  @override
  Future<void> save(String uid, OnboardingData data) async =>
      events.add('save:${data.idDocumentType.name}');
}

class _OrderStorage extends FakeDocumentStorageRepository {
  _OrderStorage(this.events);

  final List<String> events;

  @override
  Future<String> uploadVerificationImage({
    required String uid,
    required String purpose,
    required XFile file,
  }) async {
    events.add('upload');
    return 'https://fake.storage/$uid/$purpose';
  }
}

/// Storage whose uploads stay pending until [gate] completes, so a test can
/// look at the UI mid-upload.
class _GatedStorage extends FakeDocumentStorageRepository {
  final gate = Completer<String>();
  final purposes = <String>[];

  @override
  Future<String> uploadVerificationImage({
    required String uid,
    required String purpose,
    required XFile file,
  }) {
    purposes.add(purpose);
    return gate.future;
  }

  @override
  Future<String> uploadAvatar({required String uid, required XFile file}) {
    purposes.add('avatar');
    return gate.future;
  }
}

/// Face checker that stays pending until [gate] completes.
class _GatedFaceChecker implements FaceChecker {
  final gate = Completer<FaceCheckResult>();

  @override
  Future<FaceCheckResult> check(String filePath, FaceCheckKind kind) =>
      gate.future;
}

class _FakePicker extends ImagePicker {
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async => XFile('id.jpg');
}

/// Face checker for tests: passes by default, or returns the given result.
/// Records the calls so tests can see whether a photo was checked at all.
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
