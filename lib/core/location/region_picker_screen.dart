import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geocoding/geocoding.dart';
import 'package:latlong2/latlong.dart';

import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import 'address_hint.dart';
import 'geo.dart';
import 'penang.dart';
import 'penang_districts.dart';
import 'region.dart';

/// What:   Penang-bounded location picker: District dropdown, optional Town dropdown and a map, kept in sync.
/// Input:  [initialCenter], optional [initialRegion]; open with [RegionPickerScreen.show].
/// Output: Pops a [PickedLocation]. Dragging re-classifies the district (PenangDistricts); picking a district recentres on its seat;
///         picking a town geocodes it (falling back to the seat); "Use this location" is disabled outside Penang.
class RegionPickerScreen extends StatefulWidget {
  const RegionPickerScreen({
    super.key,
    required this.initialCenter,
    this.initialRegion,
  });

  final LatLng initialCenter;

  /// Pre-fills the district and town when editing an existing pick.
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

  /// True once the GeoJSON has loaded; stops an early map move from clobbering a picked district with null.
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

  /// Re-classifies the district from [_center], clearing [_town] if it no longer belongs.
  void _syncDistrictForCenter() {
    _districtCode = _districts.districtCodeAt(_center);
    final towns = kPenangTowns[_districtCode];
    if (towns == null || !towns.contains(_town)) _town = null;
  }

  void _onPositionChanged(MapCamera camera, bool hasGesture) {
    setState(() {
      _center = camera.center;
      // Skipped before load: syncing would wipe an explicit district pick (see [_ready]).
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

  /// Best-effort forward geocode; null on failure so the caller falls back to the district seat.
  Future<LatLng?> _forwardGeocode(String address) async {
    try {
      final results = await Geocoding().locationFromAddress(address);
      if (results.isEmpty) return null;
      return LatLng(results.first.latitude, results.first.longitude);
    } catch (_) {
      return null;
    }
  }

  Future<void> _confirm() async {
    final code = _districtCode;
    if (code == null || !_districts.isInPenang(_center)) return;
    setState(() => _resolving = true);
    // One reverse geocode suggests a town and carries a hint for the service-address form; failure blocks nothing.
    final hint = await reverseGeocode(_center);
    if (!mounted) return;
    // Only a town from [kPenangTowns] is accepted, never raw geocoder output.
    final town = _town ?? hint?.matchTown(kPenangTowns[code] ?? const []);
    final region = Region(
      districtCode: code,
      districtName: Region.districtNameFor(code),
      town: town,
    );
    Navigator.of(context).pop(
      PickedLocation(
        // Any signed-in user can read this, so round it.
        lat: coarseCoord(_center.latitude),
        lng: coarseCoord(_center.longitude),
        address: region.label,
        region: region,
        addressHint: hint,
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
                  // Centre pin, nudged up so its tip marks the centre.
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
