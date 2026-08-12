import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geocoding/geocoding.dart';
import 'package:latlong2/latlong.dart';

import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import 'penang.dart';
import 'penang_districts.dart';
import 'region.dart';

/// Penang-bounded location picker: a District dropdown (required), an
/// optional Town dropdown, and a map - all kept in two-way sync. Replaces the
/// old free-text location fields across the app. Push it with
/// [RegionPickerScreen.show].
///
/// - Dragging the map re-classifies the centre pin's district via offline
///   point-in-polygon ([PenangDistricts]) - the arbiter of record.
/// - Picking a District recentres the map to that district's seat.
/// - Picking a Town best-effort forward-geocodes it to recentre precisely,
///   falling back to the district seat if that fails or lands outside Penang.
/// - "Use this location" is disabled whenever the centre isn't inside any of
///   Penang's 5 districts; the District dropdown itself stays editable as a
///   near-border escape hatch (picking one always recentres to a point that's
///   in-bounds).
class RegionPickerScreen extends StatefulWidget {
  const RegionPickerScreen({
    super.key,
    required this.initialCenter,
    this.initialRegion,
  });

  final LatLng initialCenter;

  /// Pre-fills the district/town when re-opening the picker to edit an
  /// existing pick.
  final Region? initialRegion;

  static Future<PickedLocation?> show(
    BuildContext context, {
    LatLng? initialCenter,
    Region? initialRegion,
  }) {
    return Navigator.of(context).push<PickedLocation>(
      MaterialPageRoute(
        builder: (_) => RegionPickerScreen(
          initialCenter: initialCenter ?? kGeorgeTown,
          initialRegion: initialRegion,
        ),
      ),
    );
  }

  @override
  State<RegionPickerScreen> createState() => _RegionPickerScreenState();
}

class _RegionPickerScreenState extends State<RegionPickerScreen> {
  final _mapController = MapController();
  final _districts = PenangDistricts.instance;

  late LatLng _center = widget.initialCenter;
  String? _districtCode;
  String? _town;
  bool _resolving = false;

