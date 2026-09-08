import 'package:geocoding/geocoding.dart';
import 'package:latlong2/latlong.dart';

/// A best-effort street-level address suggestion, reverse-geocoded from a map
/// pin. Purely a convenience for pre-filling forms - never authoritative, and
/// never stored: the district of record still comes from offline
/// point-in-polygon (see `PenangDistricts`), and the pin itself stays the only
/// thing persisted alongside a job's public location.
///
/// Every field is optional because platform geocoders routinely return only
/// some of them. In Malaysia in particular a house number ([Placemark
/// .subThoroughfare]) is often missing, so [line1] is frequently just the
/// street name and the user still has to complete it.
class AddressHint {
  const AddressHint({
    this.line1,
    this.postcode,
    this.city,
    this.localityNames = const [],
  });

  /// House/unit number and street, e.g. "12, Jalan Mawar 3" - or just
  /// "Jalan Mawar 3" when the geocoder had no house number.
  final String? line1;

  /// 5-digit Malaysian postcode, when the geocoder returned one.
  final String? postcode;

  /// The geocoder's town/city label, e.g. "Bayan Lepas".
  final String? city;

  /// Every locality-ish label the geocoder returned, most specific first.
  /// Used by [matchTown] rather than being shown directly.
  final List<String> localityNames;

  /// True when there is nothing worth pre-filling.
  bool get isEmpty => line1 == null && postcode == null && city == null;

  /// The first of [towns] that matches one of [localityNames]
  /// case-insensitively, or null. Lets a caller keep its own fixed town list
  /// as the source of truth and treat the geocoder as a mere suggestion.
  String? matchTown(Iterable<String> towns) {
    for (final name in localityNames) {
      for (final town in towns) {
        if (town.toLowerCase() == name.toLowerCase()) return town;
      }
    }
    return null;
  }

  /// Maps a raw [Placemark], dropping empty strings so callers only ever see
  /// null-or-useful values.
  factory AddressHint.fromPlacemark(Placemark place) {
    String? clean(String? value) {
      final text = value?.trim();
      return text == null || text.isEmpty ? null : text;
    }

    final houseNumber = clean(place.subThoroughfare);
    final street = clean(place.thoroughfare) ?? clean(place.street);
    // Android's `street` sometimes already carries the house number, so only
    // prepend it when it isn't there already ("12, 12 Jalan Mawar").
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

/// How long to wait on the platform geocoder before giving up. Android's
/// backend can hang on a bad network, and every caller here treats a missing
/// suggestion as normal, so it is never worth blocking the UI longer.
const _geocodeTimeout = Duration(seconds: 6);

/// Best-effort reverse geocode of [point]. Returns `null` on any failure -
/// no matches, no geocoder on the device, a timeout - so callers can simply
/// carry on with nothing pre-filled.
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
