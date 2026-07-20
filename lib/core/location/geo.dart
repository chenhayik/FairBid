import 'package:latlong2/latlong.dart';

const _distance = Distance();

/// Great-circle (Haversine) distance in kilometres between two coordinates.
double distanceKm(LatLng a, LatLng b) =>
    _distance.as(LengthUnit.Kilometer, a, b);

/// A short human label for a distance, e.g. `0.4 km`, `2.5 km`, `12 km`.
String formatDistance(double km) {
  if (km < 10) return '${km.toStringAsFixed(1)} km';
  return '${km.round()} km';
}
