import '../../auth/domain/user_role.dart';
import '../../onboarding/domain/face_box.dart';

/// One uploaded document, ready to render in the verification gallery.
class VerificationDocument {
  const VerificationDocument(
      {required this.label, required this.url, this.faceBox});

  static const idLabel = 'Identity Document';
  static const selfieLabel = 'Selfie';

  final String label;
  final String url;

  /// Where the face is in this photo, when the on-device check found it.
  final FaceBox? faceBox;
}

/// A read-only view of a `users/{uid}` document that is awaiting admin
/// verification (`verificationStatus == 'pending'`).
///
/// The admin queue only ever reads user docs, so this is deliberately a flat
/// snapshot built from the raw Firestore map rather than the full [AppUser]
/// (which the app builds only for the signed-in person). Provider onboarding
/// nests its fields under an `onboarding` map; requestor fields live at the top
/// level - [fromMap] reads from both.
class PendingVerification {
  const PendingVerification({
    required this.uid,
    required this.displayName,
    required this.role,
    this.email,
    this.providerType,
    this.submittedAt,
    this.trustScore = 0,
    this.phone,
    this.location,
    this.bio,
    this.category,
    this.coverageArea,
    this.companyName,
    this.ssmNumber,
    this.skills = const [],
    this.documents = const [],
  });

  final String uid;
  final String displayName;
  final UserRole role;
  final String? email;

  /// 'individual' / 'business' for providers; mirrors the requestor type too.
  final String? providerType;
  final DateTime? submittedAt;
  final int trustScore;

  final String? phone;
  final String? location;
  final String? bio;
  final String? category;
  final String? coverageArea;
  final String? companyName;
  final String? ssmNumber;
  final List<String> skills;

  /// Every uploaded image/document, labelled for the review gallery.
  final List<VerificationDocument> documents;

  bool get isProvider => role == UserRole.provider;

  /// Header subtitle, e.g. "Individual Provider" or "Business Requestor".
  String get roleSummary {
    final type = switch (providerType) {
      'individual' => 'Individual',
      'business' => 'Business',
      _ => null,
    };
    final base = isProvider ? 'Provider' : 'Requestor';
    return type == null ? base : '$type $base';
  }

  /// Builds a snapshot from a raw `users/{uid}` document map, or null when the
  /// document is missing. [payoutData] is the applicant's owner+admin-only
  /// `private/payout` doc (the phone, which moved off this public doc - see
  /// firestore.rules); `VerificationRepository.
  /// watchPending` loads it per applicant and passes it in here, mirroring
  /// `AuthRepository._mapUser`'s merge. Null (missing/unreadable doc) falls
  /// back to the legacy public-doc locations below, so applicants who
  /// haven't saved since the migration still display fully.
  static PendingVerification? fromMap(
    String uid,
    Map<String, dynamic>? data, {
    Map<String, dynamic>? payoutData,
    Map<String, dynamic>? verificationData,
  }) {
    if (data == null) return null;
    final role = UserRole.fromStorage(data['role'] as String?);
    final onboarding = data['onboarding'] as Map<String, dynamic>?;

    List<String> strings(dynamic v) =>
        (v as List?)?.whereType<String>().toList() ?? const [];

    final docs = <VerificationDocument>[];
    void add(String label, String? url) {
      if (url != null && url.isNotEmpty) {
        docs.add(VerificationDocument(label: label, url: url));
      }
    }

    // Only the public "Trust Booster" docs (certificates, portfolio) come from
    // the world-readable user doc. The sensitive identity photos (ID, selfie,
    // requestor ID/SSM) live in the private subcollection and are loaded
    // separately by VerificationRepository.loadIdentityDocuments.
    if (role == UserRole.provider) {
      var i = 1;
      for (final url in strings(onboarding?['certificateUrls'])) {
        add('Certificate $i', url);
        i++;
      }
      i = 1;
      for (final url in strings(onboarding?['portfolioImageUrls'])) {
        add('Portfolio $i', url);
        i++;
      }
    }

    return PendingVerification(
      uid: uid,
      displayName: data['displayName'] as String? ??
          data['email'] as String? ??
          'Unnamed user',
      role: role,
      email: data['email'] as String?,
      providerType: role == UserRole.provider
          ? (onboarding?['providerType'] as String?)
          : (data['requestorType'] as String?),
      submittedAt: _asDate(data['submittedAt']),
      trustScore: (data['trustScore'] as num?)?.toInt() ?? 0,
      phone: (payoutData?['phone'] ?? data['phone']) as String?,
      location: data['location'] as String?,
      bio: role == UserRole.provider
          ? (onboarding?['bio'] as String?)
          : (data['bio'] as String?),
      category: onboarding?['category'] as String?,
      coverageArea: onboarding?['coverageArea'] as String?,
      // Requestors keep the company name at the top level; providers nest it
      // in the onboarding map, mirroring how `bio` is handled above.
      companyName: (data['companyName'] ??
          onboarding?['businessName']) as String?,
      // The SSM number is only ever in the private doc now - see
      // `VerificationRepository._toPendingVerification`. The public fallback
      // covers accounts that have not saved since that migration.
      ssmNumber: (verificationData?['ssmNumber'] ??
          data['ssmNumber']) as String?,
      skills: strings(onboarding?['skills']),
      documents: docs,
    );
  }

  /// Accepts both a Firestore `Timestamp` (via its `toDate()`) and a plain
  /// `DateTime`, so the same parser works against Firestore and fakes.
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
