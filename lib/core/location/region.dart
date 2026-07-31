import 'penang.dart';

/// A structured country → state → district → town location. Scoped (for this
/// launch) to Penang, so [country]/[state] are effectively fixed and only
/// [districtCode] (required) and [town] (optional) vary.
///
/// The district is decided by offline point-in-polygon against the shipped
/// boundaries (see `PenangDistricts`) — never by the device geocoder, which
/// is only ever used to suggest a [town] label.
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

  /// Optional — the picker leaves this unset when the geocoder couldn't
  /// suggest one of [kPenangTowns] and the user didn't pick one either.
  final String? town;

  /// A human-readable label composed from the most to least specific part,
  /// e.g. "George Town, Timur Laut, Penang" or "Timur Laut, Penang" when no
  /// town is known.
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

  /// Rebuilds a [Region] from a stored map. Tolerates legacy data that has no
  /// structured region at all — returns `null` when [map] is null or is
  /// missing a district code, so callers can fall back to a raw address
  /// string instead of crashing.
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

  /// Resolves a district's display name from its [code] via
  /// [kPenangDistricts], falling back to the code itself if unrecognised.
  static String districtNameFor(String code) {
    for (final district in kPenangDistricts) {
      if (district.code == code) return district.nameMs;
    }
    return code;
  }
}

/// The value returned by `RegionPickerScreen`: coordinates, a composed
/// display [address] (== [region].label), and the structured [region] behind
/// it.
class PickedLocation {
  const PickedLocation({
    required this.lat,
    required this.lng,
    required this.address,
    required this.region,
  });

  final double lat;
  final double lng;
  final String address;
  final Region region;
}
