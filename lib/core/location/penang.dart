import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:latlong2/latlong.dart';

/// FairBid is scoped to Penang for this launch: country and state are fixed
/// constants rather than user input.
const kCountry = 'Malaysia';
const kState = 'Penang';

/// One of Penang's 5 administrative districts: a stable [code] used in
/// storage plus its English and Malay display names.
class PenangDistrict {
  const PenangDistrict(this.code, this.nameEn, this.nameMs);

  /// Stable short code - never shown to the user, only stored.
  final String code;
  final String nameEn;
  final String nameMs;
}

/// Penang's 5 districts. Order matches the plan's TL/BD/SPU/SPT/SPS listing.
const kPenangDistricts = [
  PenangDistrict('TL', 'Northeast', 'Timur Laut'),
  PenangDistrict('BD', 'Southwest', 'Barat Daya'),
  PenangDistrict('SPU', 'North Seberang Perai', 'Seberang Perai Utara'),
  PenangDistrict('SPT', 'Central Seberang Perai', 'Seberang Perai Tengah'),
  PenangDistrict('SPS', 'South Seberang Perai', 'Seberang Perai Selatan'),
];

/// Each district's administrative seat: the point used both to build
/// [kPenangDistricts]' assignment in the shipped GeoJSON (see
/// `assets/geo/penang_districts.geojson`) and as the map's recenter target
/// when a district is picked without (yet) narrowing to a town.
const kDistrictCenters = <String, LatLng>{
  'TL': LatLng(5.4141, 100.3288), // George Town
  'BD': LatLng(5.3488, 100.2337), // Balik Pulau
  'SPU': LatLng(5.5155, 100.4257), // Kepala Batas
  'SPT': LatLng(5.3630, 100.4667), // Bukit Mertajam
  'SPS': LatLng(5.1656, 100.4790), // Nibong Tebal
};

/// George Town - the picker's default map centre.
const kGeorgeTown = LatLng(5.4141, 100.3288);

/// The picker's map camera is constrained to this bounding box (see
/// `CameraConstraint.contain` in `RegionPickerScreen`). Not `const` - flutter_map's
/// [LatLngBounds] is a plain mutable class, only reachable via its factory.
final kPenangBounds = LatLngBounds(
  const LatLng(5.10, 100.15),
  const LatLng(5.60, 100.58),
);

/// Known towns per district, for the picker's (optional) Town dropdown.
const kPenangTowns = <String, List<String>>{
  'TL': [
    'George Town',
    'Pulau Tikus',
    'Tanjung Tokong',
    'Tanjung Bungah',
    'Batu Ferringhi',
    'Air Itam',
    'Paya Terubong',
    'Jelutong',
    'Gelugor',
    'Bukit Bendera',
  ],
  'BD': [
    'Balik Pulau',
    'Bayan Lepas',
    'Bayan Baru',
    'Batu Maung',
    'Teluk Kumbar',
    'Gertak Sanggul',
    'Pulau Betong',
    'Teluk Bahang',
    'Sungai Ara',
  ],
  'SPU': [
    'Butterworth',
    'Kepala Batas',
    'Bertam',
    'Tasek Gelugor',
    'Penaga',
    'Bagan Ajam',
    'Telok Air Tawar',
  ],
  'SPT': [
    'Bukit Mertajam',
    'Perai',
    'Seberang Jaya',
    'Juru',
    'Bukit Minyak',
    'Permatang Pauh',
    'Machang Bubuk',
    'Alma',
  ],
  'SPS': [
    'Nibong Tebal',
    'Batu Kawan',
    'Simpang Ampat',
    'Sungai Bakap',
    'Jawi',
    'Valdor',
  ],
};
