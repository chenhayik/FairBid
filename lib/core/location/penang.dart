import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:latlong2/latlong.dart';

// FairBid is Penang-only, so country and state are constants.
const kCountry = 'Malaysia';
const kState = 'Penang';

/// What:   One of Penang's 5 districts.
/// Input:  [kPenangDistricts].
/// Output: A stored [code] and the Malay display name.
class PenangDistrict {
  const PenangDistrict(this.code, this.nameMs);

  /// Stored code, never shown.
  final String code;
  final String nameMs;
}

const kPenangDistricts = [
  PenangDistrict('TL', 'Timur Laut'),
  PenangDistrict('BD', 'Barat Daya'),
  PenangDistrict('SPU', 'Seberang Perai Utara'),
  PenangDistrict('SPT', 'Seberang Perai Tengah'),
  PenangDistrict('SPS', 'Seberang Perai Selatan'),
];

/// Each district's seat: the map recenter target when a district is picked without a town.
const kDistrictCenters = <String, LatLng>{
  'TL': LatLng(5.4141, 100.3288), // George Town
  'BD': LatLng(5.3488, 100.2337), // Balik Pulau
  'SPU': LatLng(5.5155, 100.4257), // Kepala Batas
  'SPT': LatLng(5.3630, 100.4667), // Bukit Mertajam
  'SPS': LatLng(5.1656, 100.4790), // Nibong Tebal
};

/// George Town - the picker's default map centre.
const kGeorgeTown = LatLng(5.4141, 100.3288);

/// Bounds the picker's map camera (not const: flutter_map's LatLngBounds is mutable).
final kPenangBounds = LatLngBounds(
  const LatLng(5.10, 100.15),
  const LatLng(5.60, 100.58),
);

/// Known towns per district for the picker's Town dropdown.
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
