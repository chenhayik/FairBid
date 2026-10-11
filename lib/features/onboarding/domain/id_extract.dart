/// What the server concluded about an uploaded MyKad photo.
enum IdVerdict {
  passed,
  needsReview,
  rejected;

  static IdVerdict? fromStorage(String? value) => values.asNameMap()[value];
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

/// What:   The server's reading of an uploaded ID.
/// Input:  Owner+admin-only `private/idExtract`, written by `extractIdDocument`.
/// Output: Verdict, failure codes, masked IC and three-valued checks (null = could not tell).
/// Notes:  Never holds the name, DOB or full number.
class IdExtract {
  const IdExtract({
    required this.verdict,
    this.failures = const [],
    this.maskedIc,
    this.ageOk,
    this.nameMatches,
    this.genderConsistent,
  });

  final IdVerdict verdict;
  final List<String> failures;
  final String? maskedIc;

  final bool? ageOk;
  final bool? nameMatches;
  final bool? genderConsistent;

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
    );
  }
}
