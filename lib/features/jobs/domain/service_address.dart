/// A requestor's precise, structured Malaysian service address for a job -
/// distinct from [JobLocation]'s coarse map pin, which stays visible to every
/// bidder. This is kept private (see `job_repository.dart`'s
/// `setJobAddress`/`watchJobAddress` and the matching Firestore rule): only
/// the job's owner, its accepted provider and admins may ever read it.
class ServiceAddress {
  const ServiceAddress({
    required this.line1,
    this.line2,
    required this.postcode,
    required this.city,
    this.state = 'Penang',
    this.accessNote,
  });

  /// House/unit number and street, e.g. "12, Jalan Mawar 3".
  final String line1;

  /// Building / taman / floor, optional.
  final String? line2;

  /// 5-digit Malaysian postcode.
  final String postcode;

  /// Town/city, e.g. "Bayan Lepas".
  final String city;

  final String state;

  /// Free-text delivery instructions, e.g. "gate code 1234, park at the
  /// back, call on arrival". Optional.
  final String? accessNote;

  Map<String, dynamic> toMap() => {
        'line1': line1,
        'line2': line2,
        'postcode': postcode,
        'city': city,
        'state': state,
        'accessNote': accessNote,
      };

  /// Rebuilds a [ServiceAddress] from a stored map. Returns `null` when
  /// [map] is null or has no [line1], so callers can treat "no address" -
  /// the common case, since this is entirely optional - cleanly.
  static ServiceAddress? fromMap(Map<String, dynamic>? map) {
    final line1 = map?['line1'] as String?;
    if (line1 == null || line1.isEmpty) return null;
    return ServiceAddress(
      line1: line1,
      line2: map?['line2'] as String?,
      postcode: map?['postcode'] as String? ?? '',
      city: map?['city'] as String? ?? '',
      state: map?['state'] as String? ?? 'Penang',
      accessNote: map?['accessNote'] as String?,
    );
  }

  /// A multi-line block suitable for display: line1 / line2 (if present) /
  /// "postcode city" / state.
  String get formatted => [
        line1,
        if (line2 != null && line2!.isNotEmpty) line2,
        '$postcode $city',
        state,
      ].join('\n');

  /// A one-line summary, e.g. "12, Jalan Mawar 3, 11900 Bayan Lepas".
  String get summary => '$line1, $postcode $city';
}
