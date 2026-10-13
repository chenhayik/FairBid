import '../../../core/config/platform_config.dart';
import '../../auth/domain/user_role.dart';

/// What:   Read-only, public-safe view of another user's `users/{uid}` profile.
/// Input:  Doc data from PublicProfileRepository.watchProfile() (public_profile_repository.dart).
/// Output: Identity, stats, trust and provider extras for PublicProfileScreen.
/// Notes:  The mapper never reads email, phone, wallet or payout data, ID documents, raw certificate
///         URLs (only [certificateCount]), `disputesLost`, suspension state or precise coordinates
///         (only the town/district [location] label).
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
    this.portfolioImageUrls = const [],
    this.portfolioLinks = const [],
    this.certificateCount = 0,
  });

  final String uid;
  final String displayName;

  final String? photoUrl;

  final UserRole role;

  /// 'individual' / 'business', providers only; null for requestors.
  final String? providerType;

  final String? bio;

  /// Town or district label only; prefers `baseTown` / `town`, else the legacy `location` text.
  final String? location;

  final int trustScore;
  final TrustBreakdown? trustBreakdown;

  /// Mirrors `AppUser.scoreVisible`.
  bool get scoreVisible => trustBreakdown?.scoreVisible ?? false;

  final int ratingCount;
  final int ratingSum;

  /// Average stars (1-5); null with no reviews.
  double? get averageRating =>
      ratingCount == 0 ? null : ratingSum / ratingCount;

  final int jobsCompleted;

  /// A requestor's server-owned posting counters; [hireRate] (0-100) is null while [jobsPosted] is 0.
  final int jobsPosted;
  final int? hireRate;

  /// 'none', 'pending', 'approved' or 'rejected'; only 'approved' renders a badge.
  final String verificationStatus;

  /// Account creation time, shown as "Member Since" on a requestor's profile.
  final DateTime? memberSince;

  // Provider-only extras, read from the `onboarding` map.
  final String? category;
  final List<String> skills;
  final String? coverageArea;
  final List<String> portfolioImageUrls;
  final List<String> portfolioLinks;

  /// Count of `onboarding.certificateUrls`, never the URLs.
  final int certificateCount;

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
      portfolioImageUrls: strings(onboarding?['portfolioImageUrls']),
      portfolioLinks: strings(onboarding?['portfolioLinks']),
      certificateCount: strings(onboarding?['certificateUrls']).length,
    );
  }

  /// Accepts a Firestore Timestamp or a DateTime, so fakes work too.
  static DateTime? _asDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    // Duck-typed to avoid importing cloud_firestore in the domain layer.
    try {
      return (value as dynamic).toDate() as DateTime?;
    } catch (_) {
      return null;
    }
  }
}
