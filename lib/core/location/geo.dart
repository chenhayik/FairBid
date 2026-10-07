import 'package:latlong2/latlong.dart';

const _distance = Distance();

/// Great-circle (Haversine) distance in kilometres between two coordinates.
double distanceKm(LatLng a, LatLng b) =>
    _distance.as(LengthUnit.Kilometer, a, b);

/// What:   Coordinate rounder for pins other users can read.
/// Input:  A latitude or longitude.
/// Output: The value at 3 decimals (about 110 m), so no single house shows.
double coarseCoord(double v) => (v * 1000).round() / 1000;

/// A short human label for a distance, e.g. `0.4 km`, `2.5 km`, `12 km`.
String formatDistance(double km) {
  if (km < 10) return '${km.toStringAsFixed(1)} km';
  return '${km.round()} km';
}
