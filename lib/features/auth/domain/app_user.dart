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
    this.bio,
    this.walletBalanceSen = 0,
    this.ratingCount = 0,
    this.ratingSum = 0,
    this.jobsCompleted = 0,
    this.disputesLost = 0,
    this.trustBreakdown,
    this.profilePhotoUrl,
    this.providerType,
    this.payoutBankName,
    this.payoutAccountLast4,
    this.isPasswordAccount = true,
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

  /// A provider's payout bank and masked account tail, for the Earnings screen's
  /// Payout Method card. Null until onboarding captures them.
  final String? payoutBankName;
  final String? payoutAccountLast4;

  /// Whether email/password is a linked sign-in provider (vs. Google-only).
  /// Determines whether deleting the account needs a password confirmation
  /// or a fresh Google sign-in to satisfy Firebase's recent-login check.
  final bool isPasswordAccount;

  /// A provider's saved reference point, used to compute distance to jobs in
  /// "Jobs near you". Set via a map picker; null until chosen.
  final double? baseLat;
  final double? baseLng;
  final String? baseAddress;

  bool get hasBaseLocation => baseLat != null && baseLng != null;

  /// Reputation score 0–1000 (see the technical plan): a server-computed
  /// composite of reviews, track record, verification and profile
  /// completeness. Displayed only once [scoreVisible]; until then the UI
  /// shows a "New Provider" state instead of a number.
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

  /// True while the score is still hidden — the "New Provider" state.
  bool get isNewProvider => !scoreVisible;

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
}
