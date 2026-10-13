import 'address_hint.dart';
import 'penang.dart';

/// What:   Structured country, state, district and town location (Penang only, so only [districtCode] and optional [town] vary).
/// Input:  Picker result or a stored map via [fromMap]; the district comes from PenangDistricts, never the geocoder.
/// Output: Immutable value with a readable [label].
class Region {
  const Region({
    this.country = kCountry,
    this.state = kState,
    required this.districtCode,
    required this.districtName,
    this.town,
  });

  final String country;
  final String state;
  final String districtCode;
  final String districtName;

  /// Unset when neither the user nor the geocoder produced a known town.
  final String? town;

  /// e.g. "George Town, Timur Laut, Penang", or "Timur Laut, Penang" without a town.
  String get label => [
    town,
    districtName,
    state,
  ].where((part) => part != null && part.isNotEmpty).join(', ');

  Map<String, dynamic> toMap() => {
    'country': country,
    'state': state,
    'districtCode': districtCode,
    'districtName': districtName,
    'town': town,
  };

  /// Rebuilds from a stored map; null when [map] is null or lacks a district code (legacy data).
  static Region? fromMap(Map<String, dynamic>? map) {
    final code = map?['districtCode'] as String?;
    if (code == null || code.isEmpty) return null;
    return Region(
      country: map?['country'] as String? ?? kCountry,
      state: map?['state'] as String? ?? kState,
      districtCode: code,
      districtName: map?['districtName'] as String? ?? districtNameFor(code),
      town: map?['town'] as String?,
    );
  }

  /// The display name for [code], or the code itself if unknown.
  static String districtNameFor(String code) {
    for (final district in kPenangDistricts) {
      if (district.code == code) return district.nameMs;
    }
    return code;
  }
}

/// What:   The result of `RegionPickerScreen`.
/// Input:  Coordinates, [address] (== [region].label), the [region] and an optional [addressHint].
/// Output: Immutable value; the hint only pre-fills the private service-address form and is never persisted.
class PickedLocation {
  const PickedLocation({
    required this.lat,
    required this.lng,
    required this.address,
    required this.region,
    this.addressHint,
  });

  final double lat;
  final double lng;
  final String address;
  final Region region;

  final AddressHint? addressHint;
}
