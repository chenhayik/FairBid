/// A validated Malaysian MyKad (IC) number, `YYMMDD-PB-###G`.
///
/// There is **no checksum** in a MyKad number, so the only offline checks are
/// length, a real birth date, age 18+ and a plausible place-of-birth (PB) code.
/// A PB code that is unpublished (80, 81, 94-97) is accepted but flagged with
/// [pbNeedsReview] rather than rejected.
///
/// Twin of `functions/mykad.js`; both are pinned by
/// `test/fixtures/mykad_vectors.json`.
class MyKadNumber {
  const MyKadNumber._({
    required this.normalized,
    required this.dateOfBirth,
    required this.pbCode,
    required this.isMale,
    required this.pbNeedsReview,
  });

  /// The 12 digits, nothing else. Match and de-duplicate on this.
  final String normalized;
  final DateTime dateOfBirth;

  /// Digits 7-8, e.g. `'07'` for Penang.
  final String pbCode;

  /// Last digit odd = male, even = female.
  final bool isMale;
  final bool pbNeedsReview;

  /// `900101-07-1234`.
  String get formatted =>
      '${normalized.substring(0, 6)}-$pbCode-${normalized.substring(8)}';

  /// `******-07-**34` - safe to show or log.
  String get masked => '******-$pbCode-**${normalized.substring(10)}';

  /// Null when [input] has any [issues]. [today] is injectable for tests.
  static MyKadNumber? parse(String input, {DateTime? today}) {
    if (issues(input, today: today).isNotEmpty) return null;
    final n = _strip(input);
    final pb = int.parse(n.substring(6, 8));
    return MyKadNumber._(
      normalized: n,
      dateOfBirth: _dob(n, today ?? DateTime.now())!,
      pbCode: n.substring(6, 8),
      isMale: int.parse(n[11]).isOdd,
      pbNeedsReview: _pbReview.contains(pb),
    );
  }

  /// Issue codes - `wrong-length`, `invalid-date`, `invalid-pb-code`,
  /// `underage` - or empty when valid.
  static List<String> issues(String input, {DateTime? today}) {
    final n = _strip(input);
    if (n.length != 12) return ['wrong-length'];
    final now = today ?? DateTime.now();
    final dob = _dob(n, now);
    final pb = int.parse(n.substring(6, 8));
    return [
      if (dob == null) 'invalid-date',
      if (!_pbValid(pb)) 'invalid-pb-code',
      if (dob != null &&
          _key(dob.year + 18, dob.month, dob.day) >
              _key(now.year, now.month, now.day))
        'underage',
    ];
  }

  static String _strip(String s) => s.replaceAll(RegExp(r'\D'), '');

  static const _pbReview = {80, 81, 94, 95, 96, 97};

  static bool _pbValid(int pb) =>
      (pb >= 1 && pb <= 16) ||
      (pb >= 21 && pb <= 68) ||
      pb == 71 ||
      pb == 72 ||
      (pb >= 74 && pb <= 79) ||
      (pb >= 82 && pb <= 93) ||
      pb == 98 ||
      pb == 99 ||
      _pbReview.contains(pb);

  static int _key(int y, int m, int d) => y * 10000 + m * 100 + d;

  /// The birth date, or null when YYMMDD is not a real calendar date. 20YY
  /// unless that would be in the future.
  static DateTime? _dob(String n, DateTime today) {
    final yy = int.parse(n.substring(0, 2));
    final m = int.parse(n.substring(2, 4));
    final d = int.parse(n.substring(4, 6));
    var year = 2000 + yy;
    if (_key(year, m, d) > _key(today.year, today.month, today.day)) {
      year = 1900 + yy;
    }
    final date = DateTime.utc(year, m, d);
    // DateTime rolls over (30 Feb becomes 2 Mar), so compare back.
    if (date.year != year || date.month != m || date.day != d) return null;
    return date;
  }
}
