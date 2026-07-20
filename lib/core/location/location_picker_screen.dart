import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geocoding/geocoding.dart';
import 'package:latlong2/latlong.dart';

import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

/// The value returned by the location picker: coordinates plus a best-effort,
/// human-readable address label.
class PickedLocation {
  const PickedLocation({
    required this.lat,
    required this.lng,
    required this.address,
  });

  final double lat;
  final double lng;
  final String address;
}

/// Full-screen map picker (OpenStreetMap via flutter_map — no API key). The map
/// moves under a fixed centre pin; confirming reverse-geocodes the centre into
/// an address label. Push it with [LocationPickerScreen.show].
class LocationPickerScreen extends StatefulWidget {
  const LocationPickerScreen({super.key, required this.initialCenter});

  final LatLng initialCenter;

  /// Kuala Lumpur — a sensible default centre for the Malaysian market.
  static const defaultCenter = LatLng(3.1390, 101.6869);

  static Future<PickedLocation?> show(
    BuildContext context, {
    LatLng? initial,
  }) {
    return Navigator.of(context).push<PickedLocation>(
      MaterialPageRoute(
        builder: (_) =>
            LocationPickerScreen(initialCenter: initial ?? defaultCenter),
      ),
    );
  }

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  final _mapController = MapController();
  bool _resolving = false;

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    setState(() => _resolving = true);
    final center = _mapController.camera.center;
    final address = await _reverseGeocode(center);
    if (!mounted) return;
    Navigator.of(context).pop(PickedLocation(
      lat: center.latitude,
      lng: center.longitude,
      address: address,
    ));
  }

  /// Best-effort reverse geocode. Returns a coordinate string if the platform
  /// geocoder is unavailable (e.g. some emulators) — the caller's field is
  /// editable, so the user can fix it.
  Future<String> _reverseGeocode(LatLng point) async {
    try {
      final marks = await Geocoding()
          .placemarkFromCoordinates(point.latitude, point.longitude);
      if (marks.isNotEmpty) {
        final p = marks.first;
        final parts = [p.subLocality, p.locality, p.administrativeArea]
            .where((s) => s != null && s.isNotEmpty)
            .toList();
        if (parts.isNotEmpty) return parts.join(', ');
      }
    } catch (_) {
      // fall through to coordinates
    }
    return '${point.latitude.toStringAsFixed(4)}, '
        '${point.longitude.toStringAsFixed(4)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pick a location')),
      body: Stack(
        alignment: Alignment.center,
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: widget.initialCenter,
              initialZoom: 14,
              minZoom: 3,
              maxZoom: 18,
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
            child: Icon(Icons.location_on,
                size: 44, color: context.fairbid.verified),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 24,
            child: AppCard(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Drag the map to place the pin.',
                      style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 12),
                  PrimaryButton(
                    label: 'Use this location',
                    busy: _resolving,
                    onPressed: _confirm,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
