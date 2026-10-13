import 'face_box.dart';

/// How the provider operates on FairBid (stage 2).
enum ProviderType {
  individual,
  business;

  String get label => switch (this) {
        ProviderType.individual => 'Individual / Freelancer',
        ProviderType.business => 'Registered Business',
      };

  static ProviderType? fromStorage(String? value) => values.asNameMap()[value];
}

/// Which government ID the provider is verifying with.
enum IdDocumentType {
  mykad,
  passport;

  static IdDocumentType fromStorage(String? value) =>
      values.asNameMap()[value] ?? IdDocumentType.mykad;
}

/// What:   Everything a provider fills in during the 6-stage onboarding.
/// Input:  `onboarding` map on `users/{uid}` plus `private/verification`, via OnboardingRepository.
/// Output: Mutable draft owned by OnboardingController; [toMap] is public, [privateMap] owner+admin only.
class OnboardingData {
  OnboardingData();

  /// Current stage (2-6); stage 1 is account creation.
  int step = firstStep;

  static const firstStep = 2;
  static const lastStep = 6;

  // Stage 2 - provider type.
  ProviderType? providerType;

  // Stage 3 - identity verification. Firebase Storage download URLs.
  String? idDocumentUrl;
  String? selfieUrl;
  IdDocumentType idDocumentType = IdDocumentType.mykad;

  // MyKad number: sensitive, so it lives in [privateMap] only.
  String icNumber = '';

  // Face locations from the on-device check and the PDPA consent time; all private.
  FaceBox? idFaceBox;
  FaceBox? selfieFaceBox;
  DateTime? idConsentAt;

  // Stage 3 (business only) - SSM. The number is personal data for a sole
  // proprietorship, so it is in [privateMap], not [toMap]; the name stays public.
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

  // Stage 5 - service profile. `coverageArea` mirrors `Region.label`; the rest is the structured pick.
  String? category;
  String coverageArea = '';
  String? districtCode;
  String? town;
  double? lat;
  double? lng;
  List<String> portfolioImageUrls = [];

  /// Sensitive fields, stored in owner+admin-only `private/verification`.
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
