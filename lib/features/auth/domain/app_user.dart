import '../../../core/config/platform_config.dart';
import 'user_role.dart';

/// What:   The signed-in user's profile, free of Firebase types.
/// Input:  Built by FirebaseAuthRepository._mapUser from Auth + `users/{uid}` + private/payout.
/// Output: Immutable value read by the router, controllers and screens.
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
    this.baseDistrictCode,
    this.baseTown,
    this.defaultLat,
    this.defaultLng,
    this.defaultDistrictCode,
    this.defaultTown,
    this.bio,
    this.walletBalanceSen = 0,
    this.ratingCount = 0,
    this.ratingSum = 0,
    this.jobsCompleted = 0,
    this.trustBreakdown,
    this.profilePhotoUrl,
    this.providerType,
    this.category,
    this.skills = const [],
    this.isPasswordAccount = true,
    this.emailVerified = false,
    this.mfaEnrolled = false,
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

  final String? bio;

  /// Wallet balance in sen: `users/{uid}/private/wallet` plus any legacy field on the
  /// profile doc. Only the signed-in user's own [AppUser] carries it.
  final int walletBalanceSen;

  /// Denormalised rating totals, so stars render without loading reviews.
  final int ratingCount;
  final int ratingSum;

  /// Average stars (1-5), null with no reviews.
  double? get averageRating => ratingCount == 0 ? null : ratingSum / ratingCount;

  final String? profilePhotoUrl;

  /// Provider onboarding type ('individual' / 'business'); null for requestors.
  final String? providerType;

  /// A provider's primary service category and skills; empty for requestors.
  final String? category;
  final List<String> skills;

  /// Whether email/password is a linked provider (else Google-only); decides the re-auth method.
  final bool isPasswordAccount;

  /// Whether the verification email link was confirmed; refreshed by [AuthRepository.reloadUser].
  final bool emailVerified;

  /// Blocks the app until the email link is clicked; Google accounts arrive verified.
  bool get needsEmailVerification => !emailVerified;

  /// Whether an authenticator app (TOTP) is enrolled as a second factor.
  final bool mfaEnrolled;

  /// Providers and admins must use two-factor; requestors may opt in.
  bool get requiresTwoFactor =>
      role == UserRole.provider || role == UserRole.admin;

  /// Blocks the app until a provider or admin sets up two-factor.
  bool get needsTwoFactor => requiresTwoFactor && !mfaEnrolled;

  /// A provider's saved reference point for "Jobs near you"; null until chosen.
  final double? baseLat;
  final double? baseLng;

  /// District/town of the base location (see `Region`); null on legacy data.
  final String? baseDistrictCode;
  final String? baseTown;

  bool get hasBaseLocation => baseLat != null && baseLng != null;

  /// A requestor's default location, pre-filling Post-a-Job; null for providers.
  final double? defaultLat;
  final double? defaultLng;
  final String? defaultDistrictCode;
  final String? defaultTown;

  bool get hasDefaultLocation =>
      defaultLat != null && defaultLng != null && defaultDistrictCode != null;

  /// Server-computed Trust Score 0-1000; shown only once [scoreVisible].
  final int trustScore;

  /// Completed jobs as provider or requestor (server-maintained).
  final int jobsCompleted;

  /// Sub-score breakdown behind [trustScore]; null until first scored.
  final TrustBreakdown? trustBreakdown;

  /// Admin-approved plus [PlatformConfig.minJobsForVisibleScore] completed jobs.
  bool get scoreVisible => trustBreakdown?.scoreVisible ?? false;

  /// 'none' (not submitted), 'pending', 'approved' or 'rejected'.
  final String verificationStatus;

  /// Set by requestors on finishing onboarding; providers un-gate via [verificationStatus].
  final bool onboardingComplete;

  /// Providers are gated until they submit for review, requestors until they complete onboarding.
  bool get needsOnboarding => switch (role) {
        UserRole.provider => verificationStatus == 'none',
        UserRole.requestor => !onboardingComplete,
        UserRole.admin => false,
      };

  /// Bookmarked job ids ("Saved Jobs").
  final List<String> watchlist;

  /// Whether [jobId] is on the user's watchlist.
  bool isSaved(String jobId) => watchlist.contains(jobId);

  /// Admin suspension; the router locks the user to the suspended screen. Set by `setUserSuspended`.
  final bool suspended;

  /// Optional admin note shown on the suspended screen.
  final String? suspensionReason;
}
