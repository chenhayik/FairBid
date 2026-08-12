import '../../../core/config/platform_config.dart';
import '../../auth/domain/user_role.dart';

/// A read-only, publicly-safe view of another user's `users/{uid}` profile -
/// what a requestor sees when checking out a bidder, or a provider sees when
/// checking who posted a job. Built by [PublicProfileRepository] from the
/// same doc `AppUser` maps for the signed-in user, but the mapper only ever
/// reads the fields this class exposes below.
///
/// Deliberately excluded, even though the underlying doc (or its
/// subcollections) may carry them for the owner's own use - the mapper never
/// reads these, so they can never leak through this model:
/// - `email`, `phone` - contact details; not the public's business. `phone`
///   has already moved off the public doc into the owner+admin-only
///   `private/payout` subdocument, which this repository never queries.
/// - `walletBalanceSen`, `escrowLockedSen` - another person's money is
///   nobody else's business.
/// - Payout bank fields (`bankName`, `accountHolder`, `accountLast4`,
///   `branchCode`) - live in the same owner+admin-only `private/payout`
///   subdocument as phone.
/// - `idDocumentUrl`, `selfieUrl` - identity documents live in the
///   owner+admin-only `private/verification` subdocument; this repository
///   never queries it.
/// - `onboarding.certificateUrls` - the raw certificate photos routinely
///   carry an IC number or a home address; only [certificateCount], a plain
///   count, is exposed.
/// - `disputesLost` as a standalone number - it already feeds [trustScore]
///   through the server-computed [trustBreakdown]; surfacing the raw count on
///   its own is a scarlet letter with no context (a dispute can be lost for
///   reasons that aren't the user's fault), so it isn't exposed here at all.
/// - `suspended` / `suspensionReason` - moderation state; not the public's
///   business, and would out someone as under active discipline.
/// - `baseLat`/`baseLng`/`baseAddress` and the requestor's `lat`/`lng` -
///   precise coordinates/address. Only the town/district label behind them
///   ([location]) is surfaced, never a pinpoint location.
class PublicProfile {
  const PublicProfile({
    required this.uid,
    required this.displayName,
    this.photoUrl,
    required this.role,
    this.providerType,
    this.bio,
    this.location,
    this.trustScore = 0,
    this.trustBreakdown,
    this.ratingCount = 0,
    this.ratingSum = 0,
    this.jobsCompleted = 0,
    this.jobsPosted = 0,
    this.hireRate,
    this.verificationStatus = 'none',
    this.memberSince,
    this.category,
    this.skills = const [],
    this.coverageArea,
    this.hourlyRate,
    this.portfolioImageUrls = const [],
    this.portfolioLinks = const [],
    this.certificateCount = 0,
  });

  final String uid;
  final String displayName;

  /// Snapshot of `profilePhotoUrl`. Null shows [UserAvatar]'s placeholder.
  final String? photoUrl;

  final UserRole role;

  /// 'individual' / 'business', providers only; null for requestors.
  final String? providerType;

  final String? bio;

  /// The town/district label only - see the class doc for what this
  /// deliberately is not (no coordinates, no street-level address). Prefers
  /// the structured town picked during onboarding (`baseTown` for a
  /// provider, `town` for a requestor) and falls back to the legacy
  /// free-text `location` field only when neither is set.
  final String? location;

  final int trustScore;
  final TrustBreakdown? trustBreakdown;

  /// Whether the Trust Score has been earned enough to display - mirrors
  /// `AppUser.scoreVisible`.
  bool get scoreVisible => trustBreakdown?.scoreVisible ?? false;

  final int ratingCount;
  final int ratingSum;

  /// The user's average star rating (1–5), or null with no reviews yet.
  double? get averageRating =>
      ratingCount == 0 ? null : ratingSum / ratingCount;

  final int jobsCompleted;

  /// A requestor's job-posting counters, server-owned (see firestore.rules'
  /// `trustFields()`). [hireRate] (0–100) is the share of posted jobs that
  /// reached an assigned/accepted state; null while [jobsPosted] is zero, so
  /// a brand-new client never shows a misleading "0%".
  final int jobsPosted;
  final int? hireRate;

  /// 'none' / 'pending' / 'approved' / 'rejected'. Only 'approved' ever
  /// renders a badge - see [PublicProfileScreen]; the others render nothing,
  /// never a punitive "Unverified".
  final String verificationStatus;

  /// When the account was created (from the doc's `createdAt`), shown as
  /// "Member since {month year}" on a requestor's profile.
  final DateTime? memberSince;

  // Provider-only extras, read from the `onboarding` map.
  final String? category;
  final List<String> skills;
  final String? coverageArea;
  final String? hourlyRate;
  final List<String> portfolioImageUrls;
  final List<String> portfolioLinks;

  /// A COUNT of `onboarding.certificateUrls`, never the URLs themselves -
  /// see the class doc for why.
  final int certificateCount;

  /// Builds a [PublicProfile] from [uid] and its `users/{uid}` doc data -
  /// see the class doc for exactly which fields this deliberately never
  /// reads. Accepts either a Firestore `Timestamp` or a plain `DateTime` for
  /// `createdAt`, so the same parser works against Firestore and fakes.
  factory PublicProfile.fromMap(String uid, Map<String, dynamic> m) {
    final onboarding = m['onboarding'] as Map<String, dynamic>?;
    List<String> strings(dynamic v) =>
        (v as List?)?.whereType<String>().toList() ?? const [];

    final jobsPosted = (m['jobsPosted'] as num?)?.toInt() ?? 0;
    return PublicProfile(
      uid: uid,
      displayName: m['displayName'] as String? ?? 'User',
      photoUrl: m['profilePhotoUrl'] as String?,
      role: UserRole.fromStorage(m['role'] as String?),
      providerType: onboarding?['providerType'] as String?,
      bio: m['bio'] as String?,
      location:
          (m['baseTown'] ?? m['town'] ?? m['location']) as String?,
      trustScore: (m['trustScore'] as num?)?.toInt() ?? 0,
      trustBreakdown: m['trust'] == null
          ? null
          : TrustBreakdown.fromMap(m['trust'] as Map<String, dynamic>),
      ratingCount: (m['ratingCount'] as num?)?.toInt() ?? 0,
      ratingSum: (m['ratingSum'] as num?)?.toInt() ?? 0,
      jobsCompleted: (m['jobsCompleted'] as num?)?.toInt() ?? 0,
      jobsPosted: jobsPosted,
      hireRate: jobsPosted == 0 ? null : (m['hireRate'] as num?)?.toInt(),
      verificationStatus: m['verificationStatus'] as String? ?? 'none',
      memberSince: _asDate(m['createdAt']),
      category: onboarding?['category'] as String?,
      skills: strings(onboarding?['skills']),
      coverageArea: onboarding?['coverageArea'] as String?,
      hourlyRate: onboarding?['hourlyRate'] as String?,
      portfolioImageUrls: strings(onboarding?['portfolioImageUrls']),
      portfolioLinks: strings(onboarding?['portfolioLinks']),
      certificateCount: strings(onboarding?['certificateUrls']).length,
    );
  }

  /// Accepts both a Firestore `Timestamp` (via its `toDate()`) and a plain
  /// `DateTime`, mirroring `PendingVerification._asDate`.
  static DateTime? _asDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    // Duck-type Firestore's Timestamp without importing cloud_firestore here.
    try {
      return (value as dynamic).toDate() as DateTime?;
    } catch (_) {
      return null;
    }
  }
}
