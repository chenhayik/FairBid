/// What:   Entity type in digits 5-6 of a current-format SSM number.
/// Input:  Two-digit [code] via [fromCode].
/// Output: localCompany, foreignCompany, business, localLlp, foreignLlp or professionalLlp.
enum SsmEntityType {
  localCompany('01'),
  foreignCompany('02'),
  business('03'),
  localLlp('04'),
  foreignLlp('05'),
  professionalLlp('06');

  const SsmEntityType(this.code);

  /// The two digits as they appear in the number, e.g. `'03'`.
  final String code;

  /// What:   Looks up an entity type by its two digits.
  /// Output: The matching type, or null if the code is unknown.
  static SsmEntityType? fromCode(String code) {
    for (final type in values) {
      if (type.code == code) return type;
    }
    return null;
  }
}

/// What:   Which SSM numbering scheme a number uses.
/// Output: [current] (12 digits) or [legacy] (pre-2019).
enum SsmNumberFormat {
  /// 12 digits, `YYYY` + entity type + running number. Mandatory since
  /// 11 October 2019 and applied retrospectively to existing entities.
  current,

  /// Pre-2019: an optional two-letter state prefix, 5–9 digits and a single
  /// trailing letter - `003058656-T`, `SA0085324-V`, `499519-U`.
  legacy,
}

/// What:   A parsed Malaysian SSM registration number.
/// Input:  Typed text via [parse] / [validate]; accepts the current format, the legacy one, or both pasted together
///         (`201903350205 (003058656-T)`).
/// Output: Normalised key plus year and entity type (current format only).
/// Notes:  No check digit exists: checks are length, plausible year and known type code. The legacy trailing
///         letter and state prefix are stored, not validated.
class SsmNumber {
  const SsmNumber._({
    required this.normalized,
    required this.format,
    this.year,
    this.entityType,
    this.legacyNumber,
  });

  /// Canonical key (uppercase, no punctuation, current-format half if both were pasted); match on this.
  final String normalized;

  final SsmNumberFormat format;

  /// Registration year; current format only.
  final int? year;

  /// Entity type; current format only.
  final SsmEntityType? entityType;

  /// The legacy number when the combined form was pasted, so it survives.
  final String? legacyNumber;

  /// What:   Parses typed text into an SsmNumber.
  /// Input:  [input] from the form; may be null.
  /// Output: SsmNumber, or null when invalid.
  static SsmNumber? parse(String? input) =>
      input == null ? null : _parse(input).$1;

  /// What:   `TextFormField` validator for the SSM number.
  /// Input:  [value] typed by the user.
  /// Output: Null when acceptable, else the error message.
  static String? validate(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'SSM registration number is required.';
    return _parse(text).$2;
  }

  static const _earliestYear = 1900;

  /// `201903350205 (003058656-T)` - the combined form users paste verbatim.
  static final _combined = RegExp(r'^(.+?)\s*\((.+?)\)\s*$');
  static final _currentFormat = RegExp(r'^\d{12}$');
  static final _legacyFormat = RegExp(r'^[A-Z]{0,2}\d{5,9}[A-Z]$');
  static final _digitsOnly = RegExp(r'^\d+$');

  /// What:   Removes punctuation from a number.
  /// Output: Uppercase letters and digits only; spaces, hyphens and dots are never significant.
  static String _strip(String value) =>
      value.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');

  /// What:   Shared parser behind [parse] and [validate], so they always agree.
  /// Input:  Typed text, possibly the combined `current (legacy)` form.
  /// Output: Record of (parsed number, failure reason); exactly one is non-null.
  /// How:    Splits the combined form before stripping; current format checks year and entity code, legacy checks the pattern.
  static (SsmNumber?, String?) _parse(String input) {
    final text = input.trim();

    // Split the combined form *before* stripping, or the two numbers fuse into
    // one meaningless key.
    final combined = _combined.firstMatch(text);
    final normalized = _strip(combined?.group(1) ?? text);
    final legacy = combined == null ? null : _strip(combined.group(2)!);

    if (_currentFormat.hasMatch(normalized)) {
      final year = int.parse(normalized.substring(0, 4));
      if (year < _earliestYear || year > DateTime.now().year) {
        return (null, '$year is not a valid registration year.');
      }
      final code = normalized.substring(4, 6);
      final entityType = SsmEntityType.fromCode(code);
      if (entityType == null) {
        return (null, '"$code" is not a known SSM entity type code.');
      }
      return (
        SsmNumber._(
          normalized: normalized,
          format: SsmNumberFormat.current,
          year: year,
          entityType: entityType,
          legacyNumber: legacy,
        ),
        null,
      );
    }

    if (_legacyFormat.hasMatch(normalized)) {
      return (
        SsmNumber._(
          normalized: normalized,
          format: SsmNumberFormat.legacy,
        ),
        null,
      );
    }

    // All digits but the wrong length is the common typo - name it precisely.
    if (_digitsOnly.hasMatch(normalized)) {
      return (
        null,
        'A current SSM number has 12 digits; this has ${normalized.length}.',
      );
    }
    return (null, 'Enter a valid SSM number, e.g. 201903350205 or 003058656-T.');
  }
}