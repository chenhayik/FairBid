import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

/// Offline point-in-polygon classifier over Penang's 5 districts.
///
/// Boundaries: geoBoundaries ADM2 (CC BY 4.0) - https://www.geoboundaries.org,
/// filtered down to Penang's 5 districts and shipped as
/// `assets/geo/penang_districts.geojson`.
///
/// This is the SOURCE OF TRUTH for which district a point belongs to. The
/// device geocoder is never used to decide district membership - only to
/// suggest a town label (see `RegionPickerScreen`).
class PenangDistricts {
  PenangDistricts._();

  /// Shared singleton - the GeoJSON is parsed once and cached for the life of
  /// the app.
  static final PenangDistricts instance = PenangDistricts._();

  static const _assetPath = 'assets/geo/penang_districts.geojson';

  List<_DistrictGeometry>? _districts;
  Future<void>? _loading;

  /// Loads and parses the bundled GeoJSON. Safe to call repeatedly -
  /// subsequent calls await the same cached load. Must complete before
  /// [districtCodeAt] / [isInPenang] return meaningful results.
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    final raw = await rootBundle.loadString(_assetPath);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final features = (json['features'] as List).cast<Map<String, dynamic>>();
    _districts = [for (final f in features) _DistrictGeometry.fromFeature(f)];
  }

  /// The district code (`TL`/`BD`/`SPU`/`SPT`/`SPS`) containing [point], or
  /// `null` if it's outside all 5 (e.g. open water) - or if [ensureLoaded]
  /// hasn't completed yet.
  String? districtCodeAt(LatLng point) {
    final districts = _districts;
    if (districts == null) return null;
    for (final district in districts) {
      if (district.contains(point)) return district.code;
    }
    return null;
  }

  /// Whether [point] falls inside any of Penang's 5 districts.
  bool isInPenang(LatLng point) => districtCodeAt(point) != null;
}

/// A single district's geometry: one or more polygons (a MultiPolygon has
/// more than one), each a list of rings - ring 0 is the exterior, any further
/// rings are holes.
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

  /// Even-odd ray-casting across every ring of a polygon correctly handles
  /// holes for free (a hole's crossings cancel out the exterior's), so each
  /// polygon's own total crossing parity gives its containment; a
  /// MultiPolygon then contains [point] if any one constituent polygon does.
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
