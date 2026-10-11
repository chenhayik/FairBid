/// Whether the requestor hires as an individual or a company.
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

  /// Public fields for the user doc; the document URL and phone are in [privateMap] / [payoutMap].
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

  /// Document URL and SSM number (personal data for a sole proprietorship) for owner+admin-only
  /// `private/verification`. The company name stays public in [toMap].
  Map<String, dynamic> privateMap() => {
        'clientDocumentUrl': clientDocumentUrl,
        'ssmNumber': ssmNumber,
        'ssmNumberNormalized': ssmNumberNormalized,
      };

  /// Phone number for owner+admin-only `private/payout`.
  Map<String, dynamic> payoutMap() => {'phone': phone};

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
