import 'package:latlong2/latlong.dart';

const _distance = Distance();

/// What:   Straight-line distance between two points.
/// Input:  Two LatLng coordinates.
/// Output: Kilometres (haversine).
double distanceKm(LatLng a, LatLng b) =>
    _distance.as(LengthUnit.Kilometer, a, b);

/// What:   Coordinate rounder for pins other users can read.
/// Input:  A latitude or longitude.
/// Output: The value at 3 decimals (about 110 m), so no single house shows.
double coarseCoord(double v) => (v * 1000).round() / 1000;

/// What:   Short distance label.
/// Input:  Kilometres, e.g. from [distanceKm].
/// Output: `0.4 km`, `2.5 km` or `12 km` (whole km from 10 up).
String formatDistance(double km) {
  if (km < 10) return '${km.toStringAsFixed(1)} km';
  return '${km.round()} km';
}
