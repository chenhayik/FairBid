import '../../../core/config/platform_config.dart';
import 'user_role.dart';

/// A lightweight, framework-agnostic representation of the signed-in user.
///
/// The rest of the app depends on this instead of Firebase's `User` type, which
/// keeps the UI decoupled from Firebase and makes it easy to substitute a fake
/// user in tests.
class AppUser {
  const AppUser({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.role,
    this.verificationStatus = 'none',
    this.onboardingComplete = false,
    this.trustScore = 0,
    this.phone,
    this.location,
    this.baseLat,
    this.baseLng,
    this.baseAddress,
    this.baseDistrictCode,
    this.baseTown,
    this.defaultLat,
    this.defaultLng,
    this.defaultDistrictCode,
    this.defaultTown,
    this.bio,
    this.walletBalanceSen = 0,
    this.escrowLockedSen = 0,
    this.ratingCount = 0,
    this.ratingSum = 0,
    this.jobsCompleted = 0,
    this.disputesLost = 0,
    this.trustBreakdown,
    this.profilePhotoUrl,
    this.providerType,
    this.category,
    this.skills = const [],
    this.isPasswordAccount = true,
    this.emailVerified = false,
    this.watchlist = const [],
    this.suspended = false,
    this.suspensionReason,
  });

  final String uid;
  final String? email;
  final String? displayName;
  final UserRole role;
  final String? phone;
  final String? location;

  /// The "About" text shown on the profile. Editable by the user.
  final String? bio;

  /// Available wallet balance in sen (1/100 RM). Shown on the Earnings screen.
  final int walletBalanceSen;

  /// Sen the server holds back from the wallet (server-owned; always 0 now
  /// that jobs are funded at award). Not free to spend or withdraw.
  final int escrowLockedSen;

  /// The wallet balance actually free to accept a new bid or withdraw:
  /// [walletBalanceSen] minus what's already committed to accepted work.
  int get availableBalanceSen => walletBalanceSen - escrowLockedSen;

  /// Aggregate rating data, denormalised on the profile so "Reviews (N)" and
  /// the average star score render without loading the reviews subcollection.
  final int ratingCount;
  final int ratingSum;

  /// The user's average star rating (1–5), or null when they have no reviews.
  double? get averageRating => ratingCount == 0 ? null : ratingSum / ratingCount;

  /// Header avatar. Null until a photo is uploaded.
  final String? profilePhotoUrl;

  /// A provider's onboarding provider type ('individual' / 'business'), used for
  /// the header subtitle. Null for requestors.
  final String? providerType;

  /// A provider's primary service category and skills, from onboarding.
  /// Editable on Edit Profile. Empty for requestors.
  final String? category;
  final List<String> skills;

  /// Whether email/password is a linked sign-in provider (vs. Google-only).
  /// Determines whether deleting the account needs a password confirmation
  /// or a fresh Google sign-in to satisfy Firebase's recent-login check.
  final bool isPasswordAccount;

  /// Whether the user has confirmed the link in their verification email.
  /// Google accounts arrive already verified. Set only via
  /// [AuthRepository.reloadUser] - Firebase pushes nothing on its own.
  final bool emailVerified;

  /// A provider's saved reference point, used to compute distance to jobs in
  /// "Jobs near you". Set via a map picker; null until chosen.
  final double? baseLat;
  final double? baseLng;
  final String? baseAddress;

  /// The Penang district/town behind [baseAddress] (see `Region`), when set
  /// through the structured location picker. Null on legacy free-text data.
  final String? baseDistrictCode;
  final String? baseTown;

  bool get hasBaseLocation => baseLat != null && baseLng != null;

  /// A requestor's saved default location (set during onboarding, stage 2),
  /// used to pre-fill the Post-a-Job form. Stored at the **top level** of the
  /// `users/{uid}` document - see `RequestorOnboardingData.toMap`. Null for
  /// providers, and for requestors who onboarded before this existed.
  final double? defaultLat;
  final double? defaultLng;
  final String? defaultDistrictCode;
  final String? defaultTown;

  bool get hasDefaultLocation =>
      defaultLat != null && defaultLng != null && defaultDistrictCode != null;

  /// Reputation score 0–1000 (see the technical plan): a server-computed
  /// composite of reviews, track record, verification and profile
  /// completeness. Displayed only once [scoreVisible]; until then the UI
  /// shows a "New" state instead of a number.
  final int trustScore;

  /// Completed jobs (as provider or requestor) and disputes lost, the raw
  /// track-record inputs. Server-maintained.
  final int jobsCompleted;
  final int disputesLost;

  /// The server-computed sub-score breakdown behind [trustScore], or null on
  /// a profile the Cloud Function hasn't scored yet.
  final TrustBreakdown? trustBreakdown;

  /// Whether the Trust Score has been earned enough to display (admin-approved
  /// plus [PlatformConfig.minJobsForVisibleScore] completed jobs).
  bool get scoreVisible => trustBreakdown?.scoreVisible ?? false;

  /// True while the score is still hidden - the "New User" state.
  bool get isNewUser => !scoreVisible;

  /// 'none' → not submitted for admin review,
  /// 'pending' → submitted and awaiting admin review,
  /// 'approved' / 'rejected' → admin decision.
  final String verificationStatus;

  /// Requestors mark this true when they finish their (lighter) onboarding.
  /// Providers instead un-gate by submitting for review (status → 'pending').
  final bool onboardingComplete;

  /// Whether the user must finish onboarding before using the app.
  ///
  /// - Providers are gated until they submit for review (`verificationStatus`
  ///   leaves `'none'`).
  /// - Requestors are gated until they complete their onboarding.
  bool get needsOnboarding => switch (role) {
        UserRole.provider => verificationStatus == 'none',
        UserRole.requestor => !onboardingComplete,
        UserRole.admin => false,
      };

  /// Job ids the user has bookmarked (the "Saved Jobs" watchlist).
  final List<String> watchlist;

  /// Whether [jobId] is on the user's watchlist.
  bool isSaved(String jobId) => watchlist.contains(jobId);

  /// Whether an admin has suspended this account. A suspended user is frozen
  /// out of every action (posting, bidding, paying, chatting, reviewing) and
  /// the router locks them to the "account suspended" screen. Server-owned -
  /// set only by the `setUserSuspended` Cloud Function.
  final bool suspended;

  /// The admin's optional note explaining the suspension, shown on the
  /// suspended screen. Null when not suspended or no reason was given.
  final String? suspensionReason;
}
