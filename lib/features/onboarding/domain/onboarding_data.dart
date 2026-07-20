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

/// Everything a provider fills in during the 6-stage onboarding flow.
/// Persisted as one `onboarding` map on the `users/{uid}` document so progress
/// survives app restarts.
///
/// A deliberately simple mutable data class — the controller owns the single
/// instance and saves it after each stage.
class OnboardingData {
  OnboardingData();

  /// Current stage (2–6). Stage 1 is account creation itself.
  int step = firstStep;

  static const firstStep = 2;
  static const lastStep = 6;
  static const totalStages = 6;

  // Stage 2 — provider type.
  ProviderType? providerType;

  // Stage 3 — identity verification. Firebase Storage download URLs.
  String? idDocumentUrl;
  String? selfieUrl;

  // Stage 4 — profile.
  String displayName = '';
  String bio = '';
  List<String> skills = [];
  List<String> certificateUrls = [];
  List<String> portfolioLinks = [];

  // Stage 5 — service profile.
  String? category;
  String coverageArea = '';
  String hourlyRate = '';
  List<String> portfolioImageUrls = [];

  // Stage 6 — payout details. `accountNumber` is held only in memory while the
  // form is open; only its last 4 digits are ever persisted (see toMap).
  String bankName = '';
  String accountHolder = '';
  String accountNumber = '';
  String branchCode = '';

  /// The only part of the account number we store — the full number never
  /// reaches Firestore (the `users` doc is readable by any signed-in user).
  String get accountLast4 => accountNumber.length >= 4
      ? accountNumber.substring(accountNumber.length - 4)
      : '';

  /// Sensitive identity photos — stored in the owner+admin-only
  /// `users/{uid}/private/verification` doc, never in the world-readable
  /// `onboarding` map.
  Map<String, dynamic> privateMap() => {
        'idDocumentUrl': idDocumentUrl,
        'selfieUrl': selfieUrl,
      };

  Map<String, dynamic> toMap() => {
        'step': step,
        'providerType': providerType?.name,
        'displayName': displayName,
        'bio': bio,
        'skills': skills,
        'certificateUrls': certificateUrls,
        'portfolioLinks': portfolioLinks,
        'category': category,
        'coverageArea': coverageArea,
        'hourlyRate': hourlyRate,
        'portfolioImageUrls': portfolioImageUrls,
        'bankName': bankName,
        'accountHolder': accountHolder,
        'accountLast4': accountLast4,
        'branchCode': branchCode,
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
      ..idDocumentUrl = map['idDocumentUrl'] as String?
      ..selfieUrl = map['selfieUrl'] as String?
      ..displayName = map['displayName'] as String? ?? ''
      ..bio = map['bio'] as String? ?? ''
      ..skills = strings(map['skills'])
      ..certificateUrls = strings(map['certificateUrls'])
      ..portfolioLinks = strings(map['portfolioLinks'])
      ..category = map['category'] as String?
      ..coverageArea = map['coverageArea'] as String? ?? ''
      ..hourlyRate = map['hourlyRate'] as String? ?? ''
      ..portfolioImageUrls = strings(map['portfolioImageUrls'])
      ..bankName = map['bankName'] as String? ?? ''
      ..accountHolder = map['accountHolder'] as String? ?? ''
      ..accountNumber = map['accountNumber'] as String? ?? ''
      ..branchCode = map['branchCode'] as String? ?? '';
    return data;
  }
}
