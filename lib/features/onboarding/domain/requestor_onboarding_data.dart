/// Whether the requestor hires as a private individual or a company.
enum RequestorType {
  individual,
  business;

  String get label => switch (this) {
        RequestorType.individual => 'Individual',
        RequestorType.business => 'Business',
      };

  static RequestorType? fromStorage(String? value) => switch (value) {
        'individual' => RequestorType.individual,
        'business' => RequestorType.business,
        _ => null,
      };
}

/// Everything a requestor fills in during the short 3-stage onboarding.
///
/// Unlike the provider flow (which nests everything in an `onboarding` map),
/// requestor fields are general profile data reused across the app, so they are
/// persisted at the **top level** of the `users/{uid}` document.
class RequestorOnboardingData {
  RequestorOnboardingData();

  int step = firstStep;

  static const firstStep = 1;
  static const lastStep = 3;
  static const totalStages = 3;

  // Stage 1 — account type.
  RequestorType? type;

  // Stage 2 — details.
  String fullName = '';
  String? profilePhotoUrl;
  String phone = '';
  String location = '';
  String companyName = ''; // business only
  String ssmNumber = ''; // business only

  // Stage 3 — optional verification document (ID or SSM certificate).
  String? clientDocumentUrl;

  bool get isBusiness => type == RequestorType.business;

  /// Public fields to merge into the user document. The identity/SSM document
  /// URL is intentionally excluded — see [privateMap].
  Map<String, dynamic> toMap() => {
        'requestorOnboardingStep': step,
        'requestorType': type?.name,
        if (fullName.isNotEmpty) 'displayName': fullName,
        'profilePhotoUrl': profilePhotoUrl,
        'phone': phone,
        'location': location,
        'companyName': companyName,
        'ssmNumber': ssmNumber,
      };

  /// Sensitive identity document — stored in the owner+admin-only
  /// `users/{uid}/private/verification` doc, never in the world-readable
  /// user document.
  Map<String, dynamic> privateMap() => {
        'clientDocumentUrl': clientDocumentUrl,
      };

  /// Rebuilds from the top-level fields of a `users/{uid}` document.
  static RequestorOnboardingData fromMap(Map<String, dynamic>? map) {
    final data = RequestorOnboardingData();
    if (map == null) return data;
    data
      ..step = (map['requestorOnboardingStep'] as num?)
              ?.toInt()
              .clamp(firstStep, lastStep) ??
          firstStep
      ..type = RequestorType.fromStorage(map['requestorType'] as String?)
      ..fullName = map['displayName'] as String? ?? ''
      ..profilePhotoUrl = map['profilePhotoUrl'] as String?
      ..phone = map['phone'] as String? ?? ''
      ..location = map['location'] as String? ?? ''
      ..companyName = map['companyName'] as String? ?? ''
      ..ssmNumber = map['ssmNumber'] as String? ?? ''
      ..clientDocumentUrl = map['clientDocumentUrl'] as String?;
    return data;
  }
}
