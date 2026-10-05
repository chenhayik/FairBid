/// What the server concluded about an uploaded MyKad photo.
enum IdVerdict {
  passed,
  needsReview,
  rejected;

  static IdVerdict? fromStorage(String? value) => switch (value) {
    'passed' => IdVerdict.passed,
    'needsReview' => IdVerdict.needsReview,
    'rejected' => IdVerdict.rejected,
    _ => null,
  };
}

/// Short friendly text for a failure code written by `extractIdDocument`.
String idFailureLabel(String code) => switch (code) {
  'not-an-image' => 'That file is not a JPEG or PNG photo',
  'no-ic-found' => 'We could not read an IC number on the photo',
  'invalid-ic' => 'The number on the card does not look valid',
  'underage' => 'The card shows an age under 18',
  'ic-mismatch' => 'The number on the card does not match the one you typed',
  'duplicate-ic' => 'This IC number is already registered',
  'name-mismatch' =>
    'The name on the card could not be matched to your '
        'account',
  'gender-inconsistent' => 'The gender on the card does not fit the number',
  'missing-mykad-markers' => 'The photo does not look like a MyKad',
  'unknown-pb-code' => 'The place-of-birth code needs a manual check',
  'ocr-failed' => 'We could not read the photo automatically',
  'passport-not-automated' => 'Passports are checked by our team',
  _ => code,
};

/// The server's reading of an uploaded ID, from the owner+admin-only
/// `users/{uid}/private/idExtract` document (written only by Cloud Functions).
/// Holds a masked IC and booleans only - never the name, DOB or full number.
class IdExtract {
  const IdExtract({
    required this.verdict,
    this.failures = const [],
    this.maskedIc,
    this.ageOk,
    this.nameMatches,
    this.genderConsistent,
    this.storagePath,
  });

  final IdVerdict verdict;
  final List<String> failures;
  final String? maskedIc;

  /// Three-valued: null means "could not tell", which is not "no".
  final bool? ageOk;
  final bool? nameMatches;
  final bool? genderConsistent;
  final String? storagePath;

  static IdExtract? fromMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    final verdict = IdVerdict.fromStorage(map['verdict'] as String?);
    if (verdict == null) return null;
    return IdExtract(
      verdict: verdict,
      failures:
          (map['failures'] as List?)?.whereType<String>().toList() ?? const [],
      maskedIc: map['maskedIc'] as String?,
      ageOk: map['ageOk'] as bool?,
      nameMatches: map['nameMatches'] as bool?,
      genderConsistent: map['genderConsistent'] as bool?,
      storagePath: map['storagePath'] as String?,
    );
  }
}
