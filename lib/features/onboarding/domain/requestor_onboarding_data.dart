/// What:   Whether the requestor hires as an individual or a company.
/// Input:  Chosen in AccountTypeStep via RequestorType.fromStorage().
/// Output: individual or business, with a display [label].
enum RequestorType {
  individual,
  business;

  String get label => switch (this) {
        RequestorType.individual => 'Individual',
        RequestorType.business => 'Business',
      };

  static RequestorType? fromStorage(String? value) => values.asNameMap()[value];
}

/// What:   Everything a requestor fills in during the 3-stage onboarding.
/// Input:  Top-level fields of `users/{uid}` plus private docs, via RequestorOnboardingRepository.
/// Output: Mutable draft owned by RequestorOnboardingController.
/// Notes:  Top level (not an `onboarding` map) because the app reuses these as profile data.
class RequestorOnboardingData {
  RequestorOnboardingData();

  int step = firstStep;

  static const firstStep = 1;
  static const lastStep = 3;

  // Stage 1 - account type.
  RequestorType? type;

  // Stage 2 - details. `location` mirrors `Region.label`; the rest is the structured pick.
  String fullName = '';
  String? profilePhotoUrl;
  String phone = '';
  String location = '';
  String? districtCode;
  String? town;
  double? lat;
  double? lng;
  String companyName = ''; // business only
  String ssmNumber = ''; // business only
  String ssmNumberNormalized = ''; // canonical match key

  // Stage 3 - optional verification document (ID or SSM certificate).
  String? clientDocumentUrl;

  bool get isBusiness => type == RequestorType.business;

  /// What:   Public fields for the user doc.
  /// Input:  The draft: step, type, name, photo, location and company name.
  /// Output: Map merged into `users/{uid}`; the document URL and phone go through [privateMap] / [payoutMap].
  Map<String, dynamic> toMap() => {
        'requestorOnboardingStep': step,
        'requestorType': type?.name,
        if (fullName.isNotEmpty) 'displayName': fullName,
        'profilePhotoUrl': profilePhotoUrl,
        'location': location,
        'districtCode': districtCode,
        'town': town,
        'lat': lat,
        'lng': lng,
        'companyName': companyName,
      };

  /// What:   Fields for the owner+admin-only `private/verification` doc.
  /// Input:  Document URL and SSM number (personal data for a sole proprietorship).
  /// Output: Map written by FirestoreRequestorOnboardingRepository; the company name stays public in [toMap].
  Map<String, dynamic> privateMap() => {
        'clientDocumentUrl': clientDocumentUrl,
        'ssmNumber': ssmNumber,
        'ssmNumberNormalized': ssmNumberNormalized,
      };

  /// What:   Phone number for the owner+admin-only `private/payout` doc.
  /// Input:  [phone].
  /// Output: Map with the phone.
  Map<String, dynamic> payoutMap() => {'phone': phone};

  /// What:   Rebuilds a draft from the saved user doc.
  /// Input:  [map] of `users/{uid}` fields, possibly null.
  /// Output: A draft with the step clamped to the valid range and missing fields defaulted.
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
      ..districtCode = map['districtCode'] as String?
      ..town = map['town'] as String?
      ..lat = (map['lat'] as num?)?.toDouble()
      ..lng = (map['lng'] as num?)?.toDouble()
      ..companyName = map['companyName'] as String? ?? ''
      ..ssmNumber = map['ssmNumber'] as String? ?? ''
      ..ssmNumberNormalized = map['ssmNumberNormalized'] as String? ?? ''
      ..clientDocumentUrl = map['clientDocumentUrl'] as String?;
    return data;
  }
}
