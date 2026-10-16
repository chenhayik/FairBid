import '../../auth/domain/user_role.dart';
import '../../onboarding/domain/face_box.dart';

/// What:   One labelled document for the verification gallery.
/// Input:  [label], [url]; optional [faceBox].
/// Output: Immutable value; [idLabel] and [selfieLabel] are the standard labels.
class VerificationDocument {
  const VerificationDocument(
      {required this.label, required this.url, this.faceBox});

  static const idLabel = 'Identity Document';
  static const selfieLabel = 'Selfie';

  final String label;
  final String url;

  /// Where the on-device check found the face, if it did.
  final FaceBox? faceBox;
}

/// What:   Read-only snapshot of a user awaiting verification.
/// Input:  `users/{uid}` data plus private docs, via [fromMap] from VerificationRepository.watchPending().
/// Output: Flat fields for the admin queue and detail screens; [fromMap] reads provider (`onboarding` map) and requestor (top-level) fields.
class PendingVerification {
  const PendingVerification({
    required this.uid,
    required this.displayName,
    required this.role,
    this.email,
    this.providerType,
    this.submittedAt,
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

  /// 'individual' or 'business' (provider or requestor type).
  final String? providerType;
  final DateTime? submittedAt;

  final String? phone;
  final String? location;
  final String? bio;
  final String? category;
  final String? coverageArea;
  final String? companyName;
  final String? ssmNumber;
  final List<String> skills;

  final List<VerificationDocument> documents;

  bool get isProvider => role == UserRole.provider;

  /// e.g. "Individual Provider" or "Business Requestor".
  String get roleSummary {
    final type = switch (providerType) {
      'individual' => 'Individual',
      'business' => 'Business',
      _ => null,
    };
    final base = isProvider ? 'Provider' : 'Requestor';
    return type == null ? base : '$type $base';
  }

  /// What:   Builds a queue entry from the `users/{uid}` data.
  /// Input:  [data] (null gives null); [payoutData] and [verificationData] from the private docs.
  /// Output: PendingVerification with its public documents; the legacy public fields are used when the private docs are missing.
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

    // Only public certificates and portfolio here; identity photos load via
    // VerificationRepository.loadIdentityDocuments.
    if (role == UserRole.provider) {
      for (final (i, url) in strings(onboarding?['certificateUrls']).indexed) {
        add('Certificate ${i + 1}', url);
      }
      for (final (i, url) in strings(onboarding?['portfolioImageUrls']).indexed) {
        add('Portfolio ${i + 1}', url);
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
      phone: (payoutData?['phone'] ?? data['phone']) as String?,
      location: data['location'] as String?,
      bio: role == UserRole.provider
          ? (onboarding?['bio'] as String?)
          : (data['bio'] as String?),
      category: onboarding?['category'] as String?,
      coverageArea: onboarding?['coverageArea'] as String?,
      // Requestors keep it at the top level, providers under `onboarding`.
      companyName: (data['companyName'] ??
          onboarding?['businessName']) as String?,
      // The private doc wins; the public field covers legacy accounts.
      ssmNumber: (verificationData?['ssmNumber'] ??
          data['ssmNumber']) as String?,
      skills: strings(onboarding?['skills']),
      documents: docs,
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
