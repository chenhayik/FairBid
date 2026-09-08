/// The entity type encoded in digits 5–6 of a current-format SSM number.
enum SsmEntityType {
  localCompany('01', 'Local company'),
  foreignCompany('02', 'Foreign company'),
  business('03', 'Sole proprietorship / partnership'),
  localLlp('04', 'Limited liability partnership'),
  foreignLlp('05', 'Foreign LLP'),
  professionalLlp('06', 'Professional practice LLP');

  const SsmEntityType(this.code, this.label);

  /// The two digits as they appear in the number, e.g. `'03'`.
  final String code;

  /// Human-readable, for the profile and the admin queue.
  final String label;

  static SsmEntityType? fromCode(String code) {
    for (final type in values) {
      if (type.code == code) return type;
    }
    return null;
  }
}

enum SsmNumberFormat {
  /// 12 digits, `YYYY` + entity type + running number. Mandatory since
  /// 11 October 2019 and applied retrospectively to existing entities.
  current,

  /// Pre-2019: an optional two-letter state prefix, 5–9 digits and a single
  /// trailing letter - `003058656-T`, `SA0085324-V`, `499519-U`.
  legacy,
}

/// A parsed Malaysian SSM registration number.
///
/// Both formats are still in circulation and real SSM documents print them
/// together - a certificate header reads
/// `REGISTRATION NO. : 201903350205 (003058656-T)` - so [parse] accepts either
/// form, or both at once.
///
/// There is **no check digit**: all twelve positions of the current format are
/// accounted for by year + type + sequence. The only offline checks possible
/// are the length, a plausible year and a known type code.
///
/// Deliberately *not* validated:
///  * the legacy trailing letter. It is neither a documented check character
///    nor a reliable type code - a sole proprietorship draws `-T`/`-V` from the
///    same alphabet a Sdn Bhd draws `-U`/`-K` from. Store it, never compute it.
///  * the legacy two-letter state prefix (`SA`, `PG`, `JM`). No authoritative
///    SSM table exists, so it is display metadata only.
class SsmNumber {
  const SsmNumber._({
    required this.raw,
    required this.normalized,
    required this.format,
    this.year,
    this.entityType,
    this.legacyNumber,
  });

  /// Exactly what the user typed, trimmed. Show this back to them.
  final String raw;

  /// Canonical key: uppercased, punctuation stripped, and - when the combined
  /// form was pasted - the current-format half. Match and de-duplicate on this,
  /// never on [raw].
  final String normalized;

  final SsmNumberFormat format;

  /// Registration year; current format only.
  final int? year;

  /// Entity type; current format only.
  final SsmEntityType? entityType;

  /// The legacy number when the combined form was pasted, so it survives.
  final String? legacyNumber;

  /// Returns null when [input] is not a usable SSM number.
  static SsmNumber? parse(String? input) =>
      input == null ? null : _parse(input).$1;

  /// `TextFormField` validator - null when acceptable, else the message to
  /// show. Mirrors the contract of [Validators].
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

  /// Spaces, hyphens and dots are punctuation on these numbers, never
  /// significant.
  static String _strip(String value) =>
      value.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');

  /// Returns the parsed number, or the reason it could not be parsed. One pass
  /// serves both [parse] and [validate] so the two can never disagree.
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
          raw: text,
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
          raw: text,
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