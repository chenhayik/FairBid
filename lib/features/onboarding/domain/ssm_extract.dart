/// The server's verdict on an SSM document.
enum SsmVerdict {
  passed,

  needsReview,

  rejected;

  static SsmVerdict? fromStorage(String? value) => values.asNameMap()[value];
}

/// What:   The server's reading of an uploaded SSM document.
/// Input:  Owner+admin-only `private/ssmExtract`; only `extractSsmDocument` can write it (rules).
/// Output: Verdict and proposed fields; the applicant confirms them before they reach the profile.
class SsmExtract {
  const SsmExtract({
    required this.verdict,
    this.failures = const [],
    this.registrationNumber,
    this.businessName,
    this.expiryDate,
    this.natureOfBusiness,
    this.ownerNameMatches,
  });

  final SsmVerdict verdict;

  final List<String> failures;

  final String? registrationNumber;
  final String? businessName;

  /// `YYYY-MM-DD`; null unless cleanly parsed, so a half-read date can't wrongly reject.
  final String? expiryDate;

  /// Registered nature of business, e.g. "PERKHIDMATAN PERGIGIAN".
  final String? natureOfBusiness;

  /// Whether the Business Profile's owner matches the account holder; null = no Profile or no usable name.
  /// Only the result is stored; the owner's name is discarded on the server.
  final bool? ownerNameMatches;

  bool get hasProposals =>
      (businessName ?? '').isNotEmpty || (registrationNumber ?? '').isNotEmpty;

  static const _reasons = {
    'not-a-pdf': 'That file was not a readable PDF.',
    'hidden-text': 'This document contains text that is not visible when it is '
        'read normally, so it cannot be trusted.',
    'no-text-layer': 'This looks like a photo or a scan rather than the '
        'original PDF from SSM. Please upload the file you downloaded from '
        'EzBiz or e-Info.',
    'no-registration-number': 'No SSM registration number was found.',
    'number-mismatch': 'The number on the document does not match the one you '
        'entered.',
    'registration-expired': 'This registration has expired. Please upload a '
        'current certificate.',
    'missing-ssm-markers': 'The document is missing the usual SSM markings.',
    'not-digitally-signed': 'This is not a digitally certified copy, so our '
        'team will check it by hand.',
  };

  List<String> get reasons => [for (final f in failures) _reasons[f] ?? f];

  static SsmExtract? fromMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    final verdict = SsmVerdict.fromStorage(map['verdict'] as String?);
    if (verdict == null) return null;
    return SsmExtract(
      verdict: verdict,
      failures: (map['failures'] as List?)?.whereType<String>().toList() ??
          const [],
      registrationNumber: map['registrationNumber'] as String?,
      businessName: map['businessName'] as String?,
      expiryDate: map['expiryDate'] as String?,
      natureOfBusiness: map['natureOfBusiness'] as String?,
      ownerNameMatches: map['ownerNameMatches'] as bool?,
    );
  }
}
