import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

/// What:   Offline point-in-polygon classifier over Penang's 5 districts; the source of truth for district membership.
/// Input:  `assets/geo/penang_districts.geojson` (geoBoundaries ADM2, CC BY 4.0, https://www.geoboundaries.org).
/// Output: [districtCodeAt] and [isInPenang]; the device geocoder only suggests towns.
class PenangDistricts {
  PenangDistricts._();

  /// Shared instance; the GeoJSON is parsed once.
  static final PenangDistricts instance = PenangDistricts._();

  static const _assetPath = 'assets/geo/penang_districts.geojson';

  List<_DistrictGeometry>? _districts;
  Future<void>? _loading;

  /// What:   One-time load of the district GeoJSON.
  /// Output: Future that completes when [districtCodeAt] / [isInPenang] are usable; repeat calls share the same load.
  Future<void> ensureLoaded() => _loading ??= _load();

  /// What:   Reads the asset and builds the district geometries.
  /// Input:  `assets/geo/penang_districts.geojson` via rootBundle.
  /// Output: Fills [_districts].
  Future<void> _load() async {
    final raw = await rootBundle.loadString(_assetPath);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final features = (json['features'] as List).cast<Map<String, dynamic>>();
    _districts = [for (final f in features) _DistrictGeometry.fromFeature(f)];
  }

  /// What:   District lookup for a point.
  /// Input:  A LatLng from the map or a stored pin.
  /// Output: The district code containing it; null outside all 5 or before [ensureLoaded] completes.
  String? districtCodeAt(LatLng point) {
    final districts = _districts;
    if (districts == null) return null;
    for (final district in districts) {
      if (district.contains(point)) return district.code;
    }
    return null;
  }

  /// What:   Whether a point falls inside any Penang district.
  /// Output: True when [districtCodeAt] finds a district.
  bool isInPenang(LatLng point) => districtCodeAt(point) != null;
}

/// What:   One district's polygons, with the point-in-polygon test.
/// Input:  A GeoJSON feature via [_DistrictGeometry.fromFeature]; in each polygon ring 0 is the exterior and further rings are holes.
/// Output: [code] and [contains].
class _DistrictGeometry {
  const _DistrictGeometry(this.code, this._polygons);

  factory _DistrictGeometry.fromFeature(Map<String, dynamic> feature) {
    final properties = feature['properties'] as Map<String, dynamic>;
    final geometry = feature['geometry'] as Map<String, dynamic>;
    final coordinates = geometry['coordinates'] as List;
    final polygons = geometry['type'] == 'MultiPolygon'
        ? [for (final polygon in coordinates) _ringsFrom(polygon as List)]
        : [_ringsFrom(coordinates)];
    return _DistrictGeometry(properties['district_code'] as String, polygons);
  }

  static List<List<LatLng>> _ringsFrom(List polygon) => [
    for (final ring in polygon)
      [
        for (final point in (ring as List))
          LatLng(
            ((point as List)[1] as num).toDouble(),
            (point[0] as num).toDouble(),
          ),
      ],
  ];

  final String code;
  final List<List<List<LatLng>>> _polygons;

  /// What:   Whether [point] lies inside this district.
  /// How:    Even-odd ray casting; hole crossings cancel the exterior's, and a MultiPolygon matches if any polygon does.
  bool contains(LatLng point) {
    for (final rings in _polygons) {
      var crossings = 0;
      for (final ring in rings) {
        crossings += _ringCrossings(point, ring);
      }
      if (crossings.isOdd) return true;
    }
    return false;
  }

  /// What:   Counts ring edges a ray from [point] crosses.
  /// Output: Crossing count; odd means the point is inside the ring.
  static int _ringCrossings(LatLng point, List<LatLng> ring) {
    var crossings = 0;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final a = ring[i];
      final b = ring[j];
      final crossesLatitude =
          (a.latitude > point.latitude) != (b.latitude > point.latitude);
      if (!crossesLatitude) continue;
      final longitudeAtCrossing =
          (b.longitude - a.longitude) *
              (point.latitude - a.latitude) /
              (b.latitude - a.latitude) +
          a.longitude;
      if (point.longitude < longitudeAtCrossing) crossings++;
    }
    return crossings;
  }
}
