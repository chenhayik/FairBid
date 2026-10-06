import 'face_box.dart';

/// How the provider operates on FairBid (onboarding stage 2).
enum ProviderType {
  individual,
  business;

  String get label => switch (this) {
        ProviderType.individual => 'Individual / Freelancer',
        ProviderType.business => 'Registered Business',
      };

  static ProviderType? fromStorage(String? value) => switch (value) {
        'individual' => ProviderType.individual,
        'business' => ProviderType.business,
        _ => null,
      };
}

/// Which government ID the provider is verifying with.
enum IdDocumentType {
  mykad,
  passport;

  static IdDocumentType fromStorage(String? value) =>
      value == 'passport' ? IdDocumentType.passport : IdDocumentType.mykad;
}

/// Everything a provider fills in during the 6-stage onboarding flow.
/// Persisted as one `onboarding` map on the `users/{uid}` document so progress
/// survives app restarts.
///
/// A deliberately simple mutable data class - the controller owns the single
/// instance and saves it after each stage.
class OnboardingData {
  OnboardingData();

  /// Current stage (2–6). Stage 1 is account creation itself.
  int step = firstStep;

  static const firstStep = 2;
  static const lastStep = 6;
  static const totalStages = 6;

  // Stage 2 - provider type.
  ProviderType? providerType;

  // Stage 3 - identity verification. Firebase Storage download URLs.
  String? idDocumentUrl;
  String? selfieUrl;
  IdDocumentType idDocumentType = IdDocumentType.mykad;

  // MyKad number: sensitive, so it lives in [privateMap] only.
  String icNumber = '';

  // Face locations from the on-device check, and when the applicant agreed to
  // the ID/face processing (PDPA). All private, like the photos themselves.
  FaceBox? idFaceBox;
  FaceBox? selfieFaceBox;
  DateTime? idConsentAt;

  // Stage 3 (business providers only) - SSM registration. The number is
  // deliberately NOT in [toMap]: `users/{uid}` is readable by any signed-in
  // user, and for a sole proprietorship - which has no legal personality
  // separate from its owner - the registration number is personal data. It
  // lives in [privateMap] with the identity photos. The business *name* stays
  // public: a business trading under a name expects it to be seen, and
  // counterparties need it to know who they are hiring.
  String businessName = '';
  String ssmNumber = '';
  String ssmNumberNormalized = '';
  String? ssmDocumentUrl;

  // Stage 4 - profile.
  String displayName = '';
  String bio = '';
  List<String> skills = [];
  List<String> certificateUrls = [];
  List<String> portfolioLinks = [];

  // Stage 5 - service profile. `coverageArea` mirrors `Region.label` (kept as
  // a plain string for backward-compatible display); `districtCode`/`town`/
  // `lat`/`lng` are the structured pick behind it, from the Penang-scoped
  // location picker.
  String? category;
  String coverageArea = '';
  String? districtCode;
  String? town;
  double? lat;
  double? lng;
  List<String> portfolioImageUrls = [];

  /// Sensitive identity photos - stored in the owner+admin-only
  /// `users/{uid}/private/verification` doc, never in the world-readable
  /// `onboarding` map.
  Map<String, dynamic> privateMap() => {
        'idDocumentUrl': idDocumentUrl,
        'selfieUrl': selfieUrl,
        'ssmDocumentUrl': ssmDocumentUrl,
        'icNumber': icNumber,
        'idFaceBox': idFaceBox?.toMap(),
        'selfieFaceBox': selfieFaceBox?.toMap(),
        'idConsentAt': idConsentAt,
        'ssmNumber': ssmNumber,
        'ssmNumberNormalized': ssmNumberNormalized,
      };

  Map<String, dynamic> toMap() => {
        'step': step,
        'providerType': providerType?.name,
        'idDocumentType': idDocumentType.name,
        'businessName': businessName,
        'displayName': displayName,
        'bio': bio,
        'skills': skills,
        'certificateUrls': certificateUrls,
        'portfolioLinks': portfolioLinks,
        'category': category,
        'coverageArea': coverageArea,
        'districtCode': districtCode,
        'town': town,
        'lat': lat,
        'lng': lng,
        'portfolioImageUrls': portfolioImageUrls,
      };

  static OnboardingData fromMap(Map<String, dynamic>? map) {
    final data = OnboardingData();
    if (map == null) return data;

    List<String> strings(dynamic v) =>
        (v as List?)?.whereType<String>().toList() ?? [];

    data
      ..step = (map['step'] as num?)?.toInt().clamp(firstStep, lastStep) ??
          firstStep
      ..providerType = ProviderType.fromStorage(map['providerType'] as String?)
      ..idDocumentType =
          IdDocumentType.fromStorage(map['idDocumentType'] as String?)
      ..idDocumentUrl = map['idDocumentUrl'] as String?
      ..selfieUrl = map['selfieUrl'] as String?
      ..businessName = map['businessName'] as String? ?? ''
      ..displayName = map['displayName'] as String? ?? ''
      ..bio = map['bio'] as String? ?? ''
      ..skills = strings(map['skills'])
      ..certificateUrls = strings(map['certificateUrls'])
      ..portfolioLinks = strings(map['portfolioLinks'])
      ..category = map['category'] as String?
      ..coverageArea = map['coverageArea'] as String? ?? ''
      ..districtCode = map['districtCode'] as String?
      ..town = map['town'] as String?
      ..lat = (map['lat'] as num?)?.toDouble()
      ..lng = (map['lng'] as num?)?.toDouble()
      ..portfolioImageUrls = strings(map['portfolioImageUrls']);
    return data;
  }
}
