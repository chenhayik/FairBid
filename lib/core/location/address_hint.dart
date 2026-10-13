import 'package:geocoding/geocoding.dart';
import 'package:latlong2/latlong.dart';

/// What:   Best-effort street-level address suggestion reverse-geocoded from a map pin.
/// Input:  [reverseGeocode] / [AddressHint.fromPlacemark].
/// Output: Optional fields for pre-filling forms; never stored or authoritative (the district comes from PenangDistricts).
/// Notes:  Geocoders often omit the house number, so [line1] may be just the street.
class AddressHint {
  const AddressHint({
    this.line1,
    this.postcode,
    this.city,
    this.localityNames = const [],
  });

  /// House number and street, e.g. "12, Jalan Mawar 3".
  final String? line1;

  final String? postcode;

  final String? city;

  /// Locality labels, most specific first; used by [matchTown].
  final List<String> localityNames;

  /// True when there is nothing worth pre-filling.
  bool get isEmpty => line1 == null && postcode == null && city == null;

  /// The first of [towns] matching a locality case-insensitively, or null; the caller's list stays the truth.
  String? matchTown(Iterable<String> towns) {
    for (final name in localityNames) {
      for (final town in towns) {
        if (town.toLowerCase() == name.toLowerCase()) return town;
      }
    }
    return null;
  }

  /// Maps a [Placemark], turning empty strings into null.
  factory AddressHint.fromPlacemark(Placemark place) {
    String? clean(String? value) {
      final text = value?.trim();
      return text == null || text.isEmpty ? null : text;
    }

    final houseNumber = clean(place.subThoroughfare);
    final street = clean(place.thoroughfare) ?? clean(place.street);
    // Android's `street` may already include the house number.
    final prefix = street != null &&
            houseNumber != null &&
            !street.startsWith(houseNumber)
        ? houseNumber
        : null;
    return AddressHint(
      line1: street == null ? null : [?prefix, street].join(', '),
      postcode: clean(place.postalCode),
      city: clean(place.locality) ?? clean(place.subLocality),
      localityNames: [
        clean(place.subLocality),
        clean(place.locality),
      ].whereType<String>().toList(),
    );
  }
}

/// Geocoder timeout; Android's backend can hang and a missing suggestion is normal.
const _geocodeTimeout = Duration(seconds: 6);

/// What:   Best-effort reverse geocode of [point].
/// Input:  A LatLng.
/// Output: An [AddressHint], or null on any failure (no match, no geocoder, timeout).
Future<AddressHint?> reverseGeocode(LatLng point) async {
  try {
    final placemarks = await Geocoding()
        .placemarkFromCoordinates(point.latitude, point.longitude)
        .timeout(_geocodeTimeout);
    if (placemarks.isEmpty) return null;
    final hint = AddressHint.fromPlacemark(placemarks.first);
    return hint.isEmpty && hint.localityNames.isEmpty ? null : hint;
  } catch (_) {
    return null;
  }
}