  /// True once the classifier's GeoJSON has finished loading. Guards
  /// [_syncDistrictForCenter] so a map move that fires before the asset
  /// finishes loading (e.g. the recentre right after picking a district)
  /// can't clobber that pick with a premature "not yet classified" null.
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _districtCode = widget.initialRegion?.districtCode;
    _town = widget.initialRegion?.town;
    _loadDistricts();
  }

  Future<void> _loadDistricts() async {
    await _districts.ensureLoaded();
    if (!mounted) return;
    setState(() {
      _ready = true;
      _syncDistrictForCenter();
    });
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  /// Re-classifies [_districtCode] from the current [_center] via
  /// point-in-polygon (the arbiter of record), clearing [_town] if it no
  /// longer belongs to the (possibly new) district.
  void _syncDistrictForCenter() {
    _districtCode = _districts.districtCodeAt(_center);
    final towns = kPenangTowns[_districtCode];
    if (towns == null || !towns.contains(_town)) _town = null;
  }

  void _onPositionChanged(MapCamera camera, bool hasGesture) {
    setState(() {
      _center = camera.center;
      // Before the classifier has loaded, isInPenang(_center) already reads
      // false everywhere else, so there's nothing useful to sync yet - and
      // doing so would wipe out an explicit district pick (see [_ready]).
      if (_ready) _syncDistrictForCenter();
    });
  }

  void _onDistrictChanged(String? code) {
    if (code == null) return;
    setState(() {
      _districtCode = code;
      final towns = kPenangTowns[code];
      if (towns == null || !towns.contains(_town)) _town = null;
    });
    final target = kDistrictCenters[code];
    if (target != null) _mapController.move(target, 13);
  }

  Future<void> _onTownChanged(String? town) async {
    setState(() => _town = town);
    if (town == null) return;
    final districtCode = _districtCode;
    final resolved = await _forwardGeocode('$town, Penang, Malaysia');
    if (!mounted) return;
    final target = resolved != null && _districts.isInPenang(resolved)
        ? resolved
        : kDistrictCenters[districtCode];
    if (target != null) _mapController.move(target, 15);
  }

  /// Best-effort forward geocode; returns `null` on any failure (no matches,
  /// no geocoder available, etc.) so the caller can fall back to the district
  /// seat. Convenience only - never the source of district truth.
  Future<LatLng?> _forwardGeocode(String address) async {
    try {
      final results = await Geocoding().locationFromAddress(address);
      if (results.isEmpty) return null;
      return LatLng(results.first.latitude, results.first.longitude);
    } catch (_) {
      return null;
    }
  }

  /// Best-effort reverse geocode to SUGGEST a town label when the user hasn't
  /// picked one - only accepted if it matches one of [kPenangTowns], so the
  /// stored town is always one of the fixed, known options.
  Future<String?> _suggestTown(String districtCode) async {
    final towns = kPenangTowns[districtCode];
    if (towns == null || towns.isEmpty) return null;
    try {
      final placemarks = await Geocoding().placemarkFromCoordinates(
        _center.latitude,
        _center.longitude,
      );
      if (placemarks.isEmpty) return null;
      final candidates = [
        placemarks.first.subLocality,
        placemarks.first.locality,
      ].where((s) => s != null && s.isNotEmpty).cast<String>();
      for (final candidate in candidates) {
        for (final town in towns) {
          if (town.toLowerCase() == candidate.toLowerCase()) return town;
        }
      }
    } catch (_) {
      // best-effort only - leave the town unset.
    }
    return null;
  }

  Future<void> _confirm() async {
    final code = _districtCode;
    if (code == null || !_districts.isInPenang(_center)) return;
    setState(() => _resolving = true);
    final town = _town ?? await _suggestTown(code);
    if (!mounted) return;
    final region = Region(
      districtCode: code,
      districtName: Region.districtNameFor(code),
      town: town,
    );
    Navigator.of(context).pop(
      PickedLocation(
        lat: _center.latitude,
        lng: _center.longitude,
        address: region.label,
        region: region,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inPenang = _districts.isInPenang(_center);
    final towns = kPenangTowns[_districtCode] ?? const <String>[];

    return Scaffold(
      appBar: AppBar(title: const Text('Pick a location')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
              child: AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$kState, $kCountry',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    Text('District', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      initialValue: _districtCode,
                      hint: const Text('Select a district...'),
                      items: [
                        for (final district in kPenangDistricts)
                          DropdownMenuItem(
                            value: district.code,
                            child: Text(district.nameMs),
                          ),
                      ],
                      onChanged: _onDistrictChanged,
                    ),
                    const SizedBox(height: 12),
                    Text('Town (optional)', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      initialValue: _town,
                      hint: const Text('Select a town...'),
                      items: [
                        for (final town in towns)
                          DropdownMenuItem(value: town, child: Text(town)),
                      ],
                      onChanged: towns.isEmpty ? null : _onTownChanged,
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: widget.initialCenter,
                      initialZoom: 12,
                      minZoom: 9,
                      maxZoom: 18,
                      cameraConstraint: CameraConstraint.contain(
                        bounds: kPenangBounds,
                      ),
                      onPositionChanged: _onPositionChanged,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.FYP.fairbid',
                      ),
                    ],
                  ),
                  // Fixed centre pin (nudged up so its tip marks the centre).
                  Padding(
                    padding: const EdgeInsets.only(bottom: 36),
                    child: Icon(
                      Icons.location_on,
                      size: 44,
                      color: inPenang
                          ? context.fairbid.verified
                          : context.fairbid.danger,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              child: AppCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      inPenang
                          ? 'Drag the map to place the pin.'
                          : 'Choose a spot within Penang.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: inPenang ? null : context.fairbid.danger,
                      ),
                    ),
                    const SizedBox(height: 12),
                    PrimaryButton(
                      label: 'Use this location',
                      busy: _resolving,
                      onPressed: inPenang ? _confirm : null,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
